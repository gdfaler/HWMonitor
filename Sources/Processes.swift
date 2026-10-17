import Foundation
import Darwin

struct ProcInfo: Identifiable {
    let pid: pid_t
    var name: String
    var owned: Bool          // процесс этого пользователя — им можно управлять
    var cpu: Double          // % одного ядра
    var pShare: Double       // доля времени на быстрых ядрах, -1 если неизвестно
    var mem: UInt64
    var power: Double        // Вт, 0 если неизвестно
    var responsible: pid_t   // приложение, которому принадлежит процесс
    var stopped: Bool
    var id: pid_t { pid }
}

/// Свои процессы читаются точно через libproc; чужие (системные) — через ps, он setuid.
final class ProcessSampler {
    private struct Counters {
        var cpu: UInt64
        var pcpu: UInt64
        var energy: UInt64
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    private var previous: [pid_t: Counters] = [:]
    private var previousTime = 0.0
    private var names: [pid_t: String] = [:]
    private var responsibles: [pid_t: pid_t] = [:]
    private var others: [ProcInfo] = []
    private var pass = 0
    private var timebase = mach_timebase_info_data_t()
    private let responsibleFn: ResponsibleFn?

    init() {
        mach_timebase_info(&timebase)
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") {
            responsibleFn = unsafeBitCast(symbol, to: ResponsibleFn.self)
        } else {
            responsibleFn = nil
        }
    }

    func sample() -> [ProcInfo] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - previousTime
        let hasBaseline = previousTime > 0 && dt > 0.2

        var result: [ProcInfo] = []
        var counters: [pid_t: Counters] = [:]
        var owned = Set<pid_t>()
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            var usage = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            guard ok == 0 else { continue }
            owned.insert(pid)
            let fresh = Counters(cpu: usage.ri_user_time + usage.ri_system_time,
                                 pcpu: usage.ri_user_ptime + usage.ri_system_ptime,
                                 energy: usage.ri_energy_nj)
            counters[pid] = fresh

            var cpu = 0.0
            var pShare = -1.0
            var power = 0.0
            if hasBaseline, let old = previous[pid], fresh.cpu >= old.cpu {
                let ticks = fresh.cpu - old.cpu
                let nanos = Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
                cpu = nanos / (dt * 1e9) * 100
                if ticks > 0, fresh.pcpu >= old.pcpu { pShare = min(1, Double(fresh.pcpu - old.pcpu) / Double(ticks)) }
                if fresh.energy >= old.energy { power = Double(fresh.energy - old.energy) / 1e9 / dt }
            }

            var bsd = proc_bsdinfo()
            let got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
            result.append(ProcInfo(pid: pid, name: name(of: pid), owned: true, cpu: cpu, pShare: pShare,
                                   mem: usage.ri_phys_footprint, power: power, responsible: responsible(for: pid),
                                   stopped: got > 0 && bsd.pbi_status == UInt32(SSTOP)))
        }
        previous = counters
        previousTime = now
        names = names.filter { owned.contains($0.key) }
        responsibles = responsibles.filter { owned.contains($0.key) }

        if pass % 3 == 0 { others = foreignProcesses(excluding: owned) }
        pass += 1
        return result + others
    }

    private func name(of pid: pid_t) -> String {
        if let cached = names[pid] { return cached }
        var path = [CChar](repeating: 0, count: 4096)
        var name = ""
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            name = (String(cString: path) as NSString).lastPathComponent
        }
        if name.isEmpty {
            var short = [CChar](repeating: 0, count: 256)
            proc_name(pid, &short, UInt32(short.count))
            name = String(cString: short)
        }
        if name.isEmpty { name = "pid \(pid)" }
        names[pid] = name
        return name
    }

    private func responsible(for pid: pid_t) -> pid_t {
        if let cached = responsibles[pid] { return cached }
        var owner = pid
        if let fn = responsibleFn {
            let r = fn(pid)
            if r > 0 { owner = r }
        }
        responsibles[pid] = owner
        return owner
    }

    /// Процессы других пользователей: только для показа, управлять ими без root нельзя.
    private func foreignProcesses(excluding owned: Set<pid_t>) -> [ProcInfo] {
        guard let output = runTool("/bin/ps", ["-Axco", "pid=,pcpu=,rss=,comm="]) else { return [] }
        var result: [ProcInfo] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = pid_t(parts[0]), !owned.contains(pid),
                  let cpu = Double(parts[1]), let rss = UInt64(parts[2]) else { continue }
            result.append(ProcInfo(pid: pid, name: String(parts[3]), owned: false, cpu: cpu, pShare: -1,
                                   mem: rss * 1024, power: 0, responsible: pid, stopped: false))
        }
        return result
    }
}

/// Запускает системную утилиту и возвращает её вывод.
func runTool(_ path: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8)
}
