import Foundation
import Combine

struct Sample: Identifiable {
    let id: Int
    let down: Double // bytes per second
    let up: Double
}

struct AppUsageTotal: Codable, Identifiable {
    let id: String
    var name: String
    var down: UInt64 = 0
    var up: UInt64 = 0

    var total: UInt64 { down &+ up }

    mutating func add(_ sample: AppUsageTotal) {
        name = sample.name
        down &+= sample.down
        up &+= sample.up
    }
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
        let apps = groupApps(processes)
        let rates = apps.map { info, bytes in
            AppUsage(id: info.id, name: info.name, detail: info.detail, icon: info.icon,
                     down: Double(bytes.down) / seconds, up: Double(bytes.up) / seconds)
        }
        let active = rates.filter { $0.down + $0.up >= 100 } // below this the row would read "0.0 KB/s"
        let ranked = active.sorted { ($0.down + $0.up, $0.name) > ($1.down + $1.up, $1.name) }
        topApps = Array(ranked.prefix(Self.topAppsCount))
        down = Double(bytesIn) / seconds
        up = Double(bytesOut) / seconds
        peakDown = max(peakDown, down)
        peakUp = max(peakUp, up)
        sessionDown &+= bytesIn
        sessionUp &+= bytesOut
        usage.add(down: bytesIn, up: bytesOut, apps: apps.map(\.bytes))

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

    private func groupApps(_ processes: [ProcessDelta]) -> [(info: AppResolver.Info, bytes: AppUsageTotal)] {
        var groups: [String: (AppResolver.Info, AppUsageTotal)] = [:]
        for p in processes {
            let info = resolver.info(pid: p.pid, name: p.name)
            var bytes = groups[info.id]?.1 ?? AppUsageTotal(id: info.id, name: info.name)
            bytes.down &+= p.bytesIn
            bytes.up &+= p.bytesOut
            groups[info.id] = (info, bytes)
        }
        return Array(groups.values)
    }
}

/// Persists per-day byte totals in UserDefaults.
@MainActor
final class UsageStore: ObservableObject {
    static let appHistoryDays = 14

    private let defaults: UserDefaults
    private let key = "dailyUsage"
    private let appKey = "dailyAppUsage"
    private let keepDays = 400
    @Published private(set) var days: [String: [UInt64]] = [:] // "yyyy-MM-dd": [down, up]
    @Published private var appDays: [String: [String: AppUsageTotal]] = [:]

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.dictionary(forKey: key) as? [String: [NSNumber]] {
            days = stored.mapValues { $0.map(\.uint64Value) }
        }
        if let data = defaults.data(forKey: appKey),
           let stored = try? JSONDecoder().decode([String: [String: AppUsageTotal]].self, from: data) {
            appDays = stored
        }
    }

    static func dayKey(_ date: Date = Date()) -> String { dayFormatter.string(from: date) }

    func add(down: UInt64, up: UInt64, apps: [AppUsageTotal]) {
        let k = Self.dayKey()
        if down > 0 || up > 0 {
            var v = days[k] ?? [0, 0]
            v[0] &+= down
            v[1] &+= up
            days[k] = v
        }
        if !apps.isEmpty {
            var totals = appDays[k] ?? [:]
            for app in apps {
                totals[app.id, default: AppUsageTotal(id: app.id, name: app.name)].add(app)
            }
            appDays[k] = totals
        }
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
        Self.recentDayKeys(count).map { k in
            let v = days[k] ?? [0, 0]
            return (k, v[0], v[1])
        }
    }

    func topApps(forLastDays count: Int) -> [AppUsageTotal] {
        var totals: [String: AppUsageTotal] = [:]
        for day in Self.recentDayKeys(count) {
            for app in appDays[day, default: [:]].values {
                totals[app.id, default: AppUsageTotal(id: app.id, name: app.name)].add(app)
            }
        }
        return totals.values.sorted {
            if $0.total != $1.total { return $0.total > $1.total }
            return ($0.name, $0.id) < ($1.name, $1.id)
        }
    }

    private static func recentDayKeys(_ count: Int) -> [String] {
        let cal = Calendar.current
        let now = Date()
        return (0..<count).reversed().map { offset in
            Self.dayKey(cal.date(byAdding: .day, value: -offset, to: now)!)
        }
    }

    func resetAll() {
        days.removeAll()
        appDays.removeAll()
        save()
    }

    func save() {
        let sorted = days.keys.sorted()
        if sorted.count > keepDays {
            for k in sorted.prefix(sorted.count - keepDays) { days.removeValue(forKey: k) }
        }
        defaults.set(days.mapValues { $0.map { NSNumber(value: $0) } }, forKey: key)
        let retained = Set(Self.recentDayKeys(Self.appHistoryDays))
        if appDays.keys.contains(where: { !retained.contains($0) }) {
            appDays = appDays.filter { retained.contains($0.key) }
        }
        if let data = try? JSONEncoder().encode(appDays) {
            defaults.set(data, forKey: appKey)
        }
    }
}
