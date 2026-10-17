import Foundation
import IOKit
import notify

// MARK: - sysctl и IORegistry

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}

func sysctlInt(_ name: String) -> Int? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return size == 4 ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
}

func registryProperty(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

// MARK: - Процессор

struct CPUTopology {
    var isP: [Bool]      // по логическому номеру ядра
    var pName: String    // как macOS называет быстрые ядра («Super» на M5)
    var eName: String
    var chip: String
    var model: String
    var memBytes: UInt64

    var pCount: Int { isP.filter { $0 }.count }
    var eCount: Int { isP.count - pCount }

    static func read() -> CPUTopology {
        let count = ProcessInfo.processInfo.processorCount
        var kinds: [Bool] = []
        for i in 0..<count {
            let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus/cpu\(i)")
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            guard let data = registryProperty(entry, "cluster-type") as? Data, let first = data.first else { break }
            kinds.append(first == UInt8(ascii: "P"))
        }
        if kinds.count != count {
            // Запасной вариант: на Apple Silicon экономичные ядра идут первыми.
            let e = sysctlInt("hw.perflevel1.logicalcpu") ?? 0
            kinds = (0..<count).map { $0 >= e }
        }

        var model = sysctlString("hw.model") ?? "Mac"
        let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        if product != 0 {
            if let data = registryProperty(product, "product-name") as? Data,
               let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
               !name.isEmpty {
                model = name
            }
            IOObjectRelease(product)
        }

        return CPUTopology(isP: kinds,
                           pName: sysctlString("hw.perflevel0.name") ?? "Performance",
                           eName: sysctlString("hw.perflevel1.name") ?? "Efficiency",
                           chip: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
                           model: model,
                           memBytes: ProcessInfo.processInfo.physicalMemory)
    }
}

/// Загрузка каждого ядра по счётчикам тиков ядра.
final class CPULoadReader {
    private let host = mach_host_self()
    private var previous: [(busy: UInt64, total: UInt64)] = []

    func sample() -> [Double] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var current: [(busy: UInt64, total: UInt64)] = []
        for i in 0..<Int(cpuCount) {
            let base = Int(CPU_STATE_MAX) * i
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            current.append((user + system + nice, user + system + nice + idle))
        }
        defer { previous = current }
        guard previous.count == current.count else { return current.map { _ in 0 } }
        return zip(previous, current).map { old, new in
            let total = new.total &- old.total
            return total > 0 ? min(1, Double(new.busy &- old.busy) / Double(total)) : 0
        }
    }
}

// MARK: - Память

struct MemSample {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure = 1   // 1 норма, 2 предупреждение, 4 критично

    var used: UInt64 { app + wired + compressed }
    var free: UInt64 { total > used + cached ? total - used - cached : 0 }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

final class MemoryReader {
    private let host = mach_host_self()

    func sample() -> MemSample {
        var result = MemSample()
        result.total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            // Те же формулы, что в «Мониторинге системы».
            let page = UInt64(vm_kernel_page_size)
            let purgeable = UInt64(stats.purgeable_count)
            let internalPages = UInt64(stats.internal_page_count)
            result.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            result.wired = UInt64(stats.wire_count) * page
            result.compressed = UInt64(stats.compressor_page_count) * page
            result.cached = (UInt64(stats.external_page_count) + purgeable) * page
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            result.swapUsed = swap.xsu_used
            result.swapTotal = swap.xsu_total
        }
        result.pressure = sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1
        return result
    }
}

// MARK: - GPU

struct GPUSample {
    var name = "GPU"
    var utilization: Double?   // 0...1
    var renderer: Double?
    var tiler: Double?
    var memInUse: UInt64 = 0
    var memAllocated: UInt64 = 0
}

func readGPU() -> GPUSample {
    var result = GPUSample()
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
        return result
    }
    defer { IOObjectRelease(iterator) }
    while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }
        guard let stats = registryProperty(service, "PerformanceStatistics") as? [String: Any] else { continue }
        func percent(_ key: String) -> Double? { (stats[key] as? NSNumber).map { $0.doubleValue / 100 } }
        result.utilization = percent("Device Utilization %")
        result.renderer = percent("Renderer Utilization %")
        result.tiler = percent("Tiler Utilization %")
        result.memInUse = (stats["In use system memory"] as? NSNumber)?.uint64Value ?? 0
        result.memAllocated = (stats["Alloc system memory"] as? NSNumber)?.uint64Value ?? 0
        if let model = registryProperty(service, "model") as? String { result.name = model }
        break
    }
    return result
}

// MARK: - Диск

struct DiskSample {
    var total: UInt64 = 0
    var available: UInt64 = 0
    var readRate = 0.0    // байт/с
    var writeRate = 0.0
    var used: UInt64 { total > available ? total - available : 0 }
}

final class DiskReader {
    private var previous: (read: UInt64, written: UInt64)?
    private var previousTime = 0.0
    private var capacity: (total: UInt64, available: UInt64) = (0, 0)
    private var pass = 0

    func sample() -> DiskSample {
        var result = DiskSample()
        // Свободное место меняется медленно — пересчитываем раз в 10 тиков.
        if pass % 10 == 0 {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            if let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
                capacity = (UInt64(values.volumeTotalCapacity ?? 0),
                            UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0)))
            }
        }
        pass += 1
        result.total = capacity.total
        result.available = capacity.available

        var read: UInt64 = 0
        var written: UInt64 = 0
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS {
            while case let service = IOIteratorNext(iterator), service != 0 {
                if let stats = registryProperty(service, "Statistics") as? [String: Any] {
                    read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                    written += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
                }
                IOObjectRelease(service)
            }
            IOObjectRelease(iterator)
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let prev = previous, now > previousTime, read >= prev.read, written >= prev.written {
            let dt = now - previousTime
            result.readRate = Double(read - prev.read) / dt
            result.writeRate = Double(written - prev.written) / dt
        }
        previous = (read, written)
        previousTime = now
        return result
    }
}

// MARK: - Сеть

struct NetSample {
    var inRate = 0.0    // байт/с
    var outRate = 0.0
    var totalIn: UInt64 = 0   // с запуска монитора
    var totalOut: UInt64 = 0
}

final class NetReader {
    private var previous: [String: (rx: UInt32, tx: UInt32)] = [:]
    private var previousTime = 0.0
    private var totalIn: UInt64 = 0
    private var totalOut: UInt64 = 0

    func sample() -> NetSample {
        var current: [String: (rx: UInt32, tx: UInt32)] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return NetSample() }
        defer { freeifaddrs(list) }
        var cursor = list
        while let item = cursor {
            cursor = item.pointee.ifa_next
            guard let addr = item.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = item.pointee.ifa_data else { continue }
            let name = String(cString: item.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            current[name] = (stats.ifi_ibytes, stats.ifi_obytes)
        }

        let now = ProcessInfo.processInfo.systemUptime
        var deltaIn: UInt64 = 0
        var deltaOut: UInt64 = 0
        for (name, new) in current {
            guard let old = previous[name] else { continue }
            // Счётчики 32-битные и переполняются на 4 ГБ — вычитаем с переносом.
            deltaIn += UInt64(new.rx &- old.rx)
            deltaOut += UInt64(new.tx &- old.tx)
        }
        var result = NetSample()
        if previousTime > 0, now > previousTime {
            let dt = now - previousTime
            result.inRate = Double(deltaIn) / dt
            result.outRate = Double(deltaOut) / dt
            totalIn += deltaIn
            totalOut += deltaOut
        }
        result.totalIn = totalIn
        result.totalOut = totalOut
        previous = current
        previousTime = now
        return result
    }
}

// MARK: - Батарея

struct BatterySample {
    var percent = 0
    var charging = false
    var external = false
    var full = false
    var cycles = 0
    var designCycles = 0
    var designMah = 0
    var fullMah = 0
    var remainingMah = 0
    var volts = 0.0
    var amps = 0.0             // меньше нуля — разряд
    var minutesLeft: Int?      // до разряда либо до полного заряда
    var adapterWatts: Int?
    var adapterName: String?

    var watts: Double { volts * amps }
    var health: Double? {
        designMah > 0 && fullMah > 0 ? min(1, Double(fullMah) / Double(designMah)) : nil
    }
}

func readBattery() -> BatterySample? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    func int(_ key: String) -> Int? { (registryProperty(service, key) as? NSNumber)?.intValue }
    func bool(_ key: String) -> Bool { (registryProperty(service, key) as? NSNumber)?.boolValue ?? false }

    guard let percent = int("CurrentCapacity") else { return nil }
    var result = BatterySample()
    result.percent = percent
    result.charging = bool("IsCharging")
    result.external = bool("ExternalConnected")
    result.full = bool("FullyCharged")
    result.cycles = int("CycleCount") ?? 0
    result.designCycles = int("DesignCycleCount9C") ?? 0
    result.volts = Double(int("Voltage") ?? 0) / 1000
    result.amps = Double(int("Amperage") ?? 0) / 1000
    if let data = registryProperty(service, "BatteryData") as? [String: Any] {
        result.designMah = (data["DesignCapacity"] as? NSNumber)?.intValue ?? 0
        result.fullMah = (data["FullChargeCapacity"] as? NSNumber)?.intValue ?? 0
        result.remainingMah = (data["RemainingCapacity"] as? NSNumber)?.intValue ?? 0
    }
    let key = result.charging ? "AvgTimeToFull" : "AvgTimeToEmpty"
    if let minutes = int(key), minutes > 0, minutes < 65535 { result.minutesLeft = minutes }
    if let adapter = registryProperty(service, "AdapterDetails") as? [String: Any] {
        result.adapterWatts = (adapter["Watts"] as? NSNumber)?.intValue
        result.adapterName = (adapter["Name"] as? String) ?? (adapter["Description"] as? String)
    }
    return result
}

// MARK: - Тепловое состояние

/// Уровень теплового давления macOS: 0 норма, 1 умеренное, 2 сильное, 3 критическое, 4 аварийное.
final class ThermalReader {
    private var token: Int32 = 0
    private var registered = false

    init() {
        registered = notify_register_check("com.apple.system.thermalpressurelevel", &token) == NOTIFY_STATUS_OK
    }

    func level() -> Int {
        var state: UInt64 = 0
        if registered, notify_get_state(token, &state) == NOTIFY_STATUS_OK { return Int(min(state, 4)) }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }
}
