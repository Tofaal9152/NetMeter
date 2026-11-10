import SwiftUI
import ServiceManagement

let downColor = Color(red: 0.20, green: 0.55, blue: 1.0)
let upColor = Color(red: 1.0, green: 0.55, blue: 0.15)

struct PopoverView: View {
    @ObservedObject var meter: Meter
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $tab) {
                Text("Live").tag(0)
                Text("Usage").tag(1)
                Text("Settings").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case 0: LiveView(meter: meter)
            case 1: UsageView(meter: meter, usage: meter.usage)
            default: SettingsView(meter: meter)
            }

            Divider()
            HStack {
                Text("NetMeter").font(.caption).foregroundStyle(.secondary)
                Spacer()
                FloatingGraphToggle()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 360)
    }
}

/// Footer button that switches between the menu bar item and the floating window.
struct FloatingGraphToggle: View {
    @AppStorage(SettingsKey.floatingVisible) private var visible = false

    var body: some View {
        Button {
            visible.toggle()
        } label: {
            Image(systemName: visible ? "menubar.rectangle" : "rectangle.on.rectangle")
        }
        .buttonStyle(.borderless)
        .help(visible ? "Switch to menu bar" : "Switch to floating window")
    }
}

// MARK: - Live

struct LiveView: View {
    @ObservedObject var meter: Meter
    @AppStorage(SettingsKey.useBits) private var bits = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                SpeedTile(title: "Download", arrow: "arrow.down", color: downColor,
                          value: Format.rate(meter.down, bits: bits),
                          peak: Format.rate(meter.peakDown, bits: bits))
                SpeedTile(title: "Upload", arrow: "arrow.up", color: upColor,
                          value: Format.rate(meter.up, bits: bits),
                          peak: Format.rate(meter.peakUp, bits: bits))
            }

            SpeedGraph(samples: meter.history, capacity: Meter.historyLength, bits: bits)
                .frame(height: 110)

            TopAppsList(apps: meter.topApps, bits: bits)

            HStack {
                Text("Session  ↓ \(Format.bytes(meter.sessionDown))  ↑ \(Format.bytes(meter.sessionUp))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { meter.resetSession() }
                    .controlSize(.small)
            }
        }
    }
}

struct TopAppsList: View {
    let apps: [AppUsage]
    let bits: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Apps using the network").font(.caption).foregroundStyle(.secondary)
            if apps.isEmpty {
                Text("No network activity")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            } else {
                ForEach(apps) { app in
                    HStack(spacing: 7) {
                        Image(nsImage: app.icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                        Text(app.name)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(app.detail.map { "\(app.name) — process: \($0)" } ?? app.name)
                        Spacer(minLength: 6)
                        Text("↓ " + Format.rate(app.down, bits: bits))
                            .foregroundStyle(app.down >= 50 ? downColor : .secondary)
                            .frame(width: 72, alignment: .trailing)
                        Text("↑ " + Format.rate(app.up, bits: bits))
                            .foregroundStyle(app.up >= 50 ? upColor : .secondary)
                            .frame(width: 72, alignment: .trailing)
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

struct SpeedTile: View {
    let title: String
    let arrow: String
    let color: Color
    let value: String
    let peak: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: arrow)
                .font(.caption)
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
            Text("Peak \(peak)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

struct SpeedGraph: View {
    let samples: [Sample]
    let capacity: Int
    let bits: Bool

    /// Height kept clear above the plot for the scale label (caption2 + padding).
    static let labelHeadroom: CGFloat = 20

    var body: some View {
        let maxValue = max(samples.map { max($0.down, $0.up) }.max() ?? 0, 1000)
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                // The top strip is reserved for the scale label, so peaks never run
                // into it; the plot's top gridline is the label's value.
                let top = Self.labelHeadroom
                let plotHeight = max(size.height - top, 1)
                for i in 0..<4 {
                    let y = top + plotHeight * CGFloat(i) / 4
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(p, with: .color(.primary.opacity(0.08)), lineWidth: 1)
                }
                guard samples.count > 1 else { return }
                let step = size.width / CGFloat(capacity - 1)
                let startX = size.width - CGFloat(samples.count - 1) * step

                func point(_ i: Int, _ v: Double) -> CGPoint {
                    CGPoint(x: startX + CGFloat(i) * step,
                            y: size.height - CGFloat(v / maxValue) * plotHeight)
                }

                var area = Path()
                area.move(to: CGPoint(x: startX, y: size.height))
                for (i, s) in samples.enumerated() { area.addLine(to: point(i, s.down)) }
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .color(downColor.opacity(0.25)))

                var downLine = Path()
                for (i, s) in samples.enumerated() {
                    i == 0 ? downLine.move(to: point(i, s.down)) : downLine.addLine(to: point(i, s.down))
                }
                ctx.stroke(downLine, with: .color(downColor), lineWidth: 1.5)

                var upLine = Path()
                for (i, s) in samples.enumerated() {
                    i == 0 ? upLine.move(to: point(i, s.up)) : upLine.addLine(to: point(i, s.up))
                }
                ctx.stroke(upLine, with: .color(upColor), lineWidth: 1.5)
            }
            Text(Format.rate(maxValue, bits: bits))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(3)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Usage

struct UsageView: View {
    @ObservedObject var meter: Meter
    @ObservedObject var usage: UsageStore
    @State private var confirmReset = false

    var body: some View {
        let today = usage.today
        let month = usage.thisMonth
        let days = usage.recentDays(UsageStore.appHistoryDays)
        let maxDay = max(days.map { $0.down + $0.up }.max() ?? 0, 1)

        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("").font(.caption)
                    Text("Download").font(.caption).foregroundStyle(downColor)
                    Text("Upload").font(.caption).foregroundStyle(upColor)
                    Text("Total").font(.caption).foregroundStyle(.secondary)
                }
                usageRow("Session", meter.sessionDown, meter.sessionUp)
                usageRow("Today", today.down, today.up)
                usageRow("This month", month.down, month.up)
            }

            Text("Last 14 days").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days, id: \.day) { d in
                    VStack(spacing: 0) {
                        Rectangle().fill(upColor)
                            .frame(height: 80 * CGFloat(Double(d.up) / Double(maxDay)))
                        Rectangle().fill(downColor)
                            .frame(height: 80 * CGFloat(Double(d.down) / Double(maxDay)))
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(d.day)\n↓ \(Format.bytes(d.down))  ↑ \(Format.bytes(d.up))")
                }
            }
            .frame(height: 80, alignment: .bottom)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

            AppUsageHistoryView(usage: usage)

            HStack {
                Spacer()
                Button("Reset usage history…") { confirmReset = true }
                    .controlSize(.small)
            }
        }
        .confirmationDialog("Erase all stored usage, including per-app history?", isPresented: $confirmReset) {
            Button("Erase", role: .destructive) { usage.resetAll() }
        }
    }

    @ViewBuilder
    private func usageRow(_ label: String, _ down: UInt64, _ up: UInt64) -> some View {
        GridRow {
            Text(label).font(.callout)
            Text(Format.bytes(down)).font(.callout.monospacedDigit())
            Text(Format.bytes(up)).font(.callout.monospacedDigit())
            Text(Format.bytes(down &+ up)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

private struct AppUsageHistoryView: View {
    @ObservedObject var usage: UsageStore
    @State private var period = 1

    var body: some View {
        let apps = usage.topApps(forLastDays: period)
        let rowHeight: CGFloat = 22

        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Top apps").font(.caption).foregroundStyle(.secondary)
                    .help("Estimated traffic by app, recorded by this version of NetMeter.")
                Spacer()
                Picker("App usage period", selection: $period) {
                    Text("Today").tag(1)
                    Text("Last 14 days").tag(UsageStore.appHistoryDays)
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            if apps.isEmpty {
                Text("No app usage recorded for this period.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                row("App", "Download", "Upload", "Total")
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(apps) { app in
                            row(app.name, Format.bytes(app.down), Format.bytes(app.up), Format.bytes(app.total))
                                .frame(height: rowHeight)
                        }
                    }
                }
                .frame(height: rowHeight * CGFloat(min(apps.count, 5)))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func row(_ name: String, _ download: String, _ upload: String, _ total: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(name)
            Text(download).foregroundStyle(downColor).frame(width: 64, alignment: .trailing)
            Text(upload).foregroundStyle(upColor).frame(width: 64, alignment: .trailing)
            Text(total).frame(width: 64, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .padding(.trailing, 8)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var meter: Meter
    @AppStorage(SettingsKey.interval) private var interval = 1.0
    @AppStorage(SettingsKey.useBits) private var bits = false
    @AppStorage(SettingsKey.displayMode) private var mode = DisplayMode.stacked.rawValue
    @AppStorage(SettingsKey.networkType) private var networkType = NetworkType.external.rawValue
    @AppStorage(SettingsKey.ignoredProcesses) private var ignored = "com.eset."
    @AppStorage(SettingsKey.floatingVisible) private var floatingVisible = false
    @AppStorage(SettingsKey.floatingOpacity) private var floatingOpacity = 0.9
    @State private var ignoredDraft = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Picker("Menu bar", selection: $mode) {
                ForEach(DisplayMode.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Picker("Units", selection: $bits) {
                Text("Bytes (MB/s)").tag(false)
                Text("Bits (Mbps)").tag(true)
            }
            Picker("Update every", selection: $interval) {
                Text("1 s").tag(1.0)
                Text("2 s").tag(2.0)
                Text("5 s").tag(5.0)
            }
            Picker("Count", selection: $networkType) {
                ForEach(NetworkType.allCases) { Text($0.label).tag($0.rawValue) }
            }
            VStack(alignment: .leading, spacing: 3) {
                TextField("Ignore processes", text: $ignoredDraft)
                    .onSubmit { ignored = ignoredDraft }
                Text("Comma-separated name prefixes hidden from the app list. Add antivirus/firewall filters that re-route other apps' traffic. Press Return to apply.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .onAppear { ignoredDraft = ignored }
            Section("Floating graph") {
                Toggle("Floating window instead of menu bar", isOn: $floatingVisible)
                HStack {
                    Text("Opacity")
                    Slider(value: $floatingOpacity, in: 0.2...1)
                    Text("\(Int(floatingOpacity * 100))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 34, alignment: .trailing)
                }
                .disabled(!floatingVisible)
            }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                    }
                }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(height: 470) // tall enough that the last row (Launch at login) isn't cut off
    }
}
