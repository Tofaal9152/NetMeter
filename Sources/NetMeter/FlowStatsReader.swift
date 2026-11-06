import Darwin
import Foundation

/// Network type filter passed to `nettop -t`.
enum NetworkType: String, CaseIterable, Identifiable {
    case external, wifi, wired, cell
    var id: String { rawValue }
    var label: String {
        switch self {
        case .external: return "All networks"
        case .wifi: return "Wi-Fi only"
        case .wired: return "Wired only"
        case .cell: return "Cellular only"
        }
    }
}

/// Bytes one process moved during a sample.
struct ProcessDelta {
    let pid: Int32
    let name: String // as nettop prints it (may be truncated)
    var bytesIn: UInt64
    var bytesOut: UInt64
}

/// Measures traffic by polling one-shot `/usr/bin/nettop` snapshots.
///
/// Why nettop: on recent macOS (at least with traffic filters such as ESET installed)
/// the Wi-Fi interface's receive counter (`ifi_ibytes`) stays ~0, so interface
/// counters can't measure download. nettop reports bytes per connection.
///
/// Why polling instead of `nettop -L 0` streaming: a streaming nettop receives every
/// update for every connection and used ~125% CPU continuously, whatever the sample
/// interval. A one-shot snapshot costs ~0.03 s of CPU, so ~3% at one per second.
///
/// How totals are computed: each connection row carries cumulative bytes; the
/// difference from the previous snapshot is the traffic in between. Connections that
/// a traffic filter re-routes appear with blank byte counts under the app, while the
/// filter's own connections carry those bytes, so summing every row that has numbers
/// counts all traffic once. Per-app rates come from the per-process rows, which also
/// include re-routed traffic.
@MainActor
final class FlowStatsReader {
    /// Called once per sample with bytes received / sent since the previous sample,
    /// the per-process breakdown (only processes that moved data, ignored ones
    /// excluded) and the seconds the sample covers.
    var onSample: ((_ bytesIn: UInt64, _ bytesOut: UInt64, _ processes: [ProcessDelta],
                    _ seconds: Double) -> Void)?

    private(set) var interval = 1
    private(set) var type = NetworkType.external
    /// Process-name prefixes hidden from the per-app list. Traffic filters (e.g. ESET)
    /// re-send other apps' traffic; their connections still count toward the totals.
    private(set) var ignoredPrefixes: [String] = []

    private var timer: Timer?
    private var running: Process?
    private var generation = 0

    /// Last cumulative (in, out) per connection / process, kept for a while after it
    /// disappears so a row that drops out of one snapshot and returns isn't recounted.
    private struct Seen { var bytesIn: UInt64; var bytesOut: UInt64; var lastSeen: TimeInterval }
    private var flows: [String: Seen] = [:]
    private var procs: [String: Seen] = [:]
    private var lastSnapshotTime: TimeInterval?
    private static let forgetAfter: TimeInterval = 600

    func start(interval: Int, type: NetworkType, ignoring ignored: [String]) {
        stop()
        self.interval = max(1, interval)
        self.type = type
        self.ignoredPrefixes = ignored
        generation += 1
        poll() // baseline snapshot
        let t = Timer(timeInterval: TimeInterval(self.interval), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
        if let p = running, p.isRunning { p.terminate() }
        running = nil
        flows.removeAll()
        procs.removeAll()
        lastSnapshotTime = nil
    }

    // MARK: Snapshot

    private func poll() {
        guard running == nil else { return } // previous snapshot still running; skip
        let gen = generation
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-L", "1", "-x", "-n", "-t", type.rawValue, "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        running = p

        do {
            try p.run()
        } catch {
            NSLog("NetMeter: failed to launch nettop: \(error)")
            running = nil
            return
        }
        // nettop exits after one snapshot; read its whole output off the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            let now = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == gen else { return }
                    self.running = nil
                    self.ingest(text, at: now)
                }
            }
        }
    }

    private func ingest(_ text: String, at now: TimeInterval) {
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var perProcess: [ProcessDelta] = []
        var process = ""

        for line in text.split(separator: "\n") {
            // Rows: "<process.pid or connection>,<bytes_in>,<bytes_out>,". Process names
            // may contain commas, so take the last two numeric fields.
            var fields = line.split(separator: ",", omittingEmptySubsequences: false)
            if fields.last?.isEmpty == true { fields.removeLast() }
            guard fields.count >= 3 else { continue }
            let name = fields[..<(fields.count - 2)].joined(separator: ",")
            let inField = fields[fields.count - 2], outField = fields[fields.count - 1]
            if name.isEmpty { continue } // header row

            if name.contains("<->") {
                // Connection row; blank counts mean a filter re-routes it (see above).
                guard let i = UInt64(inField), let o = UInt64(outField) else { continue }
                let (di, dout) = delta(for: process + "|" + name, i, o, in: &flows, now: now)
                totalIn &+= di
                totalOut &+= dout
            } else {
                process = name
                guard let i = UInt64(inField), let o = UInt64(outField) else { continue }
                let (di, dout) = delta(for: name, i, o, in: &procs, now: now,
                                       countDropAsNew: false)
                guard di > 0 || dout > 0,
                      !ignoredPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
                var pid: Int32 = 0
                var procName = name
                if let dot = name.lastIndex(of: "."), let n = Int32(name[name.index(after: dot)...]) {
                    pid = n
                    procName = String(name[..<dot])
                }
                perProcess.append(ProcessDelta(pid: pid, name: procName, bytesIn: di, bytesOut: dout))
            }
        }

        flows = flows.filter { now - $0.value.lastSeen < Self.forgetAfter }
        procs = procs.filter { now - $0.value.lastSeen < Self.forgetAfter }

        defer { lastSnapshotTime = now }
        guard let last = lastSnapshotTime else { return } // first snapshot is the baseline
        onSample?(totalIn, totalOut, perProcess, max(now - last, 0.1))
    }

    /// Bytes moved since this row was last seen.
    /// - countDropAsNew: for a connection, a smaller value means a new connection reused
    ///   the same addresses, so all of it is new. A process total also shrinks when one
    ///   of its connections closes; there the drop is just ignored.
    private func delta(for key: String, _ i: UInt64, _ o: UInt64, in table: inout [String: Seen],
                       now: TimeInterval, countDropAsNew: Bool = true) -> (UInt64, UInt64) {
        defer { table[key] = Seen(bytesIn: i, bytesOut: o, lastSeen: now) }
        guard lastSnapshotTime != nil else { return (0, 0) } // building the baseline
        guard let prev = table[key] else { return (i, o) }    // appeared since last snapshot
        let di = i >= prev.bytesIn ? i - prev.bytesIn : (countDropAsNew ? i : 0)
        let dout = o >= prev.bytesOut ? o - prev.bytesOut : (countDropAsNew ? o : 0)
        return (di, dout)
    }
}

// MARK: - Orphan cleanup

extension FlowStatsReader {
    /// Kills nettop processes left behind by an earlier NetMeter that was force-quit or
    /// crashed. nettop keeps running after its output closes, so without this every
    /// unclean exit would leak one. Only matches nettop processes that are owned by
    /// this user, orphaned (parent is launchd) and started with NetMeter's exact
    /// argument pattern, so a nettop the user is running themselves is never touched.
    nonisolated static func killOrphanedNettops() {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let uid = getuid()

        for pid in pids.prefix(Int(max(0, n))) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_ppid == 1, info.pbi_uid == uid else { continue }

            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                  String(cString: path) == "/usr/bin/nettop" else { continue }

            let args = arguments(of: pid)
            // nettop splits its -J value in place ("bytes_in,bytes_out" -> "bytes_in"
            // NUL "bytes_out"), so other processes see only the first column name.
            guard args.count == 13,
                  Array(args[1...4]) == ["-P", "-d", "-L", "0"],
                  args[11] == "-J", args[12].hasPrefix("bytes_in") else { continue }
            kill(pid, SIGTERM)
        }
    }

    /// argv of another process via KERN_PROCARGS2.
    private nonisolated static func arguments(of pid: pid_t) -> [String] {
        // The size query for KERN_PROCARGS2 under-reports; allocate KERN_ARGMAX instead.
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        var argmaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argmaxMib, 2, &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else { return [] }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = Int(argmax)
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }

        let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 } // skip exec path
        while i < size && buf[i] == 0 { i += 1 } // skip padding
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}
