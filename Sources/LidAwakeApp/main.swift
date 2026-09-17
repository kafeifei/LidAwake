import AppKit
import Darwin
import Foundation
import LidAwakeCore
import ServiceManagement
import Sparkle

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
    case batteryAwake(minutesLeft: Int)
    case normal
    case disabled
    case error(String)

    var text: String {
        switch self {
        case .starting(let message): return message
        case .awake: return "保持清醒"
        case .batteryAwake(let minutesLeft): return "电池保持运行 · 剩余 \(minutesLeft) 分钟"
        case .normal, .disabled: return "正常睡眠"
        case .error(let message): return message
        }
    }

    var indicatorColor: NSColor {
        switch self {
        case .awake, .batteryAwake: return .systemGreen
        case .normal, .disabled: return .secondaryLabelColor
        case .starting: return .systemYellow
        case .error: return .systemRed
        }
    }
}

private enum BatteryAwakeDuration: Int, CaseIterable {
    case thirtyMinutes = 30
    case oneHour = 60
    case twoHours = 120

    var title: String {
        switch self {
        case .thirtyMinutes: return "30 分钟"
        case .oneHour: return "1 小时"
        case .twoHours: return "2 小时"
        }
    }

    var seconds: TimeInterval {
        TimeInterval(rawValue) * 60
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
    private let batteryAwakeMenuItem = NSMenuItem(title: "电池下也保持运行", action: nil, keyEquivalent: "")
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
    private let checkForUpdatesMenuItem = NSMenuItem(
        title: "检查更新…",
        action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
        keyEquivalent: ""
    )
    private let automaticUpdateMenuItem = NSMenuItem(
        title: "自动安装更新",
        action: nil,
        keyEquivalent: ""
    )
    private var chargeLimitView: ChargeLimitView?
    private var timer: Timer?
    private var setupError: (state: String, detail: String)?
    private var batterySnapshot: BatterySnapshot?
    private var chargeLimit: Int?
    private var menuState = MenuState.starting("正在确认状态…")
    private var batteryAwakeSubmenuShowsStop = false
    private let clamshellMonitor = ClamshellMonitor()
    /// Lazy so the delegates (`self`) exist before the updater starts; the first
    /// access happens in `configureMenu()`, so the updater still starts at launch.
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: self
    )
    /// Set when a scheduled check found an update we chose not to pop a window for.
    private var pendingUpdateVersion: String?
    /// Sparkle's "install now and relaunch" handler for an automatically downloaded update.
    /// Held only until the status menu is off screen, so the app never restarts mid-click.
    private var pendingImmediateInstall: (() -> Void)?
    private var menuIsOpen = false
    private var latestStatus: HelperStatus?
    private var lidCloseCheckIsScheduled = false

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

        clamshellMonitor.onLidClosed = { [weak self] in
            self?.scheduleLidCloseDisplaySleep()
        }
        clamshellMonitor.start()
    }

    /// The helper may still be reacting to the lid event, so the decision waits a second and
    /// then re-checks every input. One lid close schedules at most one check.
    private func scheduleLidCloseDisplaySleep() {
        guard !lidCloseCheckIsScheduled else { return }
        lidCloseCheckIsScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.lidCloseCheckIsScheduled = false
            self.sleepDisplayIfLidIsStillClosed()
        }
    }

    private func sleepDisplayIfLidIsStillClosed() {
        refreshStatus()
        guard LidAwakePolicy.shouldSleepDisplayOnLidClose(
            clamshellClosed: clamshellMonitor.readClamshellClosed() == true,
            sleepDisabled: currentSleepDisabled,
            hasExternalDisplay: ClamshellMonitor.hasExternalDisplay()
        ) else {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                let message = "LidAwake: 无法让显示器睡眠：\(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(message.utf8))
            }
        }
    }

    /// A stale status says nothing about the current `SleepDisabled`.
    private var currentSleepDisabled: Bool? {
        guard let latestStatus, Date().timeIntervalSince(latestStatus.updatedAt) <= 25 else {
            return nil
        }
        return latestStatus.sleepDisabled
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
        menu.addItem(batteryAwakeMenuItem)
        updateBatteryAwakeMenuItem(until: nil)
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

        checkForUpdatesMenuItem.target = updaterController
        menu.addItem(checkForUpdatesMenuItem)
        automaticUpdateMenuItem.target = self
        automaticUpdateMenuItem.action = #selector(toggleAutomaticUpdates)
        menu.addItem(automaticUpdateMenuItem)
        updateUpdateMenuItems()
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
        menuIsOpen = true
        refreshLoginItemRegistration()
        chargeLimitView?.refresh()
        refreshStatus()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        installPendingUpdateIfIdle()
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
        updateUpdateMenuItems()
        updateStatusButton()

        if let setupError {
            statusMenuItem.toolTip = setupError.detail
            setState(.error(setupError.state))
            return
        }

        guard let data = FileManager.default.contents(atPath: AppConstants.statusPath) else {
            latestStatus = nil
            setState(.starting("正在等待后台服务…"))
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let status = try? decoder.decode(HelperStatus.self, from: data) else {
            latestStatus = nil
            setState(.error("状态文件异常"))
            return
        }

        latestStatus = status

        if Date().timeIntervalSince(status.updatedAt) > 25 {
            setState(.error("后台服务无响应"))
            return
        }

        enabledMenuItem.state = status.policyEnabled ? .on : .off
        updateBatteryAwakeMenuItem(until: status.batteryAwakeUntil)

        let sessionIsActive = status.batteryAwakeUntil != nil
        statusMenuItem.toolTip = status.batteryAwakeStopReason == .lowBattery && status.mode == .normal
            ? "电量低于阈值，已停止电池保持运行"
            : nil

        if !status.policyEnabled && !sessionIsActive {
            setState(.disabled)
        } else {
            switch status.mode {
        case .awake:
            if status.powerSource == .battery, let until = status.batteryAwakeUntil {
                setState(.batteryAwake(minutesLeft: remainingMinutes(until: until)))
            } else {
                setState(.awake)
            }
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
        let showsUpdateBadge = pendingUpdateVersion != nil
        // Read the live appearance every tick so the badged icon follows light/dark changes.
        let appearance = showsUpdateBadge ? button.effectiveAppearance : nil
        let updateSuffix = pendingUpdateVersion.map { " · 有新版本 \($0)" } ?? ""
        if let snapshot = batterySnapshot {
            button.image = BatteryMenuBarIcon.make(
                percentage: snapshot.percentage,
                isCharging: snapshot.isCharging,
                isOnACPower: snapshot.isOnACPower,
                showsUpdateBadge: showsUpdateBadge,
                appearance: appearance
            )
            button.title = ""
            button.setAccessibilityLabel("电池 \(snapshot.percentage)%，\(menuState.text)\(updateSuffix)")
            button.toolTip = "电池 \(snapshot.percentage)% · \(menuState.text)\(updateSuffix)"
        } else {
            button.image = BatteryMenuBarIcon.make(
                percentage: nil,
                isCharging: false,
                isOnACPower: false,
                showsUpdateBadge: showsUpdateBadge,
                appearance: appearance
            )
            button.title = ""
            button.setAccessibilityLabel(menuState.text + updateSuffix)
            button.toolTip = menuState.text + updateSuffix
        }
    }

    private func updateUpdateMenuItems() {
        checkForUpdatesMenuItem.title = pendingUpdateVersion.map { "有新版本 \($0)…" } ?? "检查更新…"
        let updater = updaterController.updater
        // `allowsAutomaticUpdates` is false when the option cannot be turned on at all; a dead
        // toggle would only confuse, so the item disappears instead.
        automaticUpdateMenuItem.isHidden = !updater.allowsAutomaticUpdates
        automaticUpdateMenuItem.state = updater.automaticallyDownloadsUpdates ? .on : .off
    }

    /// Invokes Sparkle's silent install only while the status menu is off screen, so the app
    /// never relaunches out from under an open menu.
    private func installPendingUpdateIfIdle() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.installPendingUpdateIfIdle() }
            return
        }
        guard !menuIsOpen, let install = pendingImmediateInstall else { return }
        pendingImmediateInstall = nil
        setPendingUpdateVersion(nil)
        install()
    }

    private func ensureConfigurationExists() throws {
        guard readConfiguration() == nil else { return }
        try writeConfiguration(LidAwakeConfiguration(enabled: true))
    }

    private func readConfiguration() -> LidAwakeConfiguration? {
        guard let data = FileManager.default.contents(atPath: LidAwakePaths.configurationPath) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LidAwakeConfiguration.self, from: data)
    }

    private func writeConfiguration(_ configuration: LidAwakeConfiguration) throws {
        let url = URL(fileURLWithPath: LidAwakePaths.configurationPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(configuration)
        try data.write(to: url, options: .atomic)
    }

    private func notifyConfigurationChanged() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(LidAwakePaths.configurationChangedNotification as CFString),
            nil,
            nil,
            true
        )
    }

    @objc private func togglePolicy() {
        var configuration = readConfiguration() ?? LidAwakeConfiguration(enabled: true)
        configuration.enabled.toggle()
        do {
            try writeConfiguration(configuration)
            enabledMenuItem.state = configuration.enabled ? .on : .off
            notifyConfigurationChanged()
        } catch {
            setState(.error("无法保存开关状态"))
        }
    }

    @objc private func startBatteryAwakeSession(_ sender: NSMenuItem) {
        guard let duration = BatteryAwakeDuration(rawValue: sender.tag) else { return }
        writeBatteryAwakeUntil(Date().addingTimeInterval(duration.seconds))
    }

    @objc private func stopBatteryAwakeSession() {
        writeBatteryAwakeUntil(nil)
    }

    private func writeBatteryAwakeUntil(_ until: Date?) {
        var configuration = readConfiguration() ?? LidAwakeConfiguration(enabled: true)
        configuration.batteryAwakeUntil = until
        do {
            try writeConfiguration(configuration)
            updateBatteryAwakeMenuItem(until: until)
            notifyConfigurationChanged()
        } catch {
            setState(.error("无法保存电池会话"))
        }
    }

    /// Rebuilds the submenu so the running session offers 停止 and a restart of each duration.
    /// The submenu itself only changes when the session starts or stops; the title refreshes every tick.
    private func updateBatteryAwakeMenuItem(until: Date?) {
        let sessionIsActive = until != nil
        if batteryAwakeMenuItem.submenu == nil || sessionIsActive != batteryAwakeSubmenuShowsStop {
            let submenu = NSMenu()
            if sessionIsActive {
                let stopItem = NSMenuItem(
                    title: "停止",
                    action: #selector(stopBatteryAwakeSession),
                    keyEquivalent: ""
                )
                stopItem.target = self
                submenu.addItem(stopItem)
                submenu.addItem(.separator())
            }
            for duration in BatteryAwakeDuration.allCases {
                let item = NSMenuItem(
                    title: duration.title,
                    action: #selector(startBatteryAwakeSession(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = duration.rawValue
                submenu.addItem(item)
            }
            batteryAwakeMenuItem.submenu = submenu
            batteryAwakeSubmenuShowsStop = sessionIsActive
        }

        if let until {
            batteryAwakeMenuItem.title = "电池下保持运行 · " + remainingText(until: until)
            batteryAwakeMenuItem.state = .on
        } else {
            batteryAwakeMenuItem.title = "电池下也保持运行"
            batteryAwakeMenuItem.state = .off
        }
    }

    private func remainingMinutes(until: Date) -> Int {
        Int((until.timeIntervalSinceNow / 60).rounded(.up))
    }

    private func remainingText(until: Date) -> String {
        let minutes = remainingMinutes(until: until)
        return minutes < 1 ? "剩余不足 1 分钟" : "剩余 \(minutes) 分钟"
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

    @objc private func toggleAutomaticUpdates() {
        updaterController.updater.automaticallyDownloadsUpdates.toggle()
        updateUpdateMenuItems()
    }

    @objc private func quitMenuBar() {
        NSApp.terminate(nil)
    }

    fileprivate func setPendingUpdateVersion(_ version: String?) {
        guard pendingUpdateVersion != version else { return }
        pendingUpdateVersion = version
        updateUpdateMenuItems()
        updateStatusButton()
    }
}

/// Sparkle would otherwise sit on an automatically downloaded update until the app quits, which
/// a menu bar app rarely does. Taking over the install lets it run and relaunch on its own.
extension AppDelegate: SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString
        pendingImmediateInstall = {
            let message = "LidAwake: 正在安装更新 \(version) 并重新启动\n"
            FileHandle.standardError.write(Data(message.utf8))
            immediateInstallHandler()
        }
        installPendingUpdateIfIdle()
        return true
    }
}

/// Scheduled checks stay quiet: instead of Sparkle's window we badge the menu bar icon and
/// retitle the update menu item, which still opens Sparkle's own dialog when clicked.
extension AppDelegate: SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !state.userInitiated else { return }
        // `displayVersionString` already falls back to `versionString` when the appcast
        // carries no short version string.
        setPendingUpdateVersion(update.displayVersionString)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        setPendingUpdateVersion(nil)
    }

    func standardUserDriverWillFinishUpdateSession() {
        setPendingUpdateVersion(nil)
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
