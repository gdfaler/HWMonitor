// HWMonitor — монитор железа для Mac на Apple Silicon: температуры, нагрузка, питание, процессы
// и управление нагревом (режим энергосбережения, перевод приложений на экономичные ядра).
//
//  Сборка:  ./build.sh   (нужны Command Line Tools: xcode-select --install)
//  Всё читается без root: SMC (датчики), IOReport (частоты ядер), libproc (процессы).

import SwiftUI
import AppKit

@main
struct HWMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        Window("HWMonitor", id: "main") {
            MainView().environmentObject(model)
        }
        .defaultSize(width: 1120, height: 800)

        MenuBarExtra {
            MenuBarView().environmentObject(model)
        } label: {
            MenuBarLabel(state: model.menuBar)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var state: MenuBarState

    var body: some View {
        Image(systemName: "thermometer.medium")
        Text(state.title)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var termination: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // По SIGTERM (pkill, выключение) выходим штатно, чтобы вернуть приоритеты замедленным процессам.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termination = source

        if let dir = ProcessInfo.processInfo.environment["HWMON_SNAPSHOT_DIR"] { LayoutCheck.run(into: dir) }

        // Пока главное окно не видно, монитор опрашивает только ключевые датчики.
        let center = NotificationCenter.default
        let signals = [
            NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
        ]
        for name in signals {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshVisibility() }
            }
        }
        // Уведомления дают мгновенную реакцию, а перепроверка на каждом замере страхует от пропущенных.
        AppModel.shared.visibilityProbe = { [weak self] in self?.mainWindowVisible ?? false }

        // При автозапуске (или с ключом --background) окно не показываем — монитор остаётся в строке меню.
        if CommandLine.arguments.contains("--background") || launchedAsLoginItem {
            DispatchQueue.main.async { self.mainWindows.forEach { $0.close() } }
        }
    }

    private var mainWindows: [NSWindow] {
        NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") == true }
    }

    private var mainWindowVisible: Bool {
        LayoutCheck.isActive || mainWindows.contains { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
    }

    private func refreshVisibility() {
        AppModel.shared.windowVisible = mainWindowVisible
    }

    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}

// MARK: - Главное окно

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $model.page) {
                    ForEach(Page.allCases) { page in
                        Label(page.title, systemImage: page.icon).tag(page)
                    }
                }
                machineSummary
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail.navigationTitle(model.page.title)
        }
        .frame(minWidth: 940, minHeight: 620)
        .alert("HWMonitor", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.alert ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.page == .processes {
            ProcessesView(store: model.processes)
        } else {
            ScrollView {
                Group {
                    switch model.page {
                    case .overview: OverviewView()
                    case .cpu: CPUView()
                    case .sensors: SensorsView()
                    case .memory: MemoryView()
                    case .power: PowerView()
                    case .controls: ControlsView()
                    case .processes: EmptyView()
                    }
                }
                .padding(20)
            }
            .background(Palette.page)
        }
    }

    private var machineSummary: some View {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return VStack(alignment: .leading, spacing: 2) {
            Text(model.topology.model).font(.caption.weight(.semibold)).foregroundStyle(.primary)
            Text("\(model.topology.chip) · \(fmtBytes(model.topology.memBytes))")
            Text("macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}

// MARK: - Строка меню

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = model.snap
        let severity = thermalSeverity(s.thermalLevel)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: severity.icon).foregroundStyle(severity.color)
                Text(thermalTitle(s.thermalLevel)).font(.headline)
                Spacer()
                Text(model.topology.chip).font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 7) {
                line("Температура чипа", fmtTemp(s.tempSoC), s.tempSoC.map { ($0 - 20) / 90 },
                     s.tempSoC.map { tempSeverity($0).color } ?? Palette.blue)
                line("Процессор", fmtPct(s.cpuTotal), s.cpuTotal, Palette.blue)
                line("GPU", fmtPct(s.gpu.utilization ?? s.gpuActive ?? 0), s.gpu.utilization ?? s.gpuActive ?? 0, Palette.aqua)
                line("Память", fmtBytes(s.mem.used), s.mem.usedFraction, Palette.blue)
                line("Мощность системы", fmtWatts(s.powerSystem), nil, Palette.blue)
                if let b = s.battery {
                    line("Батарея", "\(b.percent)%" + (b.charging ? " ⚡" : ""), Double(b.percent) / 100, Palette.blue)
                }
            }
            Divider()
            Toggle("Автоохлаждение с \(Int(model.settings.coolThreshold))°", isOn: $model.settings.autoCool)
            Toggle("Не давать Mac засыпать", isOn: $model.settings.keepAwake)
            Text(statusLine(s)).font(.caption).foregroundStyle(.secondary)
            let top = model.processes.grouped.sorted { $0.cpu > $1.cpu }.prefix(3)
            if !top.isEmpty {
                Divider()
                ForEach(top) { row in
                    HStack(spacing: 6) {
                        ProcIcon(pid: row.mainPid)
                        Text(row.name).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(fmtNumber(row.cpu, digits: 0) + "%").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            Divider()
            HStack {
                Button("Открыть монитор") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Выйти") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { model.popoverVisible = true }
        .onDisappear { model.popoverVisible = false }
    }

    private func line(_ label: String, _ value: String, _ fraction: Double?, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 128, alignment: .leading)
            if let fraction {
                Meter(value: fraction, color: color)
            } else {
                Spacer()
            }
            Text(value).monospacedDigit().frame(width: 62, alignment: .trailing)
        }
        .font(.callout)
    }

    private func statusLine(_ s: Snapshot) -> String {
        var parts = [s.lowPower ? "Энергосбережение включено" : "Энергосбережение выключено"]
        if model.processes.throttledCount > 0 { parts.append("замедлено процессов: \(model.processes.throttledCount)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Проверка вёрстки

/// HWMON_SNAPSHOT_DIR=/путь ./HWMonitor — сохраняет PNG каждого раздела и выходит.
/// HWMON_SNAPSHOT_PAGES=overview,cpu — только эти разделы, HWMON_SNAPSHOT_DELAY=60 — сколько секунд
/// копить историю перед первым снимком, HWMON_APPEARANCE=dark — тёмная тема.
@MainActor
enum LayoutCheck {
    private static var popover: NSWindow?

    /// Пока идёт проверка, окно считается видимым, даже если оно на другом рабочем столе.
    private(set) static var isActive = false

    static func run(into dir: String) {
        isActive = true
        if ProcessInfo.processInfo.environment["HWMON_APPEARANCE"] == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        let host = NSHostingView(rootView: MenuBarView().environmentObject(AppModel.shared))
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 300, height: 420), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.title = "popover"
        window.contentView = host
        window.orderBack(nil)
        popover = window

        let wanted = ProcessInfo.processInfo.environment["HWMON_SNAPSHOT_PAGES"]?.split(separator: ",").map(String.init)
        var pages = Page.allCases.filter { wanted?.contains($0.rawValue) ?? true }[...]
        func step() {
            guard let page = pages.popFirst() else {
                NSApp.terminate(nil)
                return
            }
            AppModel.shared.page = page
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                capture(page.rawValue, into: dir)
                step()
            }
        }
        let delay = Double(ProcessInfo.processInfo.environment["HWMON_SNAPSHOT_DELAY"] ?? "") ?? 8
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { step() }
    }

    private typealias WindowImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// Снимок собственного окна так, как его видит пользователь (для своих окон разрешение на запись экрана не нужно).
    private static let windowImage: WindowImageFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: WindowImageFn.self)
    }()

    private static func capture(_ name: String, into dir: String) {
        for window in NSApp.windows where window.isVisible {
            let kind = window.className.contains("StatusBar") ? "status" : window.title == "popover" ? "popover" : "window"
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(kind).png")
            // 8 — только это окно, 1 | 8 — без тени и в полном разрешении.
            guard let number = UInt32(exactly: window.windowNumber),
                  let image = windowImage?(.null, 8, number, 1 | 8)?.takeRetainedValue() else { continue }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
