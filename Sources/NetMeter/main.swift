import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let meter = Meter()
    private var eventMonitor: Any?
    private var defaultsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            SettingsKey.interval: 1.0,
            SettingsKey.useBits: false,
            SettingsKey.displayMode: DisplayMode.stacked.rawValue,
            SettingsKey.networkType: NetworkType.external.rawValue,
            SettingsKey.ignoredProcesses: "com.eset.",
        ])

        enableLaunchAtLoginOnFirstRun()
        FlowStatsReader.killOrphanedNettops()
        installTerminationHandlers()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.imagePosition = .imageOnly
        }

        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: PopoverView(meter: meter))

        meter.onTick = { [weak self] in self?.updateStatusItem() }
        meter.start()
        updateStatusItem()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
    }

    /// Registers the app as a login item the first time it runs. Afterwards the user's
    /// choice in Settings is respected (we never re-enable it if they turned it off).
    private func enableLaunchAtLoginOnFirstRun() {
        let key = "didSetupLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            NSLog("NetMeter: could not enable launch at login: \(error)")
        }
    }

    private var signalSources: [DispatchSourceSignal] = []

    /// `kill`/`pkill` (SIGTERM) and Ctrl-C end the process without
    /// applicationWillTerminate, which would orphan nettop and lose unsaved usage.
    private func installTerminationHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.meter.stop()
                    self?.meter.save()
                }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        meter.stop()
        meter.save()
    }

    private func settingsChanged() {
        meter.reconfigureIfNeeded()
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let d = UserDefaults.standard
        let bits = d.bool(forKey: SettingsKey.useBits)
        let mode = DisplayMode(rawValue: d.string(forKey: SettingsKey.displayMode) ?? "") ?? .stacked
        button.image = StatusRenderer.image(
            down: Format.rate(meter.down, bits: bits),
            up: Format.rate(meter.up, bits: bits),
            mode: mode,
            bits: bits
        )
        button.toolTip = "↓ \(Format.rate(meter.down, bits: bits))   ↑ \(Format.rate(meter.up, bits: bits))"
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.closePopover() }
            }
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }
}

/// Draws the menu bar text as a template image so it adapts to light/dark menu bars
/// and keeps a fixed width (no jitter as numbers change).
enum StatusRenderer {
    static func image(down: String, up: String, mode: DisplayMode, bits: Bool) -> NSImage {
        let height = NSStatusBar.system.thickness
        let widest = bits ? "888 Mbps" : "888 MB/s"

        switch mode {
        case .stacked:
            let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let arrowW = ("↓" as NSString).size(withAttributes: attrs).width
            let valueW = (widest as NSString).size(withAttributes: attrs).width
            let gap: CGFloat = 3
            let width = ceil(arrowW + gap + valueW) + 2
            let lineH = font.ascender - font.descender
            let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
                let topY = height / 2 - 0.5
                let bottomY = height / 2 - lineH + 1.5
                draw(arrow: "↑", value: up, y: topY, width: width, arrowW: arrowW, attrs: attrs)
                draw(arrow: "↓", value: down, y: bottomY, width: width, arrowW: arrowW, attrs: attrs)
                return true
            }
            img.isTemplate = true
            return img

        case .singleLine, .downloadOnly, .uploadOnly:
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let arrowW = ("↓ " as NSString).size(withAttributes: attrs).width
            let valueW = (widest as NSString).size(withAttributes: attrs).width
            let segW = ceil(arrowW + valueW)
            let segments: [(String, String)]
            switch mode {
            case .downloadOnly: segments = [("↓", down)]
            case .uploadOnly: segments = [("↑", up)]
            default: segments = [("↓", down), ("↑", up)]
            }
            let spacing: CGFloat = 8
            let width = segW * CGFloat(segments.count) + spacing * CGFloat(segments.count - 1) + 2
            let lineH = font.ascender - font.descender
            let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
                let y = (height - lineH) / 2
                for (i, seg) in segments.enumerated() {
                    let x = CGFloat(i) * (segW + spacing)
                    seg.0.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
                    let vW = (seg.1 as NSString).size(withAttributes: attrs).width
                    seg.1.draw(at: NSPoint(x: x + segW - vW, y: y), withAttributes: attrs)
                }
                return true
            }
            img.isTemplate = true
            return img
        }
    }

    private static func draw(arrow: String, value: String, y: CGFloat, width: CGFloat,
                             arrowW: CGFloat, attrs: [NSAttributedString.Key: Any]) {
        arrow.draw(at: NSPoint(x: 0, y: y), withAttributes: attrs)
        let vW = (value as NSString).size(withAttributes: attrs).width
        value.draw(at: NSPoint(x: width - vW - 1, y: y), withAttributes: attrs)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
