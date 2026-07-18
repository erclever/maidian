import Cocoa

// MARK: - Total interface throughput (for the menu bar title)

func currentNetworkBytes() -> (down: UInt64, up: UInt64) {
    var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return (0, 0) }
    defer { freeifaddrs(ifaddrPtr) }

    var down: UInt64 = 0
    var up: UInt64 = 0

    var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
    while let interface = ptr?.pointee {
        defer { ptr = interface.ifa_next }

        let name = String(cString: interface.ifa_name)
        guard name.hasPrefix("en") || name.hasPrefix("utun") else { continue }
        guard interface.ifa_addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
        guard let data = interface.ifa_data else { continue }

        let networkData = data.assumingMemoryBound(to: if_data.self).pointee
        down += UInt64(networkData.ifi_ibytes)
        up += UInt64(networkData.ifi_obytes)
    }

    return (down, up)
}

func formatRate(_ bytesPerSecond: UInt64) -> String {
    let kb = Double(bytesPerSecond) / 1024.0
    if kb < 1000 {
        return String(format: "%5.1f KB/s", kb)
    } else {
        return String(format: "%5.1f MB/s", kb / 1024.0)
    }
}

func formatRateTable(_ bytesPerSecond: UInt64) -> String {
    let kb = Double(bytesPerSecond) / 1024.0
    if kb < 1000 {
        return String(format: "%.0f KB/s", kb)
    } else {
        return String(format: "%.1f MB/s", kb / 1024.0)
    }
}

// MARK: - Per-app usage via nettop

private struct RawUsage {
    let pid: Int32
    let name: String
    let bytesIn: UInt64
    let bytesOut: UInt64
}

private func parseNettop(_ output: String) -> [RawUsage] {
    var results: [RawUsage] = []
    for line in output.split(separator: "\n") {
        let cols = line.split(separator: ",", omittingEmptySubsequences: false)
        guard cols.count >= 3 else { continue }
        let label = String(cols[0])
        guard let bytesIn = UInt64(cols[1]), let bytesOut = UInt64(cols[2]) else { continue }
        guard let lastDot = label.range(of: ".", options: .backwards) else { continue }
        let namePart = String(label[label.startIndex..<lastDot.lowerBound])
        let pidPart = String(label[lastDot.upperBound...])
        guard let pid = Int32(pidPart), !namePart.isEmpty else { continue }
        results.append(RawUsage(pid: pid, name: namePart, bytesIn: bytesIn, bytesOut: bytesOut))
    }
    return results
}

private func runNettopSnapshot() -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
    task.arguments = ["-P", "-L", "1", "-J", "bytes_in,bytes_out", "-x"]
    let outPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = Pipe()
    do {
        try task.run()
    } catch {
        return nil
    }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return String(data: data, encoding: .utf8)
}

// MARK: - App usage model

struct AppUsage {
    let pid: Int32
    let name: String
    let icon: NSImage?
    let downRate: UInt64
    let upRate: UInt64

    var downText: String { formatRateTable(downRate) }
    var upText: String { formatRateTable(upRate) }
}

// MARK: - Network monitor (plain callbacks, no Combine/SwiftUI dependency)

final class NetworkMonitor {
    var onSpeedUpdate: ((String, String) -> Void)?
    var onAppsUpdate: (([AppUsage]) -> Void)?

    private var lastDown: UInt64 = 0
    private var lastUp: UInt64 = 0
    private var lastAppBytes: [Int32: (down: UInt64, up: UInt64)] = [:]
    private var lastAppPollTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var appPollCounter = 0
    private var isPopoverOpen = false

    func start() {
        let (down, up) = currentNetworkBytes()
        lastDown = down
        lastUp = up

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        let (down, up) = currentNetworkBytes()
        let downDelta = down >= lastDown ? down - lastDown : 0
        let upDelta = up >= lastUp ? up - lastUp : 0
        lastDown = down
        lastUp = up

        onSpeedUpdate?(formatRate(downDelta), formatRate(upDelta))

        guard isPopoverOpen else { return }
        appPollCounter += 1
        if appPollCounter >= 2 {
            appPollCounter = 0
            refreshTopApps()
        }
    }

    func popoverOpened() {
        isPopoverOpen = true
        appPollCounter = 0
        refreshTopApps()
    }

    func popoverClosed() {
        isPopoverOpen = false
    }

    private func refreshTopApps() {
        let pollTime = ProcessInfo.processInfo.systemUptime
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let output = runNettopSnapshot() else { return }
            let raw = parseNettop(output)
            DispatchQueue.main.async {
                self?.applyNettopSnapshot(raw, at: pollTime)
            }
        }
    }

    private func applyNettopSnapshot(_ raw: [RawUsage], at pollTime: TimeInterval) {
        let elapsed = pollTime - lastAppPollTime
        lastAppPollTime = pollTime
        // First sample (or a too-short interval) has no valid rate to compute yet.
        guard elapsed > 0.1 else { return }

        var deltas: [(pid: Int32, name: String, down: UInt64, up: UInt64)] = []
        var newSnapshot: [Int32: (down: UInt64, up: UInt64)] = [:]

        for usage in raw {
            newSnapshot[usage.pid] = (usage.bytesIn, usage.bytesOut)
            if let prev = lastAppBytes[usage.pid] {
                let downDeltaBytes = usage.bytesIn >= prev.down ? usage.bytesIn - prev.down : 0
                let upDeltaBytes = usage.bytesOut >= prev.up ? usage.bytesOut - prev.up : 0
                if downDeltaBytes > 0 || upDeltaBytes > 0 {
                    let downRate = UInt64(Double(downDeltaBytes) / elapsed)
                    let upRate = UInt64(Double(upDeltaBytes) / elapsed)
                    deltas.append((usage.pid, usage.name, downRate, upRate))
                }
            }
        }
        lastAppBytes = newSnapshot

        let top = deltas
            .sorted { ($0.down + $0.up) > ($1.down + $1.up) }
            .prefix(6)
            .map { entry -> AppUsage in
                let runningApp = NSRunningApplication(processIdentifier: entry.pid)
                let name = runningApp?.localizedName ?? entry.name
                let icon = runningApp?.icon
                return AppUsage(pid: entry.pid, name: name, icon: icon, downRate: entry.down, upRate: entry.up)
            }

        onAppsUpdate?(Array(top))
    }
}

// MARK: - Popover content, built with plain AppKit views (no SwiftUI)

private let contentWidth: CGFloat = 260
private let rowWidth: CGFloat = 232 // contentWidth - 2*14 side padding
private let valueColumnWidth: CGFloat = 62

/// The big "↓ 12.3 KB/s   ↑ 4.5 KB/s" row at the top of the popover.
final class SpeedHeaderView: NSView {
    private let downValueLabel = NSTextField(labelWithString: "-- KB/s")
    private let upValueLabel = NSTextField(labelWithString: "-- KB/s")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)

        let downIcon = NSTextField(labelWithString: "↓")
        downIcon.font = font
        downIcon.textColor = .systemGreen
        downValueLabel.font = font
        downValueLabel.textColor = .systemGreen

        let upIcon = NSTextField(labelWithString: "↑")
        upIcon.font = font
        upIcon.textColor = .systemRed
        upValueLabel.font = font
        upValueLabel.textColor = .systemRed

        for label in [downIcon, downValueLabel, upIcon, upValueLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: rowWidth),
            heightAnchor.constraint(equalToConstant: 20),

            downIcon.leadingAnchor.constraint(equalTo: leadingAnchor),
            downIcon.centerYAnchor.constraint(equalTo: centerYAnchor),

            downValueLabel.leadingAnchor.constraint(equalTo: downIcon.trailingAnchor, constant: 4),
            downValueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            upValueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            upValueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            upIcon.trailingAnchor.constraint(equalTo: upValueLabel.leadingAnchor, constant: -4),
            upIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func update(down: String, up: String) {
        downValueLabel.stringValue = down
        upValueLabel.stringValue = up
    }
}

/// The "App / Down / Up" column header row above the app table.
final class ColumnHeaderView: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let font = NSFont.systemFont(ofSize: 11, weight: .bold)

        let appLabel = NSTextField(labelWithString: "App")
        appLabel.font = font

        let downLabel = NSTextField(labelWithString: "Down")
        downLabel.font = font
        downLabel.textColor = .systemGreen
        downLabel.alignment = .right

        let upLabel = NSTextField(labelWithString: "Up")
        upLabel.font = font
        upLabel.textColor = .systemRed
        upLabel.alignment = .right

        for label in [appLabel, downLabel, upLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: rowWidth),
            heightAnchor.constraint(equalToConstant: 16),

            appLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            appLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            downLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(valueColumnWidth + 8)),
            downLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            downLabel.widthAnchor.constraint(equalToConstant: valueColumnWidth),

            upLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            upLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            upLabel.widthAnchor.constraint(equalToConstant: valueColumnWidth),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

/// One row of the app table: icon, name, down rate, up rate.
final class AppRowView: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let downLabel = NSTextField(labelWithString: "")
    private let upLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        nameLabel.font = font
        nameLabel.lineBreakMode = .byTruncatingTail
        downLabel.font = font
        downLabel.alignment = .right
        downLabel.textColor = .systemGreen
        upLabel.font = font
        upLabel.alignment = .right
        upLabel.textColor = .systemRed

        for view in [iconView, nameLabel, downLabel, upLabel] {
            addSubview(view)
        }
        for label in [nameLabel, downLabel, upLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: rowWidth),
            heightAnchor.constraint(equalToConstant: 18),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: downLabel.leadingAnchor, constant: -6),

            downLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(valueColumnWidth + 8)),
            downLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            downLabel.widthAnchor.constraint(equalToConstant: valueColumnWidth),

            upLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            upLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            upLabel.widthAnchor.constraint(equalToConstant: valueColumnWidth),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(with app: AppUsage) {
        iconView.image = app.icon
        nameLabel.stringValue = app.name
        downLabel.stringValue = app.downText
        upLabel.stringValue = app.upText
    }

    /// Blanks the row instead of hiding it, so the popover height never changes
    /// as the number of active apps goes up or down.
    func configureEmpty() {
        iconView.image = nil
        nameLabel.stringValue = ""
        downLabel.stringValue = ""
        upLabel.stringValue = ""
    }
}

final class PopoverViewController: NSViewController {
    private let speedHeader = SpeedHeaderView()
    private var rows: [AppRowView] = []

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 280))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let caption = NSTextField(labelWithString: "Apps using network")
        caption.font = NSFont.systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let columnHeader = ColumnHeaderView()
        rows = (0..<6).map { _ in AppRowView() }

        let stack = NSStackView(views: [speedHeader, separator, caption, columnHeader] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            separator.widthAnchor.constraint(equalToConstant: rowWidth),
        ])
    }

    func updateSpeed(down: String, up: String) {
        speedHeader.update(down: down, up: up)
    }

    func updateApps(_ apps: [AppUsage]) {
        for (index, row) in rows.enumerated() {
            if index < apps.count {
                row.configure(with: apps[index])
            } else {
                row.configureEmpty()
            }
        }
    }
}

// MARK: - App delegate wiring NSStatusItem + NSPopover

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let monitor = NetworkMonitor()
    private let popoverViewController = PopoverViewController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: 150)
        statusItem.button?.attributedTitle = statusTitle(down: "--", up: "--")
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 260, height: 280)
        popover.contentViewController = popoverViewController
        popover.delegate = self

        monitor.onSpeedUpdate = { [weak self] downText, upText in
            self?.statusItem.button?.attributedTitle = self?.statusTitle(down: downText, up: upText) ?? NSAttributedString()
            self?.popoverViewController.updateSpeed(down: downText, up: upText)
        }
        monitor.onAppsUpdate = { [weak self] apps in
            self?.popoverViewController.updateApps(apps)
        }
        monitor.start()
    }

    private func statusTitle(down: String, up: String) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let textColor = NSColor.labelColor
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: "↓ ", attributes: [.foregroundColor: NSColor.systemGreen, .font: font]))
        result.append(NSAttributedString(string: down, attributes: [.foregroundColor: textColor, .font: font]))
        result.append(NSAttributedString(string: "  ↑ ", attributes: [.foregroundColor: NSColor.systemRed, .font: font]))
        result.append(NSAttributedString(string: up, attributes: [.foregroundColor: textColor, .font: font]))
        return result
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverWillShow(_ notification: Notification) {
        monitor.popoverOpened()
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.popoverClosed()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
