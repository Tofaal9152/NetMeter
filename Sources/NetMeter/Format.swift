import Foundation

enum Format {
    /// Formats a rate in bytes/second, e.g. "12.3 MB/s" or "98.4 Mbps".
    static func rate(_ bytesPerSec: Double, bits: Bool) -> String {
        let units = bits ? ["bps", "Kbps", "Mbps", "Gbps", "Tbps"]
                         : ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        var value = bits ? bytesPerSec * 8 : bytesPerSec
        var i = 0
        // Start at K-units: tiny values read better as "0.4 KB/s" than "412 B/s".
        value /= 1000; i = 1
        while value >= 999.5 && i < units.count - 1 {
            value /= 1000
            i += 1
        }
        let number: String
        if value < 10 { number = String(format: "%.1f", value) }
        else { number = String(format: "%.0f", value) }
        return "\(number) \(units[i])"
    }

    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .decimal)
    }
}
