import Foundation
import Combine

struct Sample: Identifiable {
    let id: Int
    let down: Double // bytes per second
    let up: Double
}

enum SettingsKey {
    static let interval = "updateInterval"
    static let useBits = "useBits"
    static let displayMode = "displayMode"
    static let networkType = "networkType"
    static let ignoredProcesses = "ignoredProcesses"
    static let floatingVisible = "floatingGraphVisible"
    static let floatingOpacity = "floatingGraphOpacity"
}

enum DisplayMode: String, CaseIterable, Identifiable {
    case stacked, singleLine, downloadOnly, uploadOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .stacked: return "Up & Down (stacked)"
        case .singleLine: return "Up & Down (one line)"
        case .downloadOnly: return "Download only"
        case .uploadOnly: return "Upload only"
        }
    }
}

@MainActor
final class Meter: ObservableObject {
    static let historyLength = 120

    @Published private(set) var down: Double = 0
    @Published private(set) var up: Double = 0
    @Published private(set) var history: [Sample] = []
    @Published private(set) var peakDown: Double = 0
    @Published private(set) var peakUp: Double = 0
    @Published private(set) var sessionDown: UInt64 = 0
    @Published private(set) var sessionUp: UInt64 = 0
    /// Apps moving the most data in the latest sample, busiest first.
    @Published private(set) var topApps: [AppUsage] = []
    static let topAppsCount = 6

    let usage = UsageStore()
    var onTick: (() -> Void)?

    private let reader = FlowStatsReader()
    private let resolver = AppResolver()
    private var sampleID = 0
    private var secondsSinceSave = 0
    private let defaults = UserDefaults.standard

    /// Sample interval in whole seconds (nettop's minimum is 1 s).
    var interval: Int {
        max(1, Int(defaults.double(forKey: SettingsKey.interval).rounded()))
    }

    var networkType: NetworkType {
        NetworkType(rawValue: defaults.string(forKey: SettingsKey.networkType) ?? "") ?? .external
    }

    /// Comma-separated process-name prefixes to exclude (see FlowStatsReader).
    var ignoredProcesses: [String] {
        (defaults.string(forKey: SettingsKey.ignoredProcesses) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func start() {
        reader.onSample = { [weak self] bytesIn, bytesOut, processes, seconds in
            self?.record(bytesIn: bytesIn, bytesOut: bytesOut, processes: processes, seconds: seconds)
        }
        reader.start(interval: interval, type: networkType, ignoring: ignoredProcesses)
    }

    /// Restarts sampling if a sampling-related setting changed.
    func reconfigureIfNeeded() {
        if reader.interval != interval || reader.type != networkType
            || reader.ignoredPrefixes != ignoredProcesses {
            reader.start(interval: interval, type: networkType, ignoring: ignoredProcesses)
        }
    }

    func stop() { reader.stop() }

    func resetSession() {
        sessionDown = 0
        sessionUp = 0
        peakDown = 0
        peakUp = 0
        history.removeAll()
    }

    func save() { usage.save() }

    private func record(bytesIn: UInt64, bytesOut: UInt64, processes: [ProcessDelta], seconds: Double) {
        topApps = rankApps(processes, seconds: seconds)
        down = Double(bytesIn) / seconds
        up = Double(bytesOut) / seconds
        peakDown = max(peakDown, down)
        peakUp = max(peakUp, up)
        sessionDown &+= bytesIn
        sessionUp &+= bytesOut
        usage.add(down: bytesIn, up: bytesOut)

        sampleID += 1
        history.append(Sample(id: sampleID, down: down, up: up))
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }

        secondsSinceSave += reader.interval
        if secondsSinceSave >= 30 {
            secondsSinceSave = 0
            usage.save()
        }

        onTick?()
    }

    private func rankApps(_ processes: [ProcessDelta], seconds: Double) -> [AppUsage] {
        var groups: [String: AppUsage] = [:]
        for p in processes {
            let info = resolver.info(pid: p.pid, name: p.name)
            var row = groups[info.id] ?? AppUsage(id: info.id, name: info.name, detail: info.detail,
                                                  icon: info.icon, down: 0, up: 0)
            row.down += Double(p.bytesIn) / seconds
            row.up += Double(p.bytesOut) / seconds
            groups[info.id] = row
        }
        return groups.values
            .filter { $0.down + $0.up >= 100 } // below this the row would read "0.0 KB/s"
            .sorted { ($0.down + $0.up, $0.name) > ($1.down + $1.up, $1.name) }
            .prefix(Self.topAppsCount)
            .map { $0 }
    }
}

/// Persists per-day byte totals in UserDefaults.
@MainActor
final class UsageStore: ObservableObject {
    private let key = "dailyUsage"
    private let keepDays = 400
    @Published private(set) var days: [String: [UInt64]] = [:] // "yyyy-MM-dd": [down, up]

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() {
        if let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: [NSNumber]] {
            days = stored.mapValues { $0.map(\.uint64Value) }
        }
    }

    static func dayKey(_ date: Date = Date()) -> String { dayFormatter.string(from: date) }

    func add(down: UInt64, up: UInt64) {
        guard down > 0 || up > 0 else { return }
        let k = Self.dayKey()
        var v = days[k] ?? [0, 0]
        v[0] &+= down
        v[1] &+= up
        days[k] = v
    }

    var today: (down: UInt64, up: UInt64) {
        let v = days[Self.dayKey()] ?? [0, 0]
        return (v[0], v[1])
    }

    var thisMonth: (down: UInt64, up: UInt64) {
        let prefix = String(Self.dayKey().prefix(7))
        return days.filter { $0.key.hasPrefix(prefix) }.values.reduce((UInt64(0), UInt64(0))) {
            ($0.0 &+ $1[0], $0.1 &+ $1[1])
        }
    }

    /// Last `count` days, oldest first, including today.
    func recentDays(_ count: Int) -> [(day: String, down: UInt64, up: UInt64)] {
        let cal = Calendar.current
        return (0..<count).reversed().map { offset in
            let date = cal.date(byAdding: .day, value: -offset, to: Date())!
            let k = Self.dayKey(date)
            let v = days[k] ?? [0, 0]
            return (k, v[0], v[1])
        }
    }

    func resetAll() {
        days.removeAll()
        save()
    }

    func save() {
        let sorted = days.keys.sorted()
        if sorted.count > keepDays {
            for k in sorted.prefix(sorted.count - keepDays) { days.removeValue(forKey: k) }
        }
        UserDefaults.standard.set(days.mapValues { $0.map { NSNumber(value: $0) } }, forKey: key)
    }
}
