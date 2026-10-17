import Foundation
import AppKit
import IOKit.pwr_mgt
import ServiceManagement
import UserNotifications

// MARK: - Процессы

enum ProcessControl {
    /// Фоновый приоритет: планировщик держит процесс только на экономичных ядрах — он греет в разы меньше.
    static func setBackground(_ pid: pid_t, _ on: Bool) -> Bool {
        setpriority(PRIO_DARWIN_PROCESS, id_t(pid), on ? PRIO_DARWIN_BG : 0) == 0
    }

    static func suspend(_ pid: pid_t) -> Bool { kill(pid, SIGSTOP) == 0 }
    static func resume(_ pid: pid_t) -> Bool { kill(pid, SIGCONT) == 0 }

    static func quit(_ pid: pid_t) {
        if let app = NSRunningApplication(processIdentifier: pid), app.terminate() { return }
        kill(pid, SIGTERM)
    }

    static func forceQuit(_ pid: pid_t) { kill(pid, SIGKILL) }
}

// MARK: - Режим энергосбережения

struct LowPowerSetting: Equatable {
    var battery = false
    var ac = false
}

enum PowerMode {
    enum Outcome {
        case done
        case cancelled
        case failed(String)
    }

    static func read() -> LowPowerSetting {
        var result = LowPowerSetting()
        guard let output = runTool("/usr/bin/pmset", ["-g", "custom"]) else { return result }
        var section = ""
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Battery Power") {
                section = "battery"
            } else if text.hasPrefix("AC Power") {
                section = "ac"
            } else if text.hasPrefix("lowpowermode") {
                let on = text.hasSuffix("1")
                if section == "battery" { result.battery = on } else if section == "ac" { result.ac = on }
            }
        }
        return result
    }

    /// pmset требует прав администратора — macOS сама покажет окно с запросом пароля.
    static func set(battery: Bool?, ac: Bool?, completion: @escaping (Outcome) -> Void) {
        var commands: [String] = []
        if let battery { commands.append("/usr/bin/pmset -b lowpowermode \(battery ? 1 : 0)") }
        if let ac { commands.append("/usr/bin/pmset -c lowpowermode \(ac ? 1 : 0)") }
        guard !commands.isEmpty else {
            completion(.done)
            return
        }
        let script = "do shell script \"\(commands.joined(separator: " && "))\" "
            + "with prompt \"HWMonitor меняет режим энергосбережения.\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { finished in
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let outcome: Outcome
            if finished.terminationStatus == 0 {
                outcome = .done
            } else if message.contains("-128") {
                outcome = .cancelled
            } else {
                outcome = .failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            DispatchQueue.main.async { completion(outcome) }
        }
        do {
            try process.run()
        } catch {
            completion(.failed(error.localizedDescription))
        }
    }

    static func openBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Не засыпать

final class KeepAwake {
    private var systemID: IOPMAssertionID = 0
    private var displayID: IOPMAssertionID = 0

    func apply(system: Bool, display: Bool) {
        set(&systemID, on: system, type: kIOPMAssertPreventUserIdleSystemSleep)
        set(&displayID, on: system && display, type: kIOPMAssertPreventUserIdleDisplaySleep)
    }

    private func set(_ id: inout IOPMAssertionID, on: Bool, type: String) {
        if on, id == 0 {
            var created: IOPMAssertionID = 0
            let kr = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "HWMonitor: не засыпать" as CFString, &created)
            if kr == kIOReturnSuccess { id = created }
        } else if !on, id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }
}

// MARK: - Уведомления и автозапуск

enum Notifier {
    /// Центр уведомлений падает, если процесс запущен не из .app.
    private static var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
