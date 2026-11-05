import AppKit
import Darwin

/// One row in the "apps using the network" list.
struct AppUsage: Identifiable {
    let id: String
    let name: String
    let detail: String? // e.g. the underlying process for a renamed system service
    let icon: NSImage
    var down: Double // bytes/second
    var up: Double
}

/// Maps a process to the app it belongs to, so helper processes (e.g. "Google Chrome
/// Helper") are grouped under their app, with the app's real name and icon.
@MainActor
final class AppResolver {
    struct Info {
        let id: String
        let name: String
        let detail: String?
        let icon: NSImage
    }

    /// Friendly names for system services that do network work on behalf of others.
    private static let knownServices: [String: String] = [
        "nsurlsessiond": "Background downloads",
        "mobileassetd": "System components",
        "softwareupdated": "Software Update",
        "appstoreagent": "App Store",
        "storedownloadd": "App Store",
        "cloudd": "iCloud",
        "bird": "iCloud Drive",
        "photolibraryd": "iCloud Photos",
        "apsd": "Push notifications",
        "mDNSResponder": "DNS",
        "trustd": "Certificate checks",
        "rapportd": "Nearby devices",
        "sharingd": "AirDrop & Sharing",
        "identityservicesd": "iMessage & FaceTime",
        "imagent": "iMessage",
        "parsecd": "Siri & Spotlight suggestions",
        "syspolicyd": "Gatekeeper",
        "timed": "Time sync",
        "akd": "Apple Account",
    ]

    private var cache: [String: Info] = [:]
    private var iconCache: [String: NSImage] = [:]

    func info(pid: Int32, name: String) -> Info {
        let key = "\(pid)|\(name)"
        if let hit = cache[key] { return hit }
        if cache.count > 2000 { cache.removeAll() }

        let info = resolve(pid: pid, name: name)
        cache[key] = info
        return info
    }

    private func resolve(pid: Int32, name: String) -> Info {
        let path = executablePath(pid: pid)

        // Inside an app bundle? Group under the outermost .app.
        if let path, let appPath = outermostApp(in: path) {
            var display = FileManager.default.displayName(atPath: appPath)
            if display.hasSuffix(".app") { display = String(display.dropLast(4)) }
            return Info(id: "app:" + appPath, name: display, detail: nil, icon: icon(forApp: appPath))
        }

        // nettop truncates names; the executable path has the full one.
        let execName = path.map { ($0 as NSString).lastPathComponent } ?? name
        let isSystem = path.map { $0.hasPrefix("/System/") || $0.hasPrefix("/usr/") } ?? true
        if let friendly = Self.knownServices[execName] {
            return Info(id: "svc:" + friendly, name: friendly + (isSystem ? " (macOS)" : ""),
                        detail: execName, icon: symbol("gearshape.fill"))
        }
        return Info(id: "proc:" + execName, name: execName, detail: nil,
                    icon: symbol(isSystem ? "gearshape.fill" : "terminal.fill"))
    }

    private func executablePath(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    private func outermostApp(in path: String) -> String? {
        var parts: [String] = []
        for comp in path.split(separator: "/", omittingEmptySubsequences: true) {
            parts.append(String(comp))
            if comp.hasSuffix(".app") { return "/" + parts.joined(separator: "/") }
        }
        return nil
    }

    private func icon(forApp appPath: String) -> NSImage {
        if let hit = iconCache[appPath] { return hit }
        let img = NSWorkspace.shared.icon(forFile: appPath)
        img.size = NSSize(width: 32, height: 32)
        iconCache[appPath] = img
        return img
    }

    private func symbol(_ name: String) -> NSImage {
        if let hit = iconCache["sf:" + name] { return hit }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        iconCache["sf:" + name] = img
        return img
    }
}
