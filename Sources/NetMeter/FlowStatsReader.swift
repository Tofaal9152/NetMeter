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

/// Streams per-interval traffic totals from `/usr/bin/nettop`.
///
/// Why not interface counters (getifaddrs / NET_RT_IFLIST2)? On recent macOS the
/// Wi-Fi receive path doesn't update `ifi_ibytes`, so download reads ~0 even though
/// upload is correct. nettop counts bytes per network flow and sees both directions.
///
/// nettop holds its output in a buffer when writing to a pipe, so it runs on a pseudo-terminal,
/// which makes it write each sample immediately.
/// Bytes one process moved during a sample.
struct ProcessDelta {
    let pid: Int32
    let name: String // as nettop prints it (may be truncated)
    var bytesIn: UInt64
    var bytesOut: UInt64
}

@MainActor
final class FlowStatsReader {
    /// Called once per completed sample with bytes received / sent during that sample,
    /// plus the per-process breakdown (only processes that moved data).
    var onSample: ((_ bytesIn: UInt64, _ bytesOut: UInt64, _ processes: [ProcessDelta]) -> Void)?

    private var process: Process?
    private var master: FileHandle?
    private var pending = ""
    private var blockIn: UInt64 = 0
    private var blockOut: UInt64 = 0
    private var blockProcs: [ProcessDelta] = []
    private var blockHasRows = false
    private var sawHeader = false
    private var blocksSeen = 0
    private var flushWork: DispatchWorkItem?
    private var generation = 0

    private(set) var interval = 1
    private(set) var type = NetworkType.external
    /// Process-name prefixes left out of the sum. Security tools that filter traffic
    /// (e.g. ESET) re-send every byte through their own connections, so their flows
    /// duplicate the originating app's and would double the totals.
    private(set) var ignoredPrefixes: [String] = []

    func start(interval: Int, type: NetworkType, ignoring ignored: [String]) {
        stop()
        self.interval = max(1, interval)
        self.type = type
        self.ignoredPrefixes = ignored
        generation += 1
        let gen = generation

        var masterFD: Int32 = 0
        var slaveFD: Int32 = 0
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            NSLog("NetMeter: openpty failed: \(errno)")
            return
        }
        // Raw-ish output: no CR translation or echo.
        var tio = termios()
        tcgetattr(slaveFD, &tio)
        tio.c_oflag &= ~tcflag_t(OPOST)
        tio.c_lflag &= ~tcflag_t(ECHO | ICANON)
        tcsetattr(slaveFD, TCSANOW, &tio)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-P", "-d", "-L", "0", "-s", String(self.interval), "-x", "-n",
                       "-t", type.rawValue, "-J", "bytes_in,bytes_out"]
        let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        p.standardOutput = slave
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            // Restart if nettop dies unexpectedly (not when we stopped it ourselves).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated {
                    guard let self, self.generation == gen else { return }
                    self.start(interval: self.interval, type: self.type, ignoring: self.ignoredPrefixes)
                }
            }
        }

        let masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        masterHandle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else {
                h.readabilityHandler = nil // EOF: nettop exited
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == gen else { return }
                    self.consume(text)
                }
            }
        }

        do {
            try p.run()
        } catch {
            NSLog("NetMeter: failed to launch nettop: \(error)")
            masterHandle.readabilityHandler = nil
            return
        }
        try? slave.close() // child keeps its own copy
        process = p
        master = masterHandle
    }

    func stop() {
        generation += 1
        flushWork?.cancel()
        master?.readabilityHandler = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        master = nil
        pending = ""
        blockIn = 0
        blockOut = 0
        blockProcs = []
        blockHasRows = false
        sawHeader = false
        blocksSeen = 0
    }

    private func consume(_ text: String) {
        pending += text
        while let nl = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(pending[..<nl])
            pending.removeSubrange(...nl)
            handle(line: line)
        }
        // A sample is written in one burst; once output goes quiet, the block is complete.
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finishBlock() }
        }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func handle(line raw: String) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard !line.isEmpty else { return }
        if line.hasPrefix(",bytes_in") || line.hasPrefix("bytes_in") {
            finishBlock()
            sawHeader = true
            return
        }
        // Rows look like "process.pid,123,456," — the process name may contain commas,
        // so take the last two numeric fields.
        var fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if fields.last == "" { fields.removeLast() }
        guard fields.count >= 3,
              let inBytes = Int64(fields[fields.count - 2]),
              let outBytes = Int64(fields[fields.count - 1]) else { return }
        let process = fields[..<(fields.count - 2)].joined(separator: ",")
        if ignoredPrefixes.contains(where: { process.hasPrefix($0) }) { return }
        let i = UInt64(max(0, inBytes))
        let o = UInt64(max(0, outBytes))
        blockIn &+= i
        blockOut &+= o
        blockHasRows = true
        if i > 0 || o > 0 {
            // "name.pid" — split at the last dot.
            var pid: Int32 = 0
            var name = process
            if let dot = process.lastIndex(of: "."), let n = Int32(process[process.index(after: dot)...]) {
                pid = n
                name = String(process[..<dot])
            }
            blockProcs.append(ProcessDelta(pid: pid, name: name, bytesIn: i, bytesOut: o))
        }
    }

    private func finishBlock() {
        flushWork?.cancel()
        flushWork = nil
        guard blockHasRows || sawHeader else { return }
        let (i, o, procs) = (blockIn, blockOut, blockProcs)
        blockIn = 0
        blockOut = 0
        blockProcs = []
        blockHasRows = false
        sawHeader = false
        blocksSeen += 1
        // In delta mode (-d) the first sample is the running total since each flow
        // started, not a per-interval delta, so it is discarded.
        guard blocksSeen > 1 else { return }
        onSample?(i, o, procs)
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
