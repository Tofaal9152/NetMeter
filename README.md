# NetMeter

A lightweight macOS menu bar app that shows your internet speed, inspired by DU Meter.

- **Live speeds in the menu bar.** Upload and download, stacked or on one line, in bytes (MB/s) or bits (Mbps).
- **Details panel.** Click the menu bar item for current and peak speeds, a 2-minute graph, and the **apps using the network** right now.
- **Usage history.** Totals for this session, today and this month, plus a 14-day chart. Stored only on your Mac.
- **Floating graph window.** Optionally replace the menu bar item with a small always-on-top graph you can drag anywhere, resize and make translucent.
- **Light on resources.** About 4–5% of one CPU core at the default 1-second update, less at 2 s or 5 s.
- Launches at login (can be turned off), works with light and dark mode, universal binary for Apple Silicon and Intel.

Requires **macOS 13 Ventura or later**.

## Install

1. Download `NetMeter-x.y.z.dmg` from the [latest release](../../releases/latest).
2. Open it and drag **NetMeter** onto **Applications**.
3. **First launch only:** NetMeter isn't notarized by Apple (that needs a paid Apple Developer account), so macOS blocks it the first time:
   1. Open NetMeter from Applications and dismiss the warning.
   2. Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the NetMeter message.
   3. Confirm with your password or Touch ID.

   Alternatively, run this in Terminal once:
   ```sh
   xattr -dr com.apple.quarantine /Applications/NetMeter.app
   ```

Each release lists a SHA-256 checksum (`.sha256` file) to verify the download: `shasum -a 256 NetMeter-x.y.z.dmg`.

## Usage

- **Click the menu bar speeds** to open the panel: **Live**, **Usage** and **Settings** tabs.
- **Floating window:** the window icon next to *Quit* (or *Settings → Floating graph*) switches to the floating graph. The graph's icons open the panel or switch back to the menu bar; right-click it for opacity and *Quit*. If you ever lose the window, open NetMeter again from Applications/Spotlight and the menu bar item returns.
- **Settings:** menu bar style, units, update interval (1/2/5 s), network type (all, Wi-Fi, wired, cellular), processes to hide from the app list, launch at login.

## How it works

NetMeter reads traffic with macOS's built-in `/usr/bin/nettop`, taking one snapshot per update interval and diffing it against the previous one.

- **Why not the network interface counters** (what most menu bar meters use)? On some Macs (seen with the ESET security suite installed) the Wi-Fi interface's receive counter stays at ~0, so download speed would always read zero. `nettop` counts bytes per connection and works in both directions.
- **Why snapshots, not a continuous `nettop` stream?** A streaming `nettop` processes every update for every open connection and used over a full CPU core. A snapshot costs about 0.03 s of CPU.
- **Traffic filters.** Antivirus/firewall tools such as ESET re-route other apps' connections through their own. NetMeter counts every connection that carries byte counts exactly once and hides the filter itself from the app list (*Settings → Ignore processes*, default `com.eset.`).

**Accuracy.** Validated against a fast.com test using the Wi-Fi interface's upload counter as reference: about 2% low. A connection that opens and closes entirely between two snapshots can be missed. Per-app speeds are approximate (an app's total dips when one of its connections closes).

## Privacy

NetMeter makes **no network connections of its own**, has no analytics or telemetry, and stores usage history only in its local preferences (`~/Library/Preferences/com.jamilxt.netmeter.plist`).

## Build from source

Requires Xcode 15+ (or the Swift 5.9+ toolchain).

```sh
git clone https://github.com/jamilxt/NetMeter.git
cd NetMeter
./build.sh            # builds build/NetMeter.app (universal)
./make-dmg.sh         # also packages build/NetMeter-<version>.dmg
cp -R build/NetMeter.app /Applications/
```

Set the version with `VERSION=1.2.0 ./make-dmg.sh` (defaults to the latest git tag).

### Project layout

| File | Purpose |
|---|---|
| `Sources/NetMeter/main.swift` | App delegate, menu bar item, display-mode switching |
| `Sources/NetMeter/FlowStatsReader.swift` | `nettop` snapshot polling and traffic accounting |
| `Sources/NetMeter/Meter.swift` | Rates, history, session/daily totals, per-app ranking |
| `Sources/NetMeter/AppResolver.swift` | Maps processes to apps (names, icons, helper grouping) |
| `Sources/NetMeter/PopoverView.swift` | The panel: Live, Usage, Settings |
| `Sources/NetMeter/FloatingGraph.swift` | The floating graph window |

## Releasing

Push a version tag and GitHub Actions builds the DMG and publishes a release:

```sh
git tag v1.0.0
git push origin v1.0.0
```

## License

[MIT](LICENSE)
