import SwiftUI

// Цвет закреплён за сущностью: быстрые ядра — синий, экономичные — оранжевый, GPU — бирюзовый.
private let pColor = Palette.blue
private let eColor = Palette.orange
private let gpuColor = Palette.aqua

private func pctAxis(_ v: Double) -> String { "\(Int(v))%" }
private func tempAxis(_ v: Double) -> String { "\(Int(v))°" }
private func wattAxis(_ v: Double) -> String { fmtNumber(v, digits: 0) + " Вт" }

private let pctScale = ChartScale.fixed(0...100, ticks: [0, 25, 50, 75, 100])
private let tempScale = ChartScale.fixed(20...110, ticks: [25, 50, 75, 100])

private func memoryScale(_ total: UInt64) -> ChartScale {
    let gb = max(1, Double(total) / 1_073_741_824)
    return .fixed(0...gb, ticks: (0...4).map { gb * Double($0) / 4 })
}

/// Положение температуры на шкале 20–110°.
private func tempFraction(_ t: Double) -> Double { (t - 20) / 90 }

// MARK: - Обзор

struct ThermalBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = model.snap
        let severity = thermalSeverity(s.thermalLevel)
        Card {
            HStack(spacing: 12) {
                Image(systemName: severity.icon).font(.title).foregroundStyle(severity.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Тепловое состояние: \(thermalTitle(s.thermalLevel))")
                        .font(.headline).foregroundStyle(Palette.ink)
                    Text(thermalDetail(s.thermalLevel)).font(.callout).foregroundStyle(Palette.ink2)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(coolingLine(s)).font(.callout).foregroundStyle(Palette.ink2)
                    Text(modeLine(s)).font(.caption).foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private func coolingLine(_ s: Snapshot) -> String {
        if s.fans.isEmpty { return "Пассивное охлаждение · вентилятора нет" }
        return s.fans.map { "Вентилятор \($0.id + 1): \(Int($0.rpm)) об/мин" }.joined(separator: " · ")
    }

    private func modeLine(_ s: Snapshot) -> String {
        var parts: [String] = [s.lowPower ? "Энергосбережение включено" : "Полная мощность"]
        let slowed = model.processes.throttledCount
        if slowed > 0 { parts.append("замедлено процессов: \(slowed)") }
        if model.settings.autoCool { parts.append("автоохлаждение с \(Int(model.settings.coolThreshold))°") }
        return parts.joined(separator: " · ")
    }
}

struct WindowPicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Picker("Период", selection: $model.settings.windowMinutes) {
            Text("1 мин").tag(1)
            Text("5 мин").tag(5)
            Text("15 мин").tag(15)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    private let tiles = [GridItem(.adaptive(minimum: 210), spacing: 12)]
    private let charts = [GridItem(.adaptive(minimum: 380), spacing: 12)]

    var body: some View {
        let s = model.snap
        VStack(alignment: .leading, spacing: 14) {
            ThermalBanner()
            LazyVGrid(columns: tiles, spacing: 12) {
                tempTile(s)
                StatTile(label: "Процессор", value: fmtPct(s.cpuTotal),
                         detail: "\(model.topology.pName) \(fmtPct(s.cpuP)) · \(model.topology.eName) \(fmtPct(s.cpuE))",
                         meter: s.cpuTotal)
                StatTile(label: "Мощность системы", value: fmtWatts(s.powerSystem),
                         detail: "чип \(fmtWatts(s.powerSoC)) · GPU \(fmtWatts(s.powerGPU))")
                memoryTile(s)
                StatTile(label: "GPU", value: fmtPct(s.gpu.utilization ?? s.gpuActive ?? 0),
                         detail: "\(fmtWatts(s.powerGPU)) · \(fmtTemp(s.tempGPU))",
                         meter: s.gpu.utilization ?? s.gpuActive ?? 0, meterColor: gpuColor)
                batteryTile(s)
            }
            HStack {
                Text("История").font(.title3.weight(.semibold)).foregroundStyle(Palette.ink)
                Spacer()
                WindowPicker()
            }
            LazyVGrid(columns: charts, spacing: 12) {
                HistoryChart(title: "Температура", points: model.chart,
                             series: [ChartSeries(name: "CPU", color: pColor, metric: .tempCPU),
                                      ChartSeries(name: "GPU", color: gpuColor, metric: .tempGPU)],
                             window: model.window, scale: tempScale, format: tempAxis)
                HistoryChart(title: "Нагрузка CPU", points: model.chart,
                             series: [ChartSeries(name: model.topology.pName, color: pColor, metric: .cpuP),
                                      ChartSeries(name: model.topology.eName, color: eColor, metric: .cpuE)],
                             window: model.window, scale: pctScale, format: pctAxis)
                HistoryChart(title: "Мощность системы", points: model.chart,
                             series: [ChartSeries(name: "Система", color: pColor, metric: .powerSystem)],
                             window: model.window, scale: .decimal(minimumTop: 10), format: wattAxis)
                HistoryChart(title: "Нагрузка GPU", points: model.chart,
                             series: [ChartSeries(name: "GPU", color: gpuColor, metric: .gpu)],
                             window: model.window, scale: pctScale, format: pctAxis)
            }
            TopProcessesCard()
        }
    }

    private func tempTile(_ s: Snapshot) -> StatTile {
        let t = s.tempSoC
        return StatTile(label: "Температура чипа", value: fmtTemp(t),
                        detail: "CPU \(fmtTemp(s.tempCPU)) · GPU \(fmtTemp(s.tempGPU)) · батарея \(fmtTemp(s.tempBattery))",
                        badge: t.map { (tempSeverity($0), tempLabel($0)) },
                        meter: t.map(tempFraction), meterColor: t.map { tempSeverity($0).color } ?? Palette.blue)
    }

    private func memoryTile(_ s: Snapshot) -> StatTile {
        let badge: (Severity, String) = s.mem.pressure >= 4 ? (.critical, "Не хватает")
            : s.mem.pressure >= 2 ? (.warning, "Давление") : (.good, "Норма")
        return StatTile(label: "Память", value: fmtBytes(s.mem.used),
                        detail: "из \(fmtBytes(s.mem.total)) · своп \(fmtBytes(s.mem.swapUsed))",
                        badge: badge, meter: s.mem.usedFraction)
    }

    private func batteryTile(_ s: Snapshot) -> StatTile {
        guard let b = s.battery else { return StatTile(label: "Батарея", value: "—") }
        var detail: String
        if b.charging {
            detail = "Заряжается" + (b.minutesLeft.map { " · до полного \(fmtMinutes($0))" } ?? "")
        } else if b.external {
            detail = b.full ? "От адаптера · заряжена" : "От адаптера · не заряжается"
        } else {
            detail = "Разряд \(fmtWatts(b.watts))" + (b.minutesLeft.map { " · ещё \(fmtMinutes($0))" } ?? "")
        }
        if s.lowPower { detail += " · экономия" }
        let low = b.percent <= 20 && !b.external
        return StatTile(label: "Батарея", value: "\(b.percent)%", detail: detail,
                        badge: low ? (.warning, "Мало заряда") : nil,
                        meter: Double(b.percent) / 100, meterColor: low ? Palette.warning : Palette.blue)
    }
}

struct TopProcessesCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let top = model.processes.grouped.sorted { $0.cpu > $1.cpu }.prefix(5)
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardTitle("Что нагружает процессор")
                    Spacer()
                    Button("Все процессы") { model.page = .processes }
                        .buttonStyle(.link)
                }
                if top.isEmpty {
                    Text("Собираю данные…").font(.callout).foregroundStyle(Palette.muted)
                }
                ForEach(top) { row in
                    HStack(spacing: 8) {
                        ProcIcon(pid: row.mainPid)
                        Text(row.name).foregroundStyle(Palette.ink).lineLimit(1)
                        if row.throttled {
                            Text("замедлен").font(.caption).foregroundStyle(Palette.muted)
                        }
                        Spacer(minLength: 8)
                        Meter(value: row.cpu / 100 / Double(max(1, model.topology.isP.count)) * 4).frame(width: 120)
                        Text(fmtNumber(row.cpu, digits: 0) + "%")
                            .foregroundStyle(Palette.ink).monospacedDigit().frame(width: 52, alignment: .trailing)
                        Text(fmtBytes(row.mem))
                            .foregroundStyle(Palette.ink2).monospacedDigit().frame(width: 70, alignment: .trailing)
                    }
                    .font(.callout)
                }
                Text("100% — одно ядро целиком. Полоса заполняется на 250%.")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
        }
    }
}

struct ProcIcon: View {
    let pid: pid_t

    var body: some View {
        if let icon = AppIcons.shared.info(pid).icon {
            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
        } else {
            Image(systemName: "gearshape").foregroundStyle(Palette.muted).frame(width: 18, height: 18)
        }
    }
}

// MARK: - Процессор и GPU

struct ClusterCard: View {
    let title: String
    let cores: [CoreSample]
    let usage: Double
    let freq: Double?
    let maxFreq: Double?
    let temp: Double?
    let color: Color

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 12, height: 3).offset(y: -4)
                    CardTitle(title)
                    Spacer()
                    Text(fmtPct(usage)).font(.title2.weight(.semibold)).foregroundStyle(Palette.ink)
                }
                HStack(spacing: 18) {
                    fact("Частота сейчас", freq.map { fmtFreq($0) } ?? "простой")
                    fact("Максимум", fmtFreq(maxFreq))
                    fact("Температура", fmtTemp(temp))
                }
                VStack(spacing: 6) {
                    ForEach(cores) { core in
                        HStack(spacing: 8) {
                            Text("Ядро \(core.id + 1)").foregroundStyle(Palette.ink2).frame(width: 58, alignment: .leading)
                            Meter(value: core.usage, color: color, height: 8)
                            Text(fmtPct(core.usage)).foregroundStyle(Palette.ink).frame(width: 40, alignment: .trailing)
                            Text(core.mhz.map { fmtFreq($0) } ?? "простой")
                                .foregroundStyle(Palette.muted).frame(width: 72, alignment: .trailing)
                        }
                        .font(.caption)
                        .monospacedDigit()
                    }
                }
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(Palette.muted)
            Text(value).font(.callout).foregroundStyle(Palette.ink).monospacedDigit()
        }
    }
}

struct CPUView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = model.snap
        let hottest: (SensorGroup) -> Double? = { group in
            s.temps.lazy.filter { $0.group == group }.map(\.value).max()
        }
        VStack(alignment: .leading, spacing: 12) {
            Text("\(model.topology.chip) · \(model.topology.pCount) \(model.topology.pName) + \(model.topology.eCount) \(model.topology.eName)")
                .font(.callout).foregroundStyle(Palette.ink2)
            HStack(alignment: .top, spacing: 12) {
                ClusterCard(title: "\(model.topology.pName)-ядра", cores: s.cores.filter(\.isP), usage: s.cpuP,
                            freq: s.freqP, maxFreq: s.maxFreqP, temp: hottest(.cpuP), color: pColor)
                ClusterCard(title: "\(model.topology.eName)-ядра", cores: s.cores.filter { !$0.isP }, usage: s.cpuE,
                            freq: s.freqE, maxFreq: s.maxFreqE, temp: hottest(.cpuE), color: eColor)
            }
            HStack {
                Spacer()
                WindowPicker()
            }
            HistoryChart(title: "Нагрузка по кластерам", points: model.chart,
                         series: [ChartSeries(name: model.topology.pName, color: pColor, metric: .cpuP),
                                  ChartSeries(name: model.topology.eName, color: eColor, metric: .cpuE)],
                         window: model.window, scale: pctScale, format: pctAxis, height: 170)
            HStack(alignment: .top, spacing: 12) {
                gpuCard(s)
                HistoryChart(title: "Нагрузка GPU", points: model.chart,
                             series: [ChartSeries(name: "GPU", color: gpuColor, metric: .gpu)],
                             window: model.window, scale: pctScale, format: pctAxis)
            }
        }
    }

    private func gpuCard(_ s: Snapshot) -> some View {
        let load = s.gpu.utilization ?? s.gpuActive ?? 0
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    RoundedRectangle(cornerRadius: 1.5).fill(gpuColor).frame(width: 12, height: 3).offset(y: -4)
                    CardTitle("GPU · \(s.gpu.name)")
                    Spacer()
                    Text(fmtPct(load)).font(.title2.weight(.semibold)).foregroundStyle(Palette.ink)
                }
                Meter(value: load, color: gpuColor, height: 8)
                KeyValue("Рендеринг", s.gpu.renderer.map(fmtPct) ?? "—")
                KeyValue("Тайлер", s.gpu.tiler.map(fmtPct) ?? "—")
                KeyValue("Мощность", fmtWatts(s.powerGPU))
                KeyValue("Температура", fmtTemp(s.tempGPU))
                KeyValue("Память в работе", fmtBytes(s.gpu.memInUse))
                KeyValue("Выделено памяти", fmtBytes(s.gpu.memAllocated))
            }
        }
    }
}

// MARK: - Датчики

private func groupTitle(_ group: SensorGroup, _ topology: CPUTopology) -> String {
    switch group {
    case .cpuP: return "CPU · \(topology.pName)-ядра"
    case .cpuE: return "CPU · \(topology.eName)-ядра"
    case .gpu: return "GPU"
    case .soc: return "Чип: остальные зоны кристалла"
    case .battery: return "Батарея"
    case .ssd: return "SSD"
    case .wifi: return "Wi‑Fi"
    case .chassis: return "Корпус"
    case .pmu: return "Контроллеры питания"
    case .model: return "Термомодель macOS (расчётные значения)"
    case .other: return "Прочие датчики"
    }
}

struct SensorCell: View {
    let reading: TempReading
    let range: ClosedRange<Double>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(reading.key).font(.caption.monospaced()).foregroundStyle(Palette.ink2)
                Spacer(minLength: 4)
                Text(fmtNumber(reading.value, digits: 1) + "°")
                    .font(.callout.weight(.medium)).foregroundStyle(Palette.ink).monospacedDigit()
            }
            Meter(value: tempFraction(reading.value), color: tempSeverity(reading.value).color, height: 4)
            Text(range.map { "\(fmtTemp($0.lowerBound)) – \(fmtTemp($0.upperBound))" } ?? " ")
                .font(.caption2).foregroundStyle(Palette.muted).monospacedDigit()
        }
    }
}

struct SensorGroupCard: View {
    let title: String
    let readings: [TempReading]
    let extremes: [String: ClosedRange<Double>]
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        let hottest = readings.map(\.value).max() ?? 0
        let mean = readings.map(\.value).reduce(0, +) / Double(max(1, readings.count))
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: toggle) {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(Palette.muted).frame(width: 12)
                        CardTitle(title)
                        Text("\(readings.count)").font(.caption).foregroundStyle(Palette.muted)
                        Spacer(minLength: 8)
                        Text("средняя \(fmtTemp(mean)) · макс. \(fmtTemp(hottest))")
                            .font(.callout).foregroundStyle(Palette.ink2).monospacedDigit()
                        StatusBadge(severity: tempSeverity(hottest), label: tempLabel(hottest))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 16)], spacing: 10) {
                        ForEach(readings) { SensorCell(reading: $0, range: extremes[$0.key]) }
                    }
                }
            }
        }
    }
}

struct SensorsView: View {
    @EnvironmentObject var model: AppModel
    @Local private var collapsed: Set<SensorGroup> = [.soc, .pmu, .model, .other]

    private static let namedRails: [(String, String)] = [
        ("PSTR", "Вся система"), ("PHPS", "Чип (оценка)"), ("PDTR", "Вход от адаптера"), ("PPBR", "Батарея"),
    ]

    var body: some View {
        let s = model.snap
        let byGroup = Dictionary(grouping: s.temps, by: \.group)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Датчиков температуры: \(s.temps.count). Диапазон под значением — минимум и максимум с запуска монитора.")
                    .font(.callout).foregroundStyle(Palette.ink2)
                Spacer()
                Button("Сбросить мин./макс.") { model.resetExtremes() }
            }
            if s.temps.isEmpty {
                Card { Text("Датчики SMC недоступны или ещё опрашиваются…").foregroundStyle(Palette.muted) }
            }
            ForEach(SensorGroup.allCases) { group in
                if let readings = byGroup[group] {
                    SensorGroupCard(title: groupTitle(group, model.topology), readings: readings,
                                    extremes: model.extremes, expanded: !collapsed.contains(group)) {
                        if collapsed.contains(group) { collapsed.remove(group) } else { collapsed.insert(group) }
                    }
                }
            }
            fansCard(s)
            railsCard(s)
        }
    }

    private func fansCard(_ s: Snapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                CardTitle("Вентиляторы")
                if s.fans.isEmpty {
                    Text("У этого Mac нет вентиляторов: чип охлаждается пассивно, через корпус. Обороты настраивать нечем — нагрев регулируется нагрузкой, см. раздел «Управление».")
                        .font(.callout).foregroundStyle(Palette.ink2)
                }
                ForEach(s.fans) { fan in
                    KeyValue("Вентилятор \(fan.id + 1)", "\(Int(fan.rpm)) об/мин (\(Int(fan.min))–\(Int(fan.max)))")
                }
            }
        }
    }

    private func railsCard(_ s: Snapshot) -> some View {
        let named = Set(SensorsView.namedRails.map(\.0))
        let rest = s.rails.filter { !named.contains($0.key) && abs($0.watts) >= 0.01 }.sorted { $0.watts > $1.watts }
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle("Мощность по шинам питания")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 24)], spacing: 6) {
                    ForEach(SensorsView.namedRails, id: \.0) { key, label in
                        KeyValue(label, fmtWatts(s.rails.first { $0.key == key }?.watts))
                    }
                }
                Divider()
                Text("Остальные шины — назначение ключей Apple не документирует").font(.caption).foregroundStyle(Palette.muted)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16)], spacing: 6) {
                    ForEach(rest) { rail in
                        HStack {
                            Text(rail.key).font(.caption.monospaced()).foregroundStyle(Palette.ink2)
                            Spacer(minLength: 4)
                            Text(fmtNumber(rail.watts, digits: 2) + " Вт")
                                .font(.caption).foregroundStyle(Palette.ink).monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Память, диск, сеть

/// Составная полоса: сегменты разделены зазором цвета поверхности, а не обводкой.
struct SegmentBar: View {
    let segments: [(color: Color, fraction: Double)]

    var body: some View {
        GeometryReader { geo in
            let usable = geo.size.width - CGFloat(max(0, segments.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(segments.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(segments[i].color)
                        .frame(width: max(0, usable * min(1, max(0, segments[i].fraction))))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 14)
        .background(Palette.grid, in: RoundedRectangle(cornerRadius: 3))
    }
}

struct MemoryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = model.snap
        VStack(alignment: .leading, spacing: 12) {
            memoryCard(s.mem)
            HStack {
                Spacer()
                WindowPicker()
            }
            HistoryChart(title: "Занято памяти", points: model.chart,
                         series: [ChartSeries(name: "Память", color: Palette.blue, metric: .memUsed)],
                         window: model.window, scale: memoryScale(s.mem.total),
                         format: { fmtNumber($0, digits: 0) + " ГБ" })
            HStack(alignment: .top, spacing: 12) {
                diskCard(s)
                HistoryChart(title: "Диск", points: model.chart,
                             series: [ChartSeries(name: "Чтение", color: Palette.blue, metric: .diskRead),
                                      ChartSeries(name: "Запись", color: Palette.orange, metric: .diskWrite)],
                             window: model.window, scale: .binary(minimumTop: 1_048_576), format: fmtRate)
            }
            HStack(alignment: .top, spacing: 12) {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CardTitle("Сеть")
                        KeyValue("Загрузка", fmtRate(s.net.inRate))
                        KeyValue("Отдача", fmtRate(s.net.outRate))
                        KeyValue("Принято с запуска монитора", fmtBytes(s.net.totalIn))
                        KeyValue("Отправлено с запуска монитора", fmtBytes(s.net.totalOut))
                    }
                }
                HistoryChart(title: "Сеть", points: model.chart,
                             series: [ChartSeries(name: "Загрузка", color: Palette.blue, metric: .netIn),
                                      ChartSeries(name: "Отдача", color: Palette.orange, metric: .netOut)],
                             window: model.window, scale: .binary(minimumTop: 131_072), format: fmtRate)
            }
        }
    }

    private func memoryCard(_ m: MemSample) -> some View {
        let total = Double(max(1, m.total))
        let parts: [(String, UInt64, Color)] = [
            ("Приложения", m.app, Palette.blue), ("Системная (wired)", m.wired, Palette.orange),
            ("Сжатая", m.compressed, Palette.aqua), ("Кэш файлов", m.cached, Palette.axis),
        ]
        let pressure: (Severity, String) = m.pressure >= 4 ? (.critical, "Памяти не хватает")
            : m.pressure >= 2 ? (.warning, "Повышенное давление") : (.good, "Давление в норме")
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    CardTitle("Память")
                    Spacer()
                    StatusBadge(severity: pressure.0, label: pressure.1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(fmtBytes(m.used)).font(.system(size: 30, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text("занято из \(fmtBytes(m.total))").font(.callout).foregroundStyle(Palette.ink2)
                }
                SegmentBar(segments: parts.map { ($0.2, Double($0.1) / total) })
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 20)], alignment: .leading, spacing: 6) {
                    ForEach(parts, id: \.0) { name, bytes, color in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                            Text(name).foregroundStyle(Palette.ink2)
                            Spacer(minLength: 4)
                            Text(fmtBytes(bytes)).foregroundStyle(Palette.ink).monospacedDigit()
                        }
                        .font(.callout)
                    }
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(Palette.grid).frame(width: 10, height: 10)
                        Text("Свободно").foregroundStyle(Palette.ink2)
                        Spacer(minLength: 4)
                        Text(fmtBytes(m.free)).foregroundStyle(Palette.ink).monospacedDigit()
                    }
                    .font(.callout)
                }
                Divider()
                KeyValue("Файл подкачки (своп)", m.swapTotal > 0 ? "\(fmtBytes(m.swapUsed)) из \(fmtBytes(m.swapTotal))" : "не используется")
            }
        }
    }

    private func diskCard(_ s: Snapshot) -> some View {
        let fraction = s.disk.total > 0 ? Double(s.disk.used) / Double(s.disk.total) : 0
        let tight = fraction > 0.9
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    CardTitle("Накопитель")
                    Spacer()
                    if tight { StatusBadge(severity: .warning, label: "Мало места") }
                }
                Meter(value: fraction, color: tight ? Palette.warning : Palette.blue, height: 8)
                KeyValue("Свободно", "\(fmtBytes(s.disk.available)) из \(fmtBytes(s.disk.total))")
                KeyValue("Чтение", fmtRate(s.disk.readRate))
                KeyValue("Запись", fmtRate(s.disk.writeRate))
                KeyValue("Температура SSD", fmtTemp(s.tempSSD))
            }
        }
    }
}

// MARK: - Питание

struct PowerView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = model.snap
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                batteryCard(s)
                flowCard(s)
            }
            HStack {
                Spacer()
                WindowPicker()
            }
            HistoryChart(title: "Мощность всей системы", points: model.chart,
                         series: [ChartSeries(name: "Система", color: Palette.blue, metric: .powerSystem)],
                         window: model.window, scale: .decimal(minimumTop: 10), format: wattAxis, height: 180)
        }
    }

    private func batteryCard(_ s: Snapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle("Батарея")
                if let b = s.battery {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(b.percent)%").font(.system(size: 30, weight: .semibold)).foregroundStyle(Palette.ink)
                        Text(stateText(b)).font(.callout).foregroundStyle(Palette.ink2)
                    }
                    Meter(value: Double(b.percent) / 100, height: 8)
                    if let minutes = b.minutesLeft {
                        KeyValue(b.charging ? "До полного заряда" : "Осталось", fmtMinutes(minutes))
                    }
                    KeyValue(b.amps < 0 ? "Разряд" : "Заряд", fmtWatts(b.watts))
                    KeyValue("Напряжение", fmtNumber(b.volts, digits: 2) + " В")
                    KeyValue("Ток", fmtNumber(b.amps, digits: 2) + " А")
                    KeyValue("Температура", fmtTemp(s.tempBattery))
                    Divider()
                    KeyValue("Здоровье", b.health.map(fmtPct) ?? "—")
                    KeyValue("Ёмкость", "\(b.fullMah) из \(b.designMah) мА·ч")
                    KeyValue("Циклы", b.designCycles > 0 ? "\(b.cycles) из \(b.designCycles)" : "\(b.cycles)")
                } else {
                    Text("Батарея не найдена.").foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private func stateText(_ b: BatterySample) -> String {
        if b.charging { return "заряжается" }
        if b.external { return b.full ? "заряжена, питание от адаптера" : "питание от адаптера" }
        return "работа от батареи"
    }

    private func flowCard(_ s: Snapshot) -> some View {
        let system = max(0.1, s.powerSystem ?? 0.1)
        let rows: [(String, Double?)] = [
            ("Вся система", s.powerSystem), ("Чип (оценка)", s.powerSoC), ("GPU", s.powerGPU),
        ]
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle("Куда уходит энергия")
                ForEach(rows, id: \.0) { name, watts in
                    VStack(alignment: .leading, spacing: 3) {
                        KeyValue(name, fmtWatts(watts))
                        Meter(value: (watts ?? 0) / system)
                    }
                }
                Divider()
                KeyValue("Вход от адаптера", fmtWatts(s.powerAdapter))
                KeyValue("Адаптер", adapterText(s.battery))
                KeyValue("Режим энергосбережения", s.lowPower ? "включён" : "выключен")
                Button("Настроить режимы") { model.page = .controls }
                    .buttonStyle(.link)
            }
        }
    }

    private func adapterText(_ b: BatterySample?) -> String {
        guard let b, b.external else { return "не подключён" }
        if let watts = b.adapterWatts { return "\(watts) Вт" + (b.adapterName.map { " · \($0)" } ?? "") }
        return "подключён"
    }
}
