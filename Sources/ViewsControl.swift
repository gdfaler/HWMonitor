import SwiftUI

// MARK: - Процессы

struct ProcNameCell: View {
    let row: ProcRow

    var body: some View {
        HStack(spacing: 6) {
            ProcIcon(pid: row.mainPid)
            Text(row.name).lineLimit(1)
            if row.isGroup, row.pids.count > 1 {
                Text("\(row.pids.count)").font(.caption).foregroundStyle(Palette.muted)
            }
            if row.throttled { tag("замедлен", "tortoise.fill") }
            if row.stopped { tag("пауза", "pause.fill") }
            if !row.owned { tag("система", "lock.fill") }
        }
    }

    private func tag(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2)
            .foregroundStyle(Palette.ink2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Palette.grid, in: Capsule())
            .fixedSize()
    }
}

struct ProcessesView: View {
    @ObservedObject var store: ProcessStore
    @AppStorage("groupProcesses") private var grouped = true
    @AppStorage("onlyMine") private var onlyMine = false
    @Local private var search = ""
    @Local private var sortOrder = [KeyPathComparator(\ProcRow.cpu, order: .reverse)]
    @Local private var selection = Set<String>()
    @Local private var pendingKill: ProcRow? = nil

    private var model: AppModel { AppModel.shared }

    private var rows: [ProcRow] {
        var list = grouped ? store.grouped : store.flat
        if onlyMine { list = list.filter(\.owned) }
        if !search.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(search) } }
        // При равных значениях порядок фиксируем по имени, чтобы строки не прыгали между замерами.
        return list.sorted(using: sortOrder + [KeyPathComparator(\ProcRow.name), KeyPathComparator(\ProcRow.id)])
    }

    var body: some View {
        table
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .searchable(text: $search, placement: .toolbar, prompt: "Поиск по названию")
            .toolbar {
                ToolbarItemGroup {
                    Toggle("По приложениям", isOn: $grouped)
                        .help("Объединять процессы одного приложения в одну строку")
                    Toggle("Только мои", isOn: $onlyMine)
                        .help("Скрыть системные процессы, которыми нельзя управлять")
                }
            }
            .confirmationDialog("Завершить принудительно?", isPresented: killBinding, presenting: pendingKill) { row in
                Button("Завершить «\(row.name)»", role: .destructive) { model.quit(row, force: true) }
            } message: { _ in
                Text("Несохранённые данные приложения будут потеряны.")
            }
    }

    private var killBinding: Binding<Bool> {
        Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } })
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Процесс", value: \.name) { row in
                ProcNameCell(row: row)
            }
            TableColumn("CPU", value: \.cpu) { row in
                Text(fmtNumber(row.cpu, digits: 1) + "%").monospacedDigit()
            }
            .width(min: 60, ideal: 70, max: 90)
            TableColumn("Память", value: \.mem) { row in
                Text(fmtBytes(row.mem)).monospacedDigit()
            }
            .width(min: 70, ideal: 80, max: 100)
            TableColumn("Мощность", value: \.power) { row in
                Text(row.power > 0.005 ? fmtNumber(row.power, digits: 2) + " Вт" : "—").monospacedDigit()
            }
            .width(min: 70, ideal: 80, max: 100)
            TableColumn("Быстрые ядра", value: \.pShare) { row in
                Text(row.pShare >= 0 ? fmtPct(row.pShare) : "—").monospacedDigit()
                    .help("Доля процессорного времени, проведённая на быстрых ядрах")
            }
            .width(min: 100, ideal: 110, max: 140)
            TableColumn("") { row in
                Menu {
                    actions(for: row)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .disabled(!row.owned)
                .help(row.owned ? "Действия" : "Системный процесс — управление недоступно")
            }
            .width(34)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let row = rows.first(where: { ids.contains($0.id) }), row.owned {
                actions(for: row)
            }
        }
    }

    /// Не больше двух строк: текст с неограниченной высотой при расчёте минимального размера окна
    /// складывается в столбик по слову и раздувает всю панель.
    private var footer: some View {
        HStack(spacing: 12) {
            Text("«Замедлить» в меню ⋯ переводит приложение на экономичные ядра: оно работает дальше, но греет чип в разы меньше. CPU 100% — одно ядро целиком.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            if store.throttledCount > 0 {
                Text("Замедлено: \(store.throttledCount)").font(.callout).fixedSize()
                Button("Вернуть всем приоритет") { model.releaseAllThrottled() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private func actions(for row: ProcRow) -> some View {
        Button(row.throttled ? "Вернуть обычный приоритет" : "Замедлить (только экономичные ядра)") {
            model.setThrottled(row, !row.throttled)
        }
        Button(row.stopped ? "Продолжить" : "Приостановить") {
            model.setSuspended(row, !row.stopped)
        }
        Divider()
        Button("Завершить") { model.quit(row, force: false) }
        Button("Завершить принудительно…", role: .destructive) { pendingKill = row }
    }
}

// MARK: - Управление

struct ProfileButton: View {
    let profile: Profile
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: profile.icon).font(.title3).frame(width: 22, height: 22)
                    Text(profile.title).font(.headline)
                    Spacer()
                    if active { Label("Выбран", systemImage: "checkmark.circle.fill").font(.caption) }
                }
                .foregroundStyle(Palette.ink)
                Text(profile.summary)
                    .font(.callout)
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(active ? Palette.blue : Palette.border, lineWidth: active ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ControlsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                Label {
                    Text("У \(model.topology.model) нет вентилятора, поэтому обороты настраивать нечем: чип остывает через корпус, а при перегреве macOS сама снижает его частоту. Управлять можно тем, сколько тепла выделяется, — режимом энергосбережения и тем, каким приложениям разрешены быстрые ядра.")
                        .font(.callout)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle").foregroundStyle(Palette.muted)
                }
            }

            Text("Профили").font(.title3.weight(.semibold)).foregroundStyle(Palette.ink)
            HStack(alignment: .top, spacing: 12) {
                ForEach(Profile.allCases) { profile in
                    ProfileButton(profile: profile, active: model.activeProfile == profile) { model.apply(profile) }
                }
            }

            HStack(alignment: .top, spacing: 12) {
                lowPowerCard
                awakeCard
            }
            coolingCard
            generalCard
        }
    }

    private var lowPowerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardTitle("Режим энергосбережения")
                    Spacer()
                    if model.lowPowerBusy { ProgressView().controlSize(.small) }
                }
                Text("macOS ограничивает частоту чипа и яркость. Самый сильный способ снизить нагрев: производительность ниже, зато корпус заметно холоднее и батареи хватает дольше.")
                    .font(.callout).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                Toggle("При работе от батареи", isOn: Binding(get: { model.lowPower.battery },
                                                                 set: { model.setLowPower(battery: $0, ac: nil) }))
                Toggle("При питании от адаптера", isOn: Binding(get: { model.lowPower.ac },
                                                                  set: { model.setLowPower(battery: nil, ac: $0) }))
                Text("Сейчас: \(model.snap.lowPower ? "включён" : "выключен"). Для изменения macOS запросит пароль администратора.")
                    .font(.caption).foregroundStyle(Palette.muted)
                Button("Открыть настройки батареи") { PowerMode.openBatterySettings() }
                    .buttonStyle(.link)
            }
            .disabled(model.lowPowerBusy)
        }
    }

    private var awakeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle("Сон")
                Text("Пригодится для долгих задач: рендер, сборка, загрузка. Действует, пока монитор запущен.")
                    .font(.callout).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                Toggle("Не давать Mac засыпать", isOn: $model.settings.keepAwake)
                Toggle("И не гасить экран", isOn: $model.settings.keepDisplayAwake)
                    .disabled(!model.settings.keepAwake)
            }
        }
    }

    private var coolingCard: some View {
        let s = model.settings
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardTitle("Автоохлаждение")
                    Spacer()
                    if model.coolingActive {
                        StatusBadge(severity: .warning, label: "Сейчас работает")
                    }
                    Toggle("", isOn: $model.settings.autoCool).labelsHidden().toggleStyle(.switch)
                }
                Text("Когда чип перегревается, самые прожорливые фоновые приложения переводятся на экономичные ядра. Они продолжают работать, но медленнее. Приоритет возвращается сам, когда приложение закончит тяжёлую работу или вы на него переключитесь.")
                    .font(.callout).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                Group {
                    HStack {
                        Text("Порог температуры чипа").frame(width: 240, alignment: .leading)
                        Slider(value: $model.settings.coolThreshold, in: 60...100, step: 1)
                        Text("\(Int(s.coolThreshold))°").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    HStack {
                        Text("Замедлять при нагрузке CPU от").frame(width: 240, alignment: .leading)
                        Slider(value: $model.settings.coolMinCPU, in: 5...200, step: 5)
                        Text("\(Int(s.coolMinCPU))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    Text("Сейчас чип: \(fmtTemp(model.snap.tempSoC)). Приложение считается закончившим работу, когда его нагрузка упала ниже порога, а чип остыл до \(Int(s.coolThreshold - 10))°.")
                        .font(.caption).foregroundStyle(Palette.muted)
                    Toggle("Срабатывать и когда macOS сама начала снижать частоту", isOn: $model.settings.coolOnPressure)
                    Toggle("Не трогать приложение, с которым я сейчас работаю", isOn: $model.settings.coolSpareFrontmost)
                    Toggle("Присылать уведомления", isOn: $model.settings.coolNotify)
                    HStack {
                        Text("Никогда не замедлять").frame(width: 240, alignment: .leading)
                        TextField("названия через запятую, например: Safari, Музыка", text: $model.settings.coolExclusions)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .disabled(!s.autoCool)
                if model.processes.throttledCount > 0 {
                    HStack {
                        Text("Сейчас замедлено процессов: \(model.processes.throttledCount)").foregroundStyle(Palette.ink2)
                        Button("Вернуть всем приоритет") { model.releaseAllThrottled() }
                    }
                    .font(.callout)
                }
                if !model.events.isEmpty {
                    Divider()
                    Text("Журнал").font(.caption).foregroundStyle(Palette.muted)
                    ForEach(model.events.prefix(6)) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(event.time, format: .dateTime.hour().minute().second())
                                .foregroundStyle(Palette.muted).monospacedDigit()
                            Text(event.text).foregroundStyle(Palette.ink2)
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private var generalCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle("Монитор")
                HStack {
                    Text("Частота опроса датчиков").frame(width: 240, alignment: .leading)
                    Picker("Частота опроса", selection: $model.settings.interval) {
                        Text("1 с").tag(1.0)
                        Text("2 с").tag(2.0)
                        Text("5 с").tag(5.0)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                HStack {
                    Text("В строке меню показывать").frame(width: 240, alignment: .leading)
                    Picker("Строка меню", selection: $model.settings.menuBar) {
                        ForEach(MenuBarMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Toggle("Запускать при входе в систему", isOn: Binding(get: { model.loginItem },
                                                                       set: { model.setLoginItem($0) }))
                Text("Окно можно закрыть — монитор останется в строке меню и продолжит следить за температурой.")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
        }
    }
}
