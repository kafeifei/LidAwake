import AppKit
import Foundation

/// Quoting shared by everything that hands a command to `/bin/sh` through AppleScript.
enum ShellEscaping {
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// The app registers a login item and a system LaunchDaemon against its own bundle path, so a
/// published copy has to live at one known location. Anything else is moved there on launch.
enum InstallLocation {
    static let requiredPath = "/Applications/LidAwake.app"

    /// SwiftPM builds run straight out of `.build`, where debugging must keep working.
    static func isDevelopmentBuild(bundlePath: String) -> Bool {
        bundlePath.contains("/.build/")
    }

    static func needsRelocation(bundlePath: String) -> Bool {
        let standardizedPath = (bundlePath as NSString).standardizingPath
        guard standardizedPath != requiredPath else { return false }
        return !isDevelopmentBuild(bundlePath: bundlePath)
    }

    /// Moves the bundle to `requiredPath`, then opens the moved copy and quits this one.
    /// Only returns without relaunching when the move itself failed.
    static func relocate(from source: String) throws {
        let fileManager = FileManager.default
        let applicationsDirectory = (requiredPath as NSString).deletingLastPathComponent

        if fileManager.isWritableFile(atPath: applicationsDirectory) {
            if fileManager.fileExists(atPath: requiredPath) {
                try fileManager.removeItem(atPath: requiredPath)
            }
            do {
                try fileManager.moveItem(atPath: source, toPath: requiredPath)
            } catch {
                // `moveItem` fails across volumes, which is the common case for a disk image.
                try fileManager.copyItem(atPath: source, toPath: requiredPath)
                try? fileManager.removeItem(atPath: source)
            }
        } else {
            let command = "/bin/rm -rf " + ShellEscaping.shellQuote(requiredPath)
                + "; /bin/mv " + ShellEscaping.shellQuote(source)
                + " " + ShellEscaping.shellQuote(requiredPath)
            try runPrivileged(command)
        }

        launchRelocatedCopyAndTerminate()
    }

    private static func runPrivileged(_ command: String) throws {
        let script = "do shell script \"\(ShellEscaping.appleScriptEscaped(command))\" with administrator privileges"
        guard let appleScript = NSAppleScript(source: script) else {
            throw NSError(
                domain: "LidAwake",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "无法创建管理员移动脚本"]
            )
        }
        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "管理员授权被取消或移动失败"
            throw NSError(domain: "LidAwake", code: 6, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    /// This process still points at the old bundle, so the moved copy is launched as a new
    /// instance and this one quits once the launch request has been answered.
    private static func launchRelocatedCopyAndTerminate() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: requiredPath),
            configuration: configuration
        ) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        // The completion handler is the normal path; this keeps a failed launch from leaving a
        // menu bar app running from a bundle that no longer exists.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { NSApp.terminate(nil) }
    }
}
