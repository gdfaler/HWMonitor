import Foundation
import SwiftUI
import AppKit

// MARK: - Данные одного замера

struct CoreSample: Identifiable {
    let id: Int          // логический номер ядра
    let isP: Bool
    var usage: Double    // 0...1
    var mhz: Double?     // средняя частота, пока ядро работало
}

struct Snapshot {
    var time = Date()
    var cores: [CoreSample] = []
    var cpuTotal = 0.0
    var cpuP = 0.0
    var cpuE = 0.0
    var freqP: Double?
    var freqE: Double?
    var maxFreqP: Double?
    var maxFreqE: Double?
    var temps: [TempReading] = []
    var tempCPU: Double?
    var tempGPU: Double?
    var tempSoC: Double?       // самая горячая точка чипа
    var tempBattery: Double?
    var tempSSD: Double?
    var powerSystem: Double?
    var powerBattery: Double?
    var powerAdapter: Double?
    var powerSoC: Double?
    var powerGPU: Double?
    var rails: [RailReading] = []
    var fans: [FanReading] = []
    var gpu = GPUSample()
    var gpuActive: Double?
    var mem = MemSample()
    var disk = DiskSample()
    var net = NetSample()
    var battery: BatterySample?
    var thermalLevel = 0
    var lowPower = false
}

enum Metric: Int, CaseIterable {
    case cpu, cpuP, cpuE, gpu, tempCPU, tempGPU, powerSystem, memUsed, netIn, netOut, diskRead, diskWrite
}

struct HistoryPoint: Identifiable {
    let id: Int
    let t: Date
    var values: [Double]   // по Metric.rawValue, NaN — нет данных

    subscript(metric: Metric) -> Double? {
        let v = values[metric.rawValue]
        return v.isNaN ? nil : v
    }
}

// MARK: - Настройки

enum Page: String, CaseIterable, Identifiable {
    case overview, cpu, sensors, memory, power, processes, controls
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Обзор"
        case .cpu: return "Процессор и GPU"
        case .sensors: return "Датчики"
        case .memory: return "Память, диск, сеть"
        case .power: return "Питание"
        case .processes: return "Процессы"
        case .controls: return "Управление"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.50percent"
        case .cpu: return "cpu"
        case .sensors: return "thermometer.medium"
        case .memory: return "memorychip"
        case .power: return "battery.75percent"
        case .processes: return "list.bullet.rectangle"
        case .controls: return "slider.horizontal.3"
        }
    }
}

enum MenuBarMode: String, Codable, CaseIterable, Identifiable {
    case tempCPU, temp, cpu, power, icon
    var id: String { rawValue }

    var title: String {
        switch self {
        case .tempCPU: return "Температура и нагрузка"
        case .temp: return "Температура"
        case .cpu: return "Нагрузка CPU"
        case .power: return "Мощность"
        case .icon: return "Только значок"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var interval = 1.0
    var windowMinutes = 5
    var menuBar = MenuBarMode.tempCPU
    var autoCool = false
    var coolThreshold = 85.0
    var coolOnPressure = true
    var coolMinCPU = 25.0
    var coolSpareFrontmost = true
    var coolNotify = true
    var coolExclusions = ""
    var keepAwake = false
    var keepDisplayAwake = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        interval = try c.decodeIfPresent(Double.self, forKey: .interval) ?? d.interval
        windowMinutes = try c.decodeIfPresent(Int.self, forKey: .windowMinutes) ?? d.windowMinutes
        menuBar = try c.decodeIfPresent(MenuBarMode.self, forKey: .menuBar) ?? d.menuBar
        autoCool = try c.decodeIfPresent(Bool.self, forKey: .autoCool) ?? d.autoCool
        coolThreshold = try c.decodeIfPresent(Double.self, forKey: .coolThreshold) ?? d.coolThreshold
        coolOnPressure = try c.decodeIfPresent(Bool.self, forKey: .coolOnPressure) ?? d.coolOnPressure
        coolMinCPU = try c.decodeIfPresent(Double.self, forKey: .coolMinCPU) ?? d.coolMinCPU
        coolSpareFrontmost = try c.decodeIfPresent(Bool.self, forKey: .coolSpareFrontmost) ?? d.coolSpareFrontmost
        coolNotify = try c.decodeIfPresent(Bool.self, forKey: .coolNotify) ?? d.coolNotify
        coolExclusions = try c.decodeIfPresent(String.self, forKey: .coolExclusions) ?? d.coolExclusions
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? d.keepAwake
        keepDisplayAwake = try c.decodeIfPresent(Bool.self, forKey: .keepDisplayAwake) ?? d.keepDisplayAwake
    }

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: "settings"),
              let saved = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return saved
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "settings") }
    }
}

/// Готовые наборы настроек. На Mac без вентилятора охлаждение — это управление тем, сколько тепла выделяется.
enum Profile: String, CaseIterable, Identifiable {
    case cool, balanced, full
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cool: return "Прохладный"
        case .balanced: return "Сбалансированный"
        case .full: return "Максимум"
        }
    }

    var icon: String {
        switch self {
        case .cool: return "snowflake"
        case .balanced: return "circle.lefthalf.filled"
        case .full: return "bolt.fill"
        }
    }

    var summary: String {
        switch self {
        case .cool: return "Энергосбережение включено, фоновые приложения замедляются уже с 70°."
        case .balanced: return "Полная мощность, автоохлаждение срабатывает с 85°."
        case .full: return "Без ограничений, Mac не засыпает. Корпус будет горячим."
        }
    }

    var lowPower: Bool { self == .cool }
}

// MARK: - Сбор данных в фоне

final class Sampler {
    private let queue = DispatchQueue(label: "local.hwmonitor.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var prepared = false
    private var smc: SMC?
    private var sensors: SensorReader?
    private var ioreport: IOReportSampler?
    private let cpuReader = CPULoadReader()
    private let memoryReader = MemoryReader()
    private let netReader = NetReader()
    private let diskReader = DiskReader()
    private let thermal = ThermalReader()
    private let processes = ProcessSampler()
    private let topology: CPUTopology
    private var tick = 0
    private var lastProcessPass = 0.0
    private var battery: BatterySample?
    private var allSensors = false
    private var wantProcesses = true

    var onSnapshot: ((Snapshot) -> Void)?
    var onProcesses: (([ProcInfo]) -> Void)?

    init(topology: CPUTopology) {
        self.topology = topology
    }

    func start(interval: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.prepared {
                self.prepared = true
                self.smc = SMC()
                self.sensors = self.smc.map { SensorReader(smc: $0) }
                self.ioreport = IOReportSampler()
            }
            self.timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.fire() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Что сейчас нужно интерфейсу: все датчики читаются только для раздела «Датчики»,
    /// процессы — только когда их кто-то видит или работает автоохлаждение.
    func setDemand(allSensors: Bool, processes: Bool) {
        queue.async {
            let resumed = processes && !self.wantProcesses
            self.allSensors = allSensors
            self.wantProcesses = processes
            if resumed { self.passProcesses() }
        }
    }

    /// Внеочередной проход по процессам — чтобы действие пользователя сразу отразилось в таблице.
    func refreshProcesses() {
        queue.asyncAfter(deadline: .now() + 0.25) { self.passProcesses() }
    }

    private func fire() {
        let snapshot = collect()
        DispatchQueue.main.async { self.onSnapshot?(snapshot) }
        if wantProcesses, ProcessInfo.processInfo.systemUptime - lastProcessPass >= 2.9 { passProcesses() }
    }

    private func passProcesses() {
        lastProcessPass = ProcessInfo.processInfo.systemUptime
        let list = processes.sample()
        DispatchQueue.main.async { self.onProcesses?(list) }
    }

    private func collect() -> Snapshot {
        var s = Snapshot()
        let usage = cpuReader.sample()
        let io = ioreport?.sample()

        var pIndex = 0, eIndex = 0
        var pLoad = 0.0, eLoad = 0.0
        var pFreq = 0.0, pActive = 0.0, eFreq = 0.0, eActive = 0.0
        for (i, isP) in topology.isP.enumerated() {
            var core = CoreSample(id: i, isP: isP, usage: i < usage.count ? usage[i] : 0)
            let stat = isP ? io?.p[pIndex] : io?.e[eIndex]
            core.mhz = stat?.mhz
            if let stat, let mhz = stat.mhz {
                if isP {
                    pFreq += stat.active * mhz
                    pActive += stat.active
                } else {
                    eFreq += stat.active * mhz
                    eActive += stat.active
                }
            }
            if isP {
                pIndex += 1
                pLoad += core.usage
            } else {
                eIndex += 1
                eLoad += core.usage
            }
            s.cores.append(core)
        }
        s.cpuP = pLoad / Double(max(1, topology.pCount))
        s.cpuE = eLoad / Double(max(1, topology.eCount))
        s.cpuTotal = (pLoad + eLoad) / Double(max(1, topology.isP.count))
        s.freqP = pActive > 0 ? pFreq / pActive : nil
        s.freqE = eActive > 0 ? eFreq / eActive : nil
        s.maxFreqP = ioreport?.pTable.last
        s.maxFreqE = ioreport?.eTable.last

        if let sensors {
            // Раз в пять замеров читаем всё, чтобы минимумы и максимумы копились и в фоне.
            let temps = sensors.readTemps(all: allSensors || tick % 5 == 0)
            func hottest(_ group: SensorGroup) -> Double? {
                temps.lazy.filter { $0.group == group }.map(\.value).max()
            }
            s.temps = temps
            s.tempCPU = [hottest(.cpuP), hottest(.cpuE)].compactMap { $0 }.max()
            s.tempGPU = hottest(.gpu)
            s.tempSoC = [s.tempCPU, s.tempGPU].compactMap { $0 }.max()
            s.tempBattery = hottest(.battery)
            s.tempSSD = hottest(.ssd)

            let rails = sensors.readRails(all: allSensors)
            func rail(_ key: String) -> Double? { rails.first { $0.key == key }?.watts }
            s.rails = rails
            s.powerSystem = rail("PSTR")
            s.powerBattery = rail("PPBR")
            s.powerAdapter = rail("PDTR")
            s.powerSoC = io?.cpuWatts ?? rail("PHPS")
            s.fans = sensors.readFans()
        }
        s.powerGPU = io?.gpuWatts
        s.gpuActive = io?.gpuActive
        s.gpu = readGPU()
        s.mem = memoryReader.sample()
        s.disk = diskReader.sample()
        s.net = netReader.sample()
        if tick % 5 == 0 { battery = readBattery() }
        s.battery = battery
        s.thermalLevel = thermal.level()
        s.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        tick += 1
        return s
    }
}

// MARK: - Процессы для интерфейса

struct ProcRow: Identifiable, Equatable {
    let id: String
    let mainPid: pid_t
    let isGroup: Bool
    var name: String
    var pids: [pid_t]
    var cpu: Double
    var mem: UInt64
    var power: Double
    var pShare: Double
    var owned: Bool
    var throttled: Bool
    var stopped: Bool
}

@MainActor
final class ProcessStore: ObservableObject {
    @Published fileprivate(set) var grouped: [ProcRow] = []
    @Published fileprivate(set) var flat: [ProcRow] = []
    @Published fileprivate(set) var throttledCount = 0
    @Published fileprivate(set) var stoppedCount = 0
}

/// Текст в строке меню живёт отдельно от замеров: значок перерисовывает системный процесс,
/// и дёргать его каждую секунду без изменения текста незачем.
@MainActor
final class MenuBarState: ObservableObject {
    @Published fileprivate(set) var title = ""
}

struct CoolingEvent: Identifiable {
    let id = UUID()
    let time: Date
    let text: String
}

/// Значки и названия приложений по pid.
@MainActor
final class AppIcons {
    static let shared = AppIcons()
    private var cache: [pid_t: (name: String?, icon: NSImage?)] = [:]

    func info(_ pid: pid_t) -> (name: String?, icon: NSImage?) {
        if let cached = cache[pid] { return cached }
        if cache.count > 3000 { cache.removeAll() }
        let app = NSRunningApplication(processIdentifier: pid)
        let value = (app?.localizedName, app?.icon)
        cache[pid] = value
        return value
    }
}

// MARK: - Модель приложения

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    /// Замер, который видит интерфейс. Обновляется, только пока открыто окно или меню:
    /// иначе SwiftUI каждую секунду пересчитывал бы графики, которых никто не видит.
    @Published private(set) var snap = Snapshot()
    @Published private(set) var chart: [HistoryPoint] = []
    private(set) var extremes: [String: ClosedRange<Double>] = [:]
    @Published var settings: AppSettings {
        didSet { if settings != oldValue { settingsChanged(from: oldValue) } }
    }
    @Published var page = Page.overview {
        didSet { updateDemand() }
    }
    var windowVisible = false {
        didSet { if windowVisible != oldValue { visibilityChanged() } }
    }
    /// Спрашивает у приложения, видно ли сейчас главное окно.
    var visibilityProbe: (() -> Bool)?
    var popoverVisible = false {
        didSet { if popoverVisible != oldValue { visibilityChanged() } }
    }
    @Published private(set) var lowPower = LowPowerSetting()
    @Published private(set) var lowPowerBusy = false
    @Published private(set) var coolingActive = false
    @Published private(set) var events: [CoolingEvent] = []
    @Published private(set) var loginItem = false
    @Published var alert: String?

    let topology = CPUTopology.read()
    let processes = ProcessStore()
    let menuBar = MenuBarState()

    private let sampler: Sampler
    private let keepAwake = KeepAwake()
    private var latest = Snapshot()
    private var history: [HistoryPoint] = []
    private var sequence = 0
    private var procs: [ProcInfo] = []
    private var throttledPids = Set<pid_t>()
    private var throttledGroups = Set<pid_t>()
    private var autoPids = Set<pid_t>()
    private var autoGroups = Set<pid_t>()
    private var suspendedPids = Set<pid_t>()
    private var hotStreak = 0
    private var calmStreak: [pid_t: Int] = [:]
    private var lastMenuBarUpdate = 0.0

    /// Приостановка этих процессов «заморозит» интерфейс системы.
    private static let vital: Set<String> = [
        "HWMonitor", "loginwindow", "WindowServer", "Dock", "Finder", "SystemUIServer", "ControlCenter", "launchd",
    ]

    private init() {
        settings = AppSettings.load()
        sampler = Sampler(topology: topology)
        recoverFromPreviousRun()
        sampler.onSnapshot = { [weak self] snapshot in
            MainActor.assumeIsolated { self?.ingest(snapshot) }
        }
        sampler.onProcesses = { [weak self] list in
            MainActor.assumeIsolated { self?.ingest(processes: list) }
        }
        sampler.start(interval: settings.interval)
        updateDemand()
        keepAwake.apply(system: settings.keepAwake, display: settings.keepDisplayAwake)
        loginItem = LoginItem.enabled
        refreshLowPower()
    }

    // MARK: Замеры

    var window: ClosedRange<Date> {
        snap.time.addingTimeInterval(-Double(settings.windowMinutes) * 60)...snap.time
    }

    private var menuBarTitle: String {
        switch settings.menuBar {
        case .tempCPU: return "\(fmtTemp(latest.tempSoC)) \(fmtPct(latest.cpuTotal))"
        case .temp: return fmtTemp(latest.tempSoC)
        case .cpu: return fmtPct(latest.cpuTotal)
        case .power: return fmtWatts(latest.powerSystem)
        case .icon: return ""
        }
    }

    /// Значок в строке меню перерисовывает системный процесс — обновляем текст не чаще раза в 2 с.
    private func updateMenuBar(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastMenuBarUpdate >= 1.9 else { return }
        let title = menuBarTitle
        if menuBar.title != title {
            menuBar.title = title
            lastMenuBarUpdate = now
        }
    }

    private func updateDemand() {
        let touched = !throttledPids.isEmpty || !suspendedPids.isEmpty
        sampler.setDemand(allSensors: windowVisible && page == .sensors,
                          processes: windowVisible || popoverVisible || settings.autoCool || touched)
    }

    private func ingest(_ s: Snapshot) {
        if s.lowPower != latest.lowPower { refreshLowPower() }
        latest = s
        if let visibilityProbe { windowVisible = visibilityProbe() }
        updateMenuBar()

        var values = [Double](repeating: .nan, count: Metric.allCases.count)
        func put(_ metric: Metric, _ value: Double?) {
            if let value { values[metric.rawValue] = value }
        }
        put(.cpu, s.cpuTotal * 100)
        put(.cpuP, s.cpuP * 100)
        put(.cpuE, s.cpuE * 100)
        put(.gpu, (s.gpu.utilization ?? s.gpuActive).map { $0 * 100 })
        put(.tempCPU, s.tempCPU)
        put(.tempGPU, s.tempGPU)
        put(.powerSystem, s.powerSystem)
        put(.memUsed, Double(s.mem.used) / 1_073_741_824)
        put(.netIn, s.net.inRate)
        put(.netOut, s.net.outRate)
        put(.diskRead, s.disk.readRate)
        put(.diskWrite, s.disk.writeRate)
        sequence += 1
        history.append(HistoryPoint(id: sequence, t: s.time, values: values))
        let cutoff = s.time.addingTimeInterval(-15 * 60)
        if let first = history.first, first.t < cutoff { history.removeAll { $0.t < cutoff } }

        for reading in s.temps {
            if let range = extremes[reading.key] {
                if reading.value < range.lowerBound || reading.value > range.upperBound {
                    extremes[reading.key] = min(range.lowerBound, reading.value)...max(range.upperBound, reading.value)
                }
            } else {
                extremes[reading.key] = reading.value...reading.value
            }
        }
        if windowVisible || popoverVisible { publish() }
    }

    private func publish() {
        snap = latest
        if windowVisible { rebuildChart() }
    }

    private func visibilityChanged() {
        updateDemand()
        if windowVisible || popoverVisible { publish() }
    }

    /// Точки для графиков: окно показа, прореженное до ~120 точек, чтобы монитор сам не грел чип.
    private func rebuildChart() {
        let seconds = Double(settings.windowMinutes) * 60
        let start = latest.time.addingTimeInterval(-seconds)
        let slice = history.drop { $0.t < start }
        let bucket = max(1, Int((seconds / settings.interval / 120).rounded(.up)))
        guard bucket > 1 else {
            chart = Array(slice)
            return
        }
        var result: [HistoryPoint] = []
        var group: [HistoryPoint] = []
        func flush() {
            guard let last = group.last else { return }
            var values = [Double](repeating: .nan, count: last.values.count)
            for i in values.indices {
                let known = group.map { $0.values[i] }.filter { !$0.isNaN }
                if !known.isEmpty { values[i] = known.reduce(0, +) / Double(known.count) }
            }
            result.append(HistoryPoint(id: last.id / bucket, t: last.t, values: values))
            group.removeAll(keepingCapacity: true)
        }
        for point in slice {
            if let last = group.last, last.id / bucket != point.id / bucket { flush() }
            group.append(point)
        }
        flush()
        chart = result
    }

    func resetExtremes() {
        objectWillChange.send()
        extremes.removeAll()
    }

    // MARK: Процессы

    private func ingest(processes list: [ProcInfo]) {
        procs = list
        let alive = Set(list.map(\.pid))
        throttledPids.formIntersection(alive)
        autoPids.formIntersection(alive)
        suspendedPids.formIntersection(alive)
        let owners = Set(list.map(\.responsible))
        throttledGroups.formIntersection(owners)
        autoGroups.formIntersection(owners)

        // Приложение могло запустить новые процессы — они тоже должны остаться на экономичных ядрах.
        for proc in list where proc.owned && throttledGroups.contains(proc.responsible) && !throttledPids.contains(proc.pid) {
            if ProcessControl.setBackground(proc.pid, true) {
                throttledPids.insert(proc.pid)
                if autoGroups.contains(proc.responsible) { autoPids.insert(proc.pid) }
            }
        }
        rebuildRows()
        evaluateCooling()
        persistTouched()
    }

    private func rebuildRows() {
        var groups: [pid_t: [ProcInfo]] = [:]
        for proc in procs { groups[proc.owned ? proc.responsible : proc.pid, default: []].append(proc) }
        processes.grouped = groups.map { row(owner: $0.key, members: $0.value, isGroup: true) }
        processes.flat = procs.map { row(owner: $0.pid, members: [$0], isGroup: false) }
        processes.throttledCount = throttledPids.count
        processes.stoppedCount = procs.filter(\.stopped).count
    }

    private func row(owner: pid_t, members: [ProcInfo], isGroup: Bool) -> ProcRow {
        let lead = members.first { $0.pid == owner } ?? members[0]
        var name = lead.name
        if isGroup, let appName = AppIcons.shared.info(owner).name { name = appName }
        let cpu = members.reduce(0) { $0 + $1.cpu }
        let known = members.filter { $0.pShare >= 0 && $0.cpu > 0 }
        let knownCPU = known.reduce(0) { $0 + $1.cpu }
        let pShare = knownCPU > 0 ? known.reduce(0) { $0 + $1.pShare * $1.cpu } / knownCPU : -1
        let pids = members.map(\.pid)
        return ProcRow(id: (isGroup ? "g" : "p") + String(owner), mainPid: owner, isGroup: isGroup, name: name,
                       pids: pids, cpu: cpu, mem: members.reduce(0) { $0 + $1.mem },
                       power: members.reduce(0) { $0 + $1.power }, pShare: pShare, owned: lead.owned,
                       throttled: isGroup && throttledGroups.contains(owner) || pids.allSatisfy(throttledPids.contains),
                       stopped: members.allSatisfy(\.stopped))
    }

    func setThrottled(_ row: ProcRow, _ on: Bool) {
        applyThrottle(row, on, auto: false)
        rebuildRows()
        persistTouched()
    }

    private func applyThrottle(_ row: ProcRow, _ on: Bool, auto: Bool) {
        for pid in row.pids where pid != getpid() {
            guard ProcessControl.setBackground(pid, on) else { continue }
            if on {
                throttledPids.insert(pid)
                if auto { autoPids.insert(pid) }
            } else {
                throttledPids.remove(pid)
                autoPids.remove(pid)
            }
        }
        guard row.isGroup else { return }
        if on {
            throttledGroups.insert(row.mainPid)
            if auto { autoGroups.insert(row.mainPid) }
        } else {
            throttledGroups.remove(row.mainPid)
            autoGroups.remove(row.mainPid)
        }
    }

    func setSuspended(_ row: ProcRow, _ on: Bool) {
        if on, AppModel.vital.contains(row.name) {
            alert = "«\(row.name)» нужен системе для работы интерфейса — приостанавливать его нельзя."
            return
        }
        for pid in row.pids where pid != getpid() {
            if on {
                if ProcessControl.suspend(pid) { suspendedPids.insert(pid) }
            } else if ProcessControl.resume(pid) {
                suspendedPids.remove(pid)
            }
        }
        persistTouched()
        sampler.refreshProcesses()
    }

    func quit(_ row: ProcRow, force: Bool) {
        if force {
            for pid in row.pids where pid != getpid() { ProcessControl.forceQuit(pid) }
        } else {
            ProcessControl.quit(row.mainPid)
        }
        sampler.refreshProcesses()
    }

    /// Возвращает обычный приоритет всем замедленным процессам.
    func releaseAllThrottled() {
        for pid in throttledPids { _ = ProcessControl.setBackground(pid, false) }
        throttledPids.removeAll()
        throttledGroups.removeAll()
        autoPids.removeAll()
        autoGroups.removeAll()
        coolingActive = false
        rebuildRows()
        persistTouched()
    }

    // MARK: Автоохлаждение

    private func evaluateCooling() {
        guard settings.autoCool else {
            if coolingActive || !autoPids.isEmpty { releaseAuto(note: nil) }
            return
        }
        guard let temp = latest.tempSoC else { return }
        let pressured = settings.coolOnPressure && latest.thermalLevel >= 1
        let hot = temp >= settings.coolThreshold || pressured
        hotStreak = hot ? hotStreak + 1 : 0

        // Два замера подряд, чтобы не реагировать на короткий всплеск; при сильном перегреве — сразу:
        // без вентилятора чип набирает десятки градусов за секунды.
        if hotStreak >= 2 || (hot && temp >= settings.coolThreshold + 10) {
            let victims = coolingCandidates()
            for row in victims { applyThrottle(row, true, auto: true) }
            if !victims.isEmpty {
                let names = victims.map(\.name).joined(separator: ", ")
                log("\(fmtTemp(temp)): замедлены \(names)")
                if settings.coolNotify {
                    Notifier.post(title: "Автоохлаждение: \(fmtTemp(temp))",
                                  body: "Переведены на экономичные ядра: \(names).")
                }
            }
        }

        // Приоритет возвращаем, когда приложение закончило тяжёлую работу или пользователь перешёл к нему.
        // Просто по остыванию возвращать нельзя: нагрузка тут же раскалит чип снова.
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let cooled = temp <= settings.coolThreshold - 10 && latest.thermalLevel == 0
        var released: [String] = []
        for row in processes.grouped where autoGroups.contains(row.mainPid) {
            let switchedTo = settings.coolSpareFrontmost && row.mainPid == front
            let calm = cooled && row.cpu < settings.coolMinCPU
            calmStreak[row.mainPid] = calm ? (calmStreak[row.mainPid] ?? 0) + 1 : 0
            if switchedTo || (calmStreak[row.mainPid] ?? 0) >= 3 {
                applyThrottle(row, false, auto: true)
                calmStreak[row.mainPid] = nil
                released.append(row.name)
            }
        }
        calmStreak = calmStreak.filter { autoGroups.contains($0.key) }
        if !released.isEmpty {
            let note = "\(fmtTemp(temp)): приоритет возвращён — \(released.joined(separator: ", "))"
            log(note)
            if settings.coolNotify { Notifier.post(title: "Автоохлаждение", body: note) }
        }
        coolingActive = !autoGroups.isEmpty
        rebuildRows()
    }

    private func coolingCandidates() -> [ProcRow] {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let excluded = Set(settings.coolExclusions.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        return processes.grouped
            .filter { row in
                row.owned && !row.throttled && !row.stopped && row.cpu >= settings.coolMinCPU
                    && !row.pids.contains(getpid())
                    && !(settings.coolSpareFrontmost && row.mainPid == front)
                    && !AppModel.vital.contains(row.name)
                    && !excluded.contains(row.name.lowercased())
            }
            .sorted { $0.cpu > $1.cpu }
            .prefix(3)
            .map { $0 }
    }

    private func releaseAuto(note: String?) {
        for pid in autoPids {
            if ProcessControl.setBackground(pid, false) { throttledPids.remove(pid) }
        }
        throttledGroups.subtract(autoGroups)
        autoPids.removeAll()
        autoGroups.removeAll()
        coolingActive = false
        hotStreak = 0
        calmStreak.removeAll()
        if let note {
            log(note)
            if settings.coolNotify { Notifier.post(title: "Автоохлаждение", body: note) }
        }
        rebuildRows()
    }

    private func log(_ text: String) {
        NSLog("HWMonitor: %@", text)
        events.insert(CoolingEvent(time: Date(), text: text), at: 0)
        if events.count > 30 { events.removeLast(events.count - 30) }
    }

    // MARK: Питание и настройки

    func refreshLowPower() {
        DispatchQueue.global(qos: .utility).async {
            let value = PowerMode.read()
            DispatchQueue.main.async { self.lowPower = value }
        }
    }

    /// Меняет режим энергосбережения; nil — источник питания не трогаем.
    func setLowPower(battery: Bool?, ac: Bool?) {
        let b = battery == lowPower.battery ? nil : battery
        let a = ac == lowPower.ac ? nil : ac
        guard b != nil || a != nil, !lowPowerBusy else { return }
        lowPowerBusy = true
        PowerMode.set(battery: b, ac: a) { [weak self] outcome in
            guard let self else { return }
            self.lowPowerBusy = false
            if case .failed(let message) = outcome {
                self.alert = "Не удалось изменить режим энергосбережения.\n\(message)"
            }
            self.refreshLowPower()
        }
    }

    var activeProfile: Profile? {
        let lowBoth = lowPower.battery && lowPower.ac
        let lowNone = !lowPower.battery && !lowPower.ac
        if lowBoth, settings.autoCool, settings.coolThreshold == 70 { return .cool }
        if lowNone, settings.autoCool, settings.coolThreshold == 85, !settings.keepAwake { return .balanced }
        if lowNone, !settings.autoCool, settings.keepAwake { return .full }
        return nil
    }

    func apply(_ profile: Profile) {
        var s = settings
        switch profile {
        case .cool:
            s.autoCool = true
            s.coolThreshold = 70
            s.coolMinCPU = 15
            s.keepAwake = false
        case .balanced:
            s.autoCool = true
            s.coolThreshold = 85
            s.coolMinCPU = 25
            s.keepAwake = false
        case .full:
            s.autoCool = false
            s.keepAwake = true
        }
        settings = s
        setLowPower(battery: profile.lowPower, ac: profile.lowPower)
    }

    func setLoginItem(_ on: Bool) {
        do {
            try LoginItem.set(on)
        } catch {
            alert = "Не удалось изменить автозапуск: \(error.localizedDescription)"
        }
        loginItem = LoginItem.enabled
    }

    private func settingsChanged(from old: AppSettings) {
        settings.save()
        if settings.interval != old.interval { sampler.start(interval: settings.interval) }
        if settings.menuBar != old.menuBar { updateMenuBar(force: true) }
        if settings.autoCool != old.autoCool { updateDemand() }
        if settings.windowMinutes != old.windowMinutes || settings.interval != old.interval { rebuildChart() }
        if settings.keepAwake != old.keepAwake || settings.keepDisplayAwake != old.keepDisplayAwake {
            keepAwake.apply(system: settings.keepAwake, display: settings.keepDisplayAwake)
        }
        if settings.autoCool, settings.coolNotify, !(old.autoCool && old.coolNotify) { Notifier.requestAuthorization() }
        if !settings.autoCool, old.autoCool { releaseAuto(note: nil) }
    }

    // MARK: Завершение работы

    /// Замедленные и приостановленные процессы нельзя бросать в таком виде, когда монитор закрывается.
    func shutdown() {
        for pid in throttledPids { _ = ProcessControl.setBackground(pid, false) }
        for pid in suspendedPids { _ = ProcessControl.resume(pid) }
        keepAwake.apply(system: false, display: false)
        UserDefaults.standard.removeObject(forKey: "throttledPids")
        UserDefaults.standard.removeObject(forKey: "suspendedPids")
    }

    private func persistTouched() {
        updateDemand()
        UserDefaults.standard.set(throttledPids.map { Int($0) }, forKey: "throttledPids")
        UserDefaults.standard.set(suspendedPids.map { Int($0) }, forKey: "suspendedPids")
    }

    /// Если прошлый запуск упал, возвращаем тронутым процессам обычное состояние.
    private func recoverFromPreviousRun() {
        let defaults = UserDefaults.standard
        for value in defaults.array(forKey: "throttledPids") as? [Int] ?? [] {
            _ = ProcessControl.setBackground(pid_t(value), false)
        }
        for value in defaults.array(forKey: "suspendedPids") as? [Int] ?? [] {
            _ = ProcessControl.resume(pid_t(value))
        }
        defaults.removeObject(forKey: "throttledPids")
        defaults.removeObject(forKey: "suspendedPids")
    }
}
