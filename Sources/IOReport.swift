import Foundation
import IOKit

/// Частоты ядер (по времени в каждом состоянии DVFS) и мощность GPU через IOReport.
final class IOReportSampler {
    struct Core {
        var active: Double   // доля времени не в простое, 0...1
        var mhz: Double?     // средняя частота, пока ядро работало
    }

    struct Result {
        var e: [Int: Core] = [:]
        var p: [Int: Core] = [:]
        var gpuActive: Double?
        var gpuWatts: Double?
        var cpuWatts: Double?
    }

    private let subscription: OpaquePointer
    private let channels: CFMutableDictionary
    private let listKey = "IOReportChannels" as CFString
    private var previous: CFDictionary?
    private var previousTime = 0.0
    let eTable: [Double]   // МГц по состояниям, от низшего к высшему
    let pTable: [Double]

    init?() {
        let wanted: [(String, String?)] = [
            ("CPU Stats", "CPU Core Performance States"),
            ("GPU Stats", "GPU Performance States"),
            ("Energy Model", nil),
        ]
        var merged: CFMutableDictionary?
        for (group, sub) in wanted {
            guard let found = IOReportCopyChannelsInGroup(group as CFString, sub.map { $0 as CFString }, 0, 0, 0) else { continue }
            if let m = merged {
                IOReportMergeChannels(m, found, nil)
            } else {
                merged = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, found)
            }
        }
        guard let desired = merged else { return nil }
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let sub = IOReportCreateSubscription(nil, desired, &subbed, 0, nil),
              let dict = subbed?.takeRetainedValue() else { return nil }
        subscription = sub
        channels = dict
        eTable = IOReportSampler.dvfsTable("voltage-states1-sram")
        pTable = IOReportSampler.dvfsTable("voltage-states5-sram")
    }

    /// Таблица частот кластера из узла pmgr: пары (частота, напряжение) по 4 байта.
    private static func dvfsTable(_ property: String) -> [Double] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("pmgr"))
        guard service != 0 else { return [] }
        defer { IOObjectRelease(service) }
        guard let data = IORegistryEntryCreateCFProperty(service, property as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return [] }
        var table: [Double] = []
        var offset = 0
        while offset + 8 <= data.count {
            let freq = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            // До M4 частота записана в Гц, начиная с M4 — в кГц.
            if freq > 0 { table.append(freq >= 100_000_000 ? Double(freq) / 1e6 : Double(freq) / 1e3) }
            offset += 8
        }
        return table
    }

    func sample() -> Result? {
        guard let current = IOReportCreateSamples(subscription, channels, nil) else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        defer {
            previous = current
            previousTime = now
        }
        guard let prev = previous, let delta = IOReportCreateSamplesDelta(prev, current, nil) else { return nil }
        let dt = now - previousTime
        guard dt > 0.05,
              let raw = CFDictionaryGetValue(delta, Unmanaged.passUnretained(listKey).toOpaque()) else { return nil }
        // Функции IOReportChannelGet* дописывают кэш в словарь канала, поэтому работаем с CF-объектами напрямую.
        let list = unsafeBitCast(raw, to: CFArray.self)

        var result = Result()
        for i in 0..<CFArrayGetCount(list) {
            let ch = unsafeBitCast(CFArrayGetValueAtIndex(list, i), to: CFDictionary.self)
            let group = IOReportChannelGetGroup(ch).map { $0 as String } ?? ""
            let name = IOReportChannelGetChannelName(ch).map { $0 as String } ?? ""
            switch group {
            case "CPU Stats":
                if name.hasPrefix("ECPU"), let index = Int(name.dropFirst(4)) {
                    result.e[index] = residency(ch, table: eTable)
                } else if name.hasPrefix("PCPU"), let index = Int(name.dropFirst(4)) {
                    result.p[index] = residency(ch, table: pTable)
                }
            case "GPU Stats":
                if name == "GPUPH" { result.gpuActive = residency(ch, table: []).active }
            case "Energy Model":
                guard name == "GPU Energy" || name == "CPU Energy" else { continue }
                let unit = (IOReportChannelGetUnitLabel(ch).map { $0 as String } ?? "").trimmingCharacters(in: .whitespaces)
                let scale: Double
                switch unit {
                case "mJ": scale = 1e-3
                case "uJ": scale = 1e-6
                case "nJ": scale = 1e-9
                default: continue
                }
                let watts = Double(IOReportSimpleGetIntegerValue(ch, 0)) * scale / dt
                if name == "GPU Energy" {
                    result.gpuWatts = watts
                } else if watts > 0 {
                    // На M5 канал CPU Energy отдаёт нули — тогда мощность чипа берём из SMC.
                    result.cpuWatts = watts
                }
            default:
                continue
            }
        }
        return result
    }

    private func residency(_ ch: CFDictionary, table: [Double]) -> Core {
        var idle: Int64 = 0
        var active: Int64 = 0
        var weighted = 0.0
        var state = 0
        for i in 0..<IOReportStateGetCount(ch) {
            let name = IOReportStateGetNameForIndex(ch, i).map { $0 as String } ?? ""
            let time = IOReportStateGetResidency(ch, i)
            if name == "IDLE" || name == "DOWN" || name == "OFF" {
                idle += time
                continue
            }
            active += time
            if state < table.count { weighted += Double(time) * table[state] }
            state += 1
        }
        let total = idle + active
        let known = state == table.count && active > 0
        return Core(active: total > 0 ? Double(active) / Double(total) : 0,
                    mhz: known ? weighted / Double(active) : nil)
    }
}
