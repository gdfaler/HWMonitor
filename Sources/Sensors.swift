import Foundation

enum SensorGroup: Int, CaseIterable, Identifiable {
    case cpuP, cpuE, gpu, soc, battery, ssd, wifi, chassis, pmu, model, other
    var id: Int { rawValue }
}

struct TempReading: Identifiable {
    let key: String
    let group: SensorGroup
    var value: Double
    var id: String { key }
}

struct RailReading: Identifiable {
    let key: String
    var watts: Double
    var id: String { key }
}

struct FanReading: Identifiable {
    let id: Int
    var rpm: Double
    var min: Double
    var max: Double
}

/// Находит на этой машине живые датчики SMC и читает их каждый тик.
final class SensorReader {
    private let smc: SMC
    private var temps: [(code: UInt32, key: String, group: SensorGroup)] = []
    private var rails: [(code: UInt32, key: String)] = []
    private var fanCount = 0

    /// Не температуры, а пороги и флаги термомодели.
    private static let skipped: Set<String> = ["TVmS", "TVMD"]

    /// Каждый запрос к SMC стоит ~0,3 мс, поэтому постоянно читается только главное.
    private static let coreGroups: Set<SensorGroup> = [.cpuP, .cpuE, .gpu, .battery, .ssd]
    static let coreRails: Set<String> = ["PSTR", "PHPS", "PDTR", "PPBR"]

    init(smc: SMC) {
        self.smc = smc
        for key in smc.allKeys() {
            if key.hasPrefix("T") {
                guard smc.type(of: key) == "flt ", !SensorReader.skipped.contains(key),
                      let v = smc.read(key), v > 1, v < 150 else { continue }
                temps.append((fourCC(key), key, SensorReader.classify(key)))
            } else if key.hasPrefix("P") {
                guard smc.type(of: key) == "flt ", smc.read(key) != nil else { continue }
                rails.append((fourCC(key), key))
            }
        }
        temps.sort { ($0.group.rawValue, $0.key) < ($1.group.rawValue, $1.key) }
        fanCount = Int(smc.read("FNum") ?? 0)
    }

    /// Имена ключей у Apple не документированы; группы проверены нагрузочным тестом на M5.
    static func classify(_ key: String) -> SensorGroup {
        if key.hasPrefix("Tp") { return .cpuP }
        if key.hasPrefix("Te") { return .cpuE }
        if key.hasPrefix("Tg") { return .gpu }
        if key == "Ts0P" || key == "Ts1P" { return .chassis }
        if key.hasPrefix("Ts") || key.hasPrefix("Ta") { return .soc }
        if key.hasPrefix("TB") { return .battery }
        if key.hasPrefix("TH") { return .ssd }
        if key.hasPrefix("TW") { return .wifi }
        if key.hasPrefix("TPD") || key.hasPrefix("TRD") { return .pmu }
        if key.hasPrefix("TV") { return .model }
        return .other
    }

    func readTemps(all: Bool) -> [TempReading] {
        temps.compactMap { t in
            guard all || SensorReader.coreGroups.contains(t.group),
                  let v = smc.read(t.code), v > 1, v < 150 else { return nil }
            return TempReading(key: t.key, group: t.group, value: v)
        }
    }

    func readRails(all: Bool) -> [RailReading] {
        rails.compactMap { r in
            guard all || SensorReader.coreRails.contains(r.key),
                  let v = smc.read(r.code), v.isFinite else { return nil }
            return RailReading(key: r.key, watts: v)
        }
    }

    func readFans() -> [FanReading] {
        guard fanCount > 0 else { return [] }
        return (0..<fanCount).compactMap { i in
            guard let rpm = smc.read("F\(i)Ac") else { return nil }
            return FanReading(id: i, rpm: rpm, min: smc.read("F\(i)Mn") ?? 0, max: smc.read("F\(i)Mx") ?? 0)
        }
    }
}
