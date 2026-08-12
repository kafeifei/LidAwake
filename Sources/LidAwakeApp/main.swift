import AppKit
import Darwin
import Foundation
import LidAwakeCore
import ServiceManagement

private enum AppConstants {
    static let helperVersion = LidAwakeProtocol.helperVersion
    static let helperLabel = LidAwakeProtocol.helperLabel
    static let installedHelperPath = "/Library/PrivilegedHelperTools/" + helperLabel
    static let installedPlistPath = "/Library/LaunchDaemons/" + helperLabel + ".plist"
    static let statusPath = LidAwakePaths.statusPath
}

private enum LoginItemRegistrationError: LocalizedError {
    case requiresApproval
    case unavailable

    var errorDescription: String? {
        switch self {
        case .requiresApproval:
            return "请在系统设置的“登录项与扩展”中允许 LidAwake"
        case .unavailable:
            return "系统无法注册 LidAwake 登录项"
        }
    }
}

private enum LoginItemRegistration {
    static func ensureRegistered() throws {
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled:
            return
        case .notRegistered:
            try service.register()
        case .requiresApproval:
            throw LoginItemRegistrationError.requiresApproval
        case .notFound:
            throw LoginItemRegistrationError.unavailable
        @unknown default:
            throw LoginItemRegistrationError.unavailable
        }

        if service.status == .requiresApproval {
            throw LoginItemRegistrationError.requiresApproval
        }
    }

    static func unregister() throws {
        let service = SMAppService.mainApp
        guard service.status != .notRegistered else { return }
        try service.unregister()
    }
}

private enum MenuState {
    case starting(String)
    case awake
    case normal
    case disabled
    case error(String)

    var text: String {
        switch self {
        case .starting(let message): return message
        case .awake: return "保持清醒"
        case .normal, .disabled: return "正常睡眠"
        case .error(let message): return message
        }
    }

    var indicatorColor: NSColor {
        switch self {
        case .awake: return .systemGreen
        case .normal, .disabled: return .secondaryLabelColor
        case .starting: return .systemYellow
        case .error: return .systemRed
        }
    }
}

private final class HelperInstaller: @unchecked Sendable {
    func isCurrentVersionInstalled(configurationPath: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: AppConstants.installedHelperPath),
              let installedPlist = NSDictionary(contentsOfFile: AppConstants.installedPlistPath),
              let arguments = installedPlist["ProgramArguments"] as? [String],
              arguments.contains(configurationPath) else {
            return false
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: AppConstants.installedHelperPath)
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return false }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value == String(AppConstants.helperVersion),
                  let data = FileManager.default.contents(atPath: AppConstants.statusPath) else {
                return false
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let status = try? decoder.decode(HelperStatus.self, from: data) else { return false }
            return status.version == AppConstants.helperVersion
                && Date().timeIntervalSince(status.updatedAt) < 25
        } catch {
            return false
        }
    }

    func install(configurationPath: String) throws {
        guard let helperURL = Bundle.main.url(forResource: "LidAwakeHelper", withExtension: nil),
              let plistURL = Bundle.main.url(forResource: AppConstants.helperLabel, withExtension: "plist") else {
            throw NSError(
                domain: "LidAwake",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "应用包缺少后台服务文件"]
            )
        }

        let renderedPlistURL = try renderHelperPlist(
            templateURL: plistURL,
            configurationPath: configurationPath
        )
        defer { try? FileManager.default.removeItem(at: renderedPlistURL.deletingLastPathComponent()) }

        let commands = [
            "set -e",
            "/bin/mkdir -p " + shellQuote("/Library/PrivilegedHelperTools"),
            "/bin/mkdir -p " + shellQuote("/Library/Application Support/LidAwake"),
            "/bin/launchctl bootout system/" + AppConstants.helperLabel + " >/dev/null 2>&1 || true",
            "/usr/bin/pmset disablesleep 0 || true",
            "/usr/bin/install -o root -g wheel -m 0755 " + shellQuote(helperURL.path) + " " + shellQuote(AppConstants.installedHelperPath),
            "/usr/bin/install -o root -g wheel -m 0644 " + shellQuote(renderedPlistURL.path) + " " + shellQuote(AppConstants.installedPlistPath),
            "/bin/launchctl bootstrap system " + shellQuote(AppConstants.installedPlistPath),
            "/bin/launchctl enable system/" + AppConstants.helperLabel,
            "/bin/launchctl kickstart -k system/" + AppConstants.helperLabel,
        ]

        let command = commands.joined(separator: "; ")
        let script = "do shell script \"\(appleScriptEscaped(command))\" with administrator privileges"
        var errorInfo: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            throw NSError(
                domain: "LidAwake",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "无法创建管理员安装脚本"]
            )
        }
        appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "管理员授权被取消或安装失败"
            throw NSError(domain: "LidAwake", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func renderHelperPlist(templateURL: URL, configurationPath: String) throws -> URL {
        let data = try Data(contentsOf: templateURL)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LidAwake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let outputURL = directory.appendingPathComponent(AppConstants.helperLabel + ".plist")
        let outputData = try HelperPlistRenderer.render(
            templateData: data,
            configurationPath: configurationPath
        )
        try outputData.write(to: outputURL, options: .atomic)
        return outputURL
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let summaryMenuItem = NSMenuItem()
    private let summaryView = BatterySummaryView()
    private let statusMenuItem = NSMenuItem(title: "当前：正在确认…", action: nil, keyEquivalent: "")
    private let enabledMenuItem = NSMenuItem(title: "插电时合盖保持运行", action: nil, keyEquivalent: "")
    private let loginItemMenuItem = NSMenuItem(
        title: "允许登录时启动…",
        action: nil,
        keyEquivalent: ""
    )
    private let helperRetryMenuItem = NSMenuItem(
        title: "重试安装后台服务…",
        action: nil,
        keyEquivalent: ""
    )
    private var chargeLimitView: ChargeLimitView?
    private var timer: Timer?
    private var setupError: (state: String, detail: String)?
    private var batterySnapshot: BatterySnapshot?
    private var chargeLimit: Int?
    private var menuState = MenuState.starting("正在确认状态…")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        refreshLoginItemRegistration()
        batterySnapshot = BatteryReader.read()
        summaryView.update(with: batterySnapshot, chargeLimit: chargeLimit)
        setState(.starting("正在确认状态…"))
        do {
            try ensureConfigurationExists()
            ensureHelperInstalled()
        } catch {
            setupError = ("无法创建配置文件", error.localizedDescription)
            setState(.error("无法创建配置文件"))
        }
        refreshStatus()
        let refreshTimer = Timer(
            timeInterval: 1,
            target: self,
            selector: #selector(statusTimerFired),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(refreshTimer, forMode: .common)
        timer = refreshTimer
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.delegate = self
        summaryMenuItem.view = summaryView
        statusMenuItem.isEnabled = false
        menu.addItem(summaryMenuItem)

        if let controller = ChargeLimitController(),
           (try? controller.availableLimits())?.isEmpty == false {
            menu.addItem(.separator())
            let chargeLimitItem = NSMenuItem()
            let view = ChargeLimitView(controller: controller)
            chargeLimit = try? controller.currentLimit()
            view.onLimitChanged = { [weak self] limit in
                guard let self else { return }
                self.chargeLimit = limit
                self.summaryView.update(with: self.batterySnapshot, chargeLimit: limit)
            }
            chargeLimitItem.view = view
            chargeLimitView = view
            menu.addItem(chargeLimitItem)
        }

        menu.addItem(.separator())

        enabledMenuItem.target = self
        enabledMenuItem.action = #selector(togglePolicy)
        menu.addItem(enabledMenuItem)
        menu.addItem(statusMenuItem)
        helperRetryMenuItem.target = self
        helperRetryMenuItem.action = #selector(retryHelperInstallation)
        helperRetryMenuItem.isHidden = true
        menu.addItem(helperRetryMenuItem)
        loginItemMenuItem.target = self
        loginItemMenuItem.action = #selector(openLoginItemsSettings)
        loginItemMenuItem.isHidden = true
        menu.addItem(loginItemMenuItem)
        menu.addItem(.separator())

        let batterySettingsItem = NSMenuItem(
            title: "电池设置…",
            action: #selector(openBatterySettings),
            keyEquivalent: ","
        )
        batterySettingsItem.target = self
        menu.addItem(batterySettingsItem)

        let quitItem = NSMenuItem(
            title: "退出电池显示",
            action: #selector(quitMenuBar),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshLoginItemRegistration()
        chargeLimitView?.refresh()
        refreshStatus()
    }

    private func refreshLoginItemRegistration() {
        do {
            try LoginItemRegistration.ensureRegistered()
            loginItemMenuItem.isHidden = true
            loginItemMenuItem.toolTip = nil
        } catch {
            loginItemMenuItem.isHidden = false
            loginItemMenuItem.toolTip = error.localizedDescription
        }
    }

    private func ensureHelperInstalled() {
        let installer = HelperInstaller()
        let configurationPath = LidAwakePaths.configurationPath
        guard !installer.isCurrentVersionInstalled(configurationPath: configurationPath) else {
            setupError = nil
            helperRetryMenuItem.isHidden = true
            statusMenuItem.toolTip = nil
            return
        }
        setupError = nil
        helperRetryMenuItem.isHidden = true
        setState(.starting("需要管理员授权…"))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try installer.install(configurationPath: configurationPath)
                DispatchQueue.main.async {
                    self?.setupError = nil
                    self?.helperRetryMenuItem.isHidden = true
                    self?.statusMenuItem.toolTip = nil
                    self?.refreshStatus()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.setupError = ("后台服务未安装", error.localizedDescription)
                    self?.helperRetryMenuItem.isHidden = false
                    self?.helperRetryMenuItem.toolTip = error.localizedDescription
                    self?.statusMenuItem.toolTip = error.localizedDescription
                    self?.setState(.error("后台服务未安装"))
                }
            }
        }
    }

    private func refreshStatus() {
        batterySnapshot = BatteryReader.read()
        summaryView.update(with: batterySnapshot, chargeLimit: chargeLimit)
        updateStatusButton()

        if let setupError {
            statusMenuItem.toolTip = setupError.detail
            setState(.error(setupError.state))
            return
        }

        guard let data = FileManager.default.contents(atPath: AppConstants.statusPath) else {
            setState(.starting("正在等待后台服务…"))
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let status = try? decoder.decode(HelperStatus.self, from: data) else {
            setState(.error("状态文件异常"))
            return
        }

        if Date().timeIntervalSince(status.updatedAt) > 25 {
            setState(.error("后台服务无响应"))
            return
        }

        enabledMenuItem.state = status.policyEnabled ? .on : .off

        if !status.policyEnabled {
            setState(.disabled)
        } else {
            switch status.mode {
        case .awake:
            setState(.awake)
        case .normal:
            setState(.normal)
        case .starting:
            setState(.starting("正在确认状态…"))
        case .error:
            if status.sleepDisabled == false {
                setState(.error("异常 · 已恢复正常睡眠"))
            } else {
                setState(.error("异常 · 无法确认睡眠状态"))
            }
            }
        }

    }

    private func setState(_ state: MenuState) {
        menuState = state
        let title = NSMutableAttributedString(
            string: "●  ",
            attributes: [.foregroundColor: state.indicatorColor]
        )
        title.append(NSAttributedString(
            string: "当前：" + state.text,
            attributes: [.foregroundColor: NSColor.secondaryLabelColor]
        ))
        statusMenuItem.attributedTitle = title
        updateStatusButton()
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        if let snapshot = batterySnapshot {
            button.image = BatteryMenuBarIcon.make(
                percentage: snapshot.percentage,
                isCharging: snapshot.isCharging,
                isOnACPower: snapshot.isOnACPower
            )
            button.title = ""
            button.setAccessibilityLabel("电池 \(snapshot.percentage)%，\(menuState.text)")
            button.toolTip = "电池 \(snapshot.percentage)% · \(menuState.text)"
        } else {
            button.image = BatteryMenuBarIcon.make(
                percentage: nil,
                isCharging: false,
                isOnACPower: false
            )
            button.title = ""
            button.setAccessibilityLabel(menuState.text)
            button.toolTip = menuState.text
        }
    }

    private func ensureConfigurationExists() throws {
        guard readConfiguration() == nil else { return }
        try writeConfiguration(LidAwakeConfiguration(enabled: true))
    }

    private func readConfiguration() -> LidAwakeConfiguration? {
        guard let data = FileManager.default.contents(atPath: LidAwakePaths.configurationPath) else {
            return nil
        }
        return try? JSONDecoder().decode(LidAwakeConfiguration.self, from: data)
    }

    private func writeConfiguration(_ configuration: LidAwakeConfiguration) throws {
        let url = URL(fileURLWithPath: LidAwakePaths.configurationPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(configuration)
        try data.write(to: url, options: .atomic)
    }

    @objc private func togglePolicy() {
        let current = readConfiguration() ?? LidAwakeConfiguration(enabled: true)
        do {
            try writeConfiguration(LidAwakeConfiguration(enabled: !current.enabled))
            enabledMenuItem.state = current.enabled ? .off : .on
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(LidAwakePaths.configurationChangedNotification as CFString),
                nil,
                nil,
                true
            )
        } catch {
            setState(.error("无法保存开关状态"))
        }
    }

    @objc private func statusTimerFired() {
        refreshStatus()
    }

    @objc private func retryHelperInstallation() {
        ensureHelperInstalled()
    }

    @objc private func openBatterySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc private func quitMenuBar() {
        NSApp.terminate(nil)
    }
}

if CommandLine.arguments.dropFirst().first == "--unregister-login-item" {
    do {
        try LoginItemRegistration.unregister()
        exit(EXIT_SUCCESS)
    } catch {
        let message = "LidAwake: 无法取消登录项：\(error.localizedDescription)\n"
        FileHandle.standardError.write(Data(message.utf8))
        exit(EXIT_FAILURE)
    }
}

private let application = NSApplication.shared
private let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.run()
