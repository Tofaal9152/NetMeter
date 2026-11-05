import AppKit
import SwiftUI

/// A small always-on-top window with the live speed graph, like DU Meter's
/// desktop graph. It replaces the menu bar item while shown (see
/// AppDelegate.applyDisplayMode): it shows on every Space and over full-screen apps,
/// can be dragged anywhere and resized, and remembers its frame.
@MainActor
final class FloatingGraphController: NSObject, NSWindowDelegate {
    private let meter: Meter
    private let onShowDetails: (NSView, NSRectEdge) -> Void
    private var panel: NSPanel?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    init(meter: Meter, onShowDetails: @escaping (NSView, NSRectEdge) -> Void) {
        self.meter = meter
        self.onShowDetails = onShowDetails
    }

    /// Applies the current settings: shows/hides the window and sets its opacity.
    func sync() {
        let d = UserDefaults.standard
        guard d.bool(forKey: SettingsKey.floatingVisible) else {
            panel?.orderOut(nil)
            return
        }
        let p = panel ?? makePanel()
        panel = p
        p.alphaValue = CGFloat(min(max(d.double(forKey: SettingsKey.floatingOpacity), 0.2), 1))
        if !p.isVisible { p.orderFrontRegardless() }
    }

    // MARK: Actions from the SwiftUI content

    func switchToMenuBar() {
        UserDefaults.standard.set(false, forKey: SettingsKey.floatingVisible)
    }

    /// Opens the details panel beside the window, on whichever side has room
    /// (under it, the panel would run off the screen when the window is near an edge).
    func showDetails() {
        guard let p = panel, let view = p.contentView else { return }
        let screenMidX = (p.screen ?? NSScreen.main)?.visibleFrame.midX ?? p.frame.midX
        onShowDetails(view, p.frame.midX > screenMidX ? .minX : .maxX)
    }

    /// Moves the window with the mouse. Done by hand instead of
    /// `isMovableByWindowBackground`, which would swallow clicks on the buttons.
    func dragChanged() {
        guard let p = panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, p.frame.origin) }
        guard let start = dragStart else { return }
        p.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                 y: start.origin.y + mouse.y - start.mouse.y))
    }

    func dragEnded() {
        dragStart = nil
    }

    // MARK: Window

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 120),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // A titled window gets resize edges and rounded corners; hide the title bar itself.
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            p.standardWindowButton(b)?.isHidden = true
        }
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.minSize = NSSize(width: 180, height: 80)
        p.isReleasedWhenClosed = false
        p.delegate = self

        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        let host = NSHostingView(rootView: FloatingGraphView(meter: meter, controller: self))
        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        p.contentView = blur

        if !p.setFrameUsingName(Self.frameName) {
            // First time: top-right corner of the main screen, under the menu bar.
            if let screen = NSScreen.main?.visibleFrame {
                p.setFrameTopLeftPoint(NSPoint(x: screen.maxX - p.frame.width - 16, y: screen.maxY - 12))
            }
        }
        p.setFrameAutosaveName(Self.frameName)
        return p
    }

    private static let frameName = "FloatingGraph"

    func windowWillClose(_ notification: Notification) {
        switchToMenuBar()
    }
}

struct FloatingGraphView: View {
    @ObservedObject var meter: Meter
    let controller: FloatingGraphController
    @AppStorage(SettingsKey.useBits) private var bits = false
    @AppStorage(SettingsKey.floatingOpacity) private var opacity = 0.9

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Text("↓ " + Format.rate(meter.down, bits: bits)).foregroundStyle(downColor)
                Spacer(minLength: 6)
                Text("↑ " + Format.rate(meter.up, bits: bits)).foregroundStyle(upColor)
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.7) // shrink rather than truncate in a narrow window

            // Buttons sit in the graph's top-right corner so the speeds row keeps its width.
            SpeedGraph(samples: meter.history, capacity: Meter.historyLength, bits: bits)
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 0) {
                        iconButton("chart.bar.doc.horizontal", help: "Show details, usage and settings") {
                            controller.showDetails()
                        }
                        iconButton("menubar.rectangle", help: "Switch to menu bar") {
                            controller.switchToMenuBar()
                        }
                    }
                    .padding(2)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(3)
                }
        }
        .padding(.horizontal, 9)
        .padding(.top, 7)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Blur alone lets busy content behind (text, lines) show through the numbers.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.55))
        .ignoresSafeArea() // the hidden title bar would otherwise reserve an empty strip
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { _ in controller.dragChanged() }
                .onEnded { _ in controller.dragEnded() }
        )
        .contextMenu {
            Button("Show Details…") { controller.showDetails() }
            Button("Switch to Menu Bar") { controller.switchToMenuBar() }
            Menu("Opacity") {
                ForEach([1.0, 0.9, 0.75, 0.5, 0.3], id: \.self) { v in
                    Button {
                        opacity = v
                    } label: {
                        Text("\(Int(v * 100))%" + (abs(opacity - v) < 0.01 ? "  ✓" : ""))
                    }
                }
            }
            Divider()
            Button("Quit NetMeter") { NSApp.terminate(nil) }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
