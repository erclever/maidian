import Cocoa
import ServiceManagement

// MARK: - Total interface throughput (for the menu bar title)

func currentNetworkBytes() -> [String: (down: UInt64, up: UInt64)] {
    var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return [:] }
    defer { freeifaddrs(ifaddrPtr) }

    var result: [String: (down: UInt64, up: UInt64)] = [:]

    var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
    while let interface = ptr?.pointee {
        defer { ptr = interface.ifa_next }

        let name = String(cString: interface.ifa_name)
        guard name.hasPrefix("en") && (interface.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
        guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK) else { continue }
        guard let data = interface.ifa_data else { continue }

        let networkData = data.assumingMemoryBound(to: if_data.self).pointee
        result[name] = (UInt64(networkData.ifi_ibytes), UInt64(networkData.ifi_obytes))
    }

    return result
}

func formatRate(_ bytesPerSecond: UInt64) -> String {
    let kb = Double(bytesPerSecond) / 1024.0
    if kb < 1000 {
        return String(format: "%5.1f KB/s", kb)
    } else if kb < 1024 * 1000 {
        return String(format: "%5.1f MB/s", kb / 1024.0)
    } else {
        return String(format: "%5.1f GB/s", kb / 1024.0 / 1024.0)
    }
}

func formatRateTable(_ bytesPerSecond: UInt64) -> String {
    let kb = Double(bytesPerSecond) / 1024.0
    if kb > 0 && kb < 1 { return String(format: "%.1f KB/s", kb) }
    if kb < 1000 {
        return String(format: "%.0f KB/s", kb)
    } else {
        return String(format: "%.1f MB/s", kb / 1024.0)
    }
}

private let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
private let statusTextWidth: CGFloat = {
    let examples = ["99.9K/s", "99.9M/s", "99.9G/s", "99.9T/s", "999K/s", "999M/s", "999G/s", "999T/s", ">999T/s"]
    return ceil(examples.map { ($0 as NSString).size(withAttributes: [.font: statusFont]).width }.max() ?? 40)
}()

private func compactStatus(_ text: String) -> String {
    let fields = text.split(whereSeparator: { $0.isWhitespace })
    guard fields.count == 2, var value = Double(fields[0]), value.isFinite, value >= 0,
          let start = ["KB/s", "MB/s", "GB/s"].firstIndex(of: String(fields[1])) else { return "--" }
    let units = ["K/s", "M/s", "G/s", "T/s"]
    var unit = start
    while value >= 999.5 && unit < units.count - 1 { value /= 1024; unit += 1 }
    if value >= 999.5 { return ">999T/s" }
    return String(format: value < 100 ? "%.1f%@" : "%.0f%@", value, units[unit])
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

// Owns the short-lived system samplers. A generation prevents a queued job
// from starting after its panel has closed or the ranking mode has changed.
private final class SamplingCommandRunner {
    private let lock = NSLock()
    private var generation = 0
    private var active: Process?

    func advance(to newGeneration: Int) {
        lock.lock()
        generation = newGeneration
        if let process = active, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        lock.unlock()
    }

    var activePID: Int32? {
        lock.lock(); defer { lock.unlock() }
        return active?.isRunning == true ? active?.processIdentifier : nil
    }

    func run(_ executable: String, arguments: [String], generation token: Int, timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        lock.lock()
        guard generation == token, active == nil else { lock.unlock(); return nil }
        do { try process.run() } catch { lock.unlock(); return nil }
        active = process
        lock.unlock()

        let deadline = DispatchWorkItem { [weak self, weak process] in
            guard let self = self, let process = process else { return }
            self.lock.lock()
            if self.active === process, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            self.lock.unlock()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        lock.lock()
        if active === process { active = nil }
        let valid = generation == token
        lock.unlock()
        guard valid, process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private func runNettopSnapshot(using runner: SamplingCommandRunner, generation: Int) -> String? {
    guard let output = runner.run("/usr/bin/nettop", arguments: ["-n", "-P", "-L", "1", "-J", "bytes_in,bytes_out", "-x"], generation: generation),
          output.contains("bytes_in"), output.contains("bytes_out") else { return nil }
    return output
}

private func memorySnapshot(using runner: SamplingCommandRunner, generation: Int) -> [(pid: Int32, name: String, down: UInt64, up: UInt64)]? {
    guard let text = runner.run("/bin/ps", arguments: ["-axo", "pid=,rss=,comm="], generation: generation) else { return nil }
    return text.split(separator: "\n").compactMap { line in
        let fields = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
        guard fields.count == 3, let pid = Int32(fields[0]), let rss = UInt64(fields[1]), rss > 0 else { return nil }
        return (pid: pid, name: URL(fileURLWithPath: String(fields[2])).lastPathComponent, down: rss * 1024, up: 0)
    }
}

enum RankOrder { case total, download, upload }

private func sortedUsage(_ items: [AppUsage], order: RankOrder) -> [AppUsage] {
    func value(_ item: AppUsage) -> UInt64 {
        switch order { case .total: return item.downRate &+ item.upRate; case .download: return item.downRate; case .upload: return item.upRate }
    }
    return items.sorted { a, b in value(a) == value(b) ? a.name.localizedStandardCompare(b.name) == .orderedAscending : value(a) > value(b) }
}

private func temperatureColor(_ value: Double) -> NSColor {
    guard value.isFinite else { return .secondaryLabelColor }
    return value >= 80 ? .systemRed : value >= 60 ? .systemOrange : .systemBlue
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
    var onAppsError: ((Bool) -> Void)?

    private var lastInterfaces: [String: (down: UInt64, up: UInt64)] = [:]
    private var lastSpeedTime = ProcessInfo.processInfo.systemUptime
    private var generation = 0
    private let runner = SamplingCommandRunner()
    private var lastAppBytes: [Int32: (down: UInt64, up: UInt64)] = [:]
    private var lastAppPollTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var appPollCounter = 0
    private var isPopoverOpen = false
    private var samplingApps = false
    private var networkMode = false
    private var hasSamplingError = false
    private var hasRankSnapshot = false
    private var rankOrder: RankOrder = .total
    private var groupedCache: [AppUsage] = []

    func start() {
        lastInterfaces = currentNetworkBytes()
        lastSpeedTime = ProcessInfo.processInfo.systemUptime

        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        let current = currentNetworkBytes()
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastSpeedTime
        lastSpeedTime = now
        var downDelta: UInt64 = 0, upDelta: UInt64 = 0
        if elapsed > 0.1 && elapsed < 5 {
            for (name, bytes) in current {
                guard let previous = lastInterfaces[name] else { continue }
                if bytes.down >= previous.down { downDelta += UInt64(Double(bytes.down - previous.down) / elapsed) }
                if bytes.up >= previous.up { upDelta += UInt64(Double(bytes.up - previous.up) / elapsed) }
            }
        }
        lastInterfaces = current

        onSpeedUpdate?(formatRate(downDelta), formatRate(upDelta))

        guard isPopoverOpen else { return }
        appPollCounter += 1
        if appPollCounter >= 1 {
            appPollCounter = 0
            refreshTopApps()
        }
    }

    func popoverOpened() {
        isPopoverOpen = true
        hasRankSnapshot = false
        groupedCache.removeAll()
        generation += 1
        runner.advance(to: generation)
        lastAppBytes.removeAll()
        appPollCounter = 0
        refreshTopApps()
    }

    func popoverClosed() {
        isPopoverOpen = false
        generation += 1
        runner.advance(to: generation)
        lastAppBytes.removeAll()
    }

    func selectNetwork(_ enabled: Bool) {
        networkMode = enabled
        hasSamplingError = false
        hasRankSnapshot = false
        rankOrder = .total
        groupedCache.removeAll()
        generation += 1
        runner.advance(to: generation)
        lastAppBytes.removeAll()
        if isPopoverOpen { refreshTopApps() }
    }

    func selectSort(_ order: RankOrder) {
        rankOrder = order
        if !hasSamplingError && hasRankSnapshot { renderGrouped() }
    }

    private func refreshTopApps() {
        guard !samplingApps else { return }
        samplingApps = true
        let pollTime = ProcessInfo.processInfo.systemUptime
        let currentGeneration = generation
        let network = networkMode
        let runner = runner
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let output = network ? runNettopSnapshot(using: runner, generation: currentGeneration) : nil
            let raw = output.map(parseNettop) ?? []
            let memory = network ? nil : memorySnapshot(using: runner, generation: currentGeneration)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.samplingApps = false
                guard self.isPopoverOpen else { return }
                guard self.generation == currentGeneration else { self.refreshTopApps(); return }
                if network {
                    guard output != nil else {
                        self.lastAppBytes.removeAll()
                        self.groupedCache.removeAll()
                        self.hasSamplingError = true
                        self.onAppsError?(true)
                        return
                    }
                    self.hasSamplingError = false
                    self.applyNettopSnapshot(raw, at: pollTime)
                } else {
                    guard let memory = memory, !memory.isEmpty else {
                        self.groupedCache.removeAll()
                        self.hasSamplingError = true
                        self.onAppsError?(false)
                        return
                    }
                    self.hasSamplingError = false
                    self.applyGrouped(memory)
                }
            }
        }
    }

    private func applyNettopSnapshot(_ raw: [RawUsage], at pollTime: TimeInterval) {
        let elapsed = pollTime - lastAppPollTime
        lastAppPollTime = pollTime
        // First sample (or a too-short interval) has no valid rate to compute yet.
        guard elapsed > 0.1 else { return }

        let isFirstSample = lastAppBytes.isEmpty
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
        if isFirstSample && !newSnapshot.isEmpty { return }
        applyGrouped(deltas)
    }

    private func applyGrouped(_ deltas: [(pid: Int32, name: String, down: UInt64, up: UInt64)]) {
        var groups: [String: AppUsage] = [:]
        for entry in deltas {
            var buffer = [CChar](repeating: 0, count: 4096)
            let length = proc_pidpath(entry.pid, &buffer, UInt32(buffer.count))
            let path = length > 0 ? String(cString: buffer) : ""
            let parts = path.components(separatedBy: "/")
            let appIndex = parts.firstIndex { $0.hasSuffix(".app") }
            let appPath = appIndex.map { parts.prefix($0 + 1).joined(separator: "/") }
            let bundle = appPath.flatMap { Bundle(path: $0) }
            let key = bundle?.bundleIdentifier ?? "pid:\(entry.pid)"
            let running = NSRunningApplication(processIdentifier: entry.pid)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? running?.localizedName ?? entry.name
            let old = groups[key]
            groups[key] = AppUsage(pid: entry.pid, name: old?.name ?? name, icon: nil, downRate: (old?.downRate ?? 0) + entry.down, upRate: (old?.upRate ?? 0) + entry.up)
        }
        groupedCache = Array(groups.values)
        hasRankSnapshot = true
        renderGrouped()
    }

    private func renderGrouped() {
        let top = sortedUsage(groupedCache, order: rankOrder).prefix(10)

        let display = top.map { item -> AppUsage in
            var path = [CChar](repeating: 0, count: 4096)
            let len = proc_pidpath(item.pid, &path, UInt32(path.count))
            let components = len > 0 ? String(cString: path).components(separatedBy: "/") : []
            let appIndex = components.firstIndex { $0.hasSuffix(".app") }
            let appPath = appIndex.map { components.prefix($0 + 1).joined(separator: "/") }
            let icon = appPath.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSRunningApplication(processIdentifier: item.pid)?.icon
            return AppUsage(pid: item.pid, name: item.name, icon: icon, downRate: item.downRate, upRate: item.upRate)
        }
        onAppsUpdate?(display)
    }
}

// MARK: - Popover content, built with plain AppKit views (no SwiftUI)

private let contentWidth: CGFloat = 360
private let rowWidth: CGFloat = 332 // contentWidth - 2*14 side padding
private let valueColumnWidth: CGFloat = 62

/// The big "↓ 12.3 KB/s   ↑ 4.5 KB/s" row at the top of the popover.
final class SpeedHeaderView: NSView {
    private let downValueLabel = NSTextField(labelWithString: "-- KB/s")
    private let upValueLabel = NSTextField(labelWithString: "-- KB/s")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let downTitle = NSTextField(labelWithString: "下载")
        let upTitle = NSTextField(labelWithString: "上传")
        for title in [downTitle, upTitle] {
            title.font = .systemFont(ofSize: 10, weight: .medium)
            title.textColor = .labelColor
        }
        upTitle.alignment = .right
        let font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        downValueLabel.font = font; downValueLabel.textColor = .systemTeal
        upValueLabel.font = font; upValueLabel.textColor = .systemIndigo; upValueLabel.alignment = .right
        for label in [downTitle, upTitle, downValueLabel, upValueLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false; addSubview(label)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: rowWidth), heightAnchor.constraint(equalToConstant: 42),
            downTitle.leadingAnchor.constraint(equalTo: leadingAnchor), downTitle.topAnchor.constraint(equalTo: topAnchor),
            upTitle.trailingAnchor.constraint(equalTo: trailingAnchor), upTitle.topAnchor.constraint(equalTo: topAnchor),
            downValueLabel.leadingAnchor.constraint(equalTo: leadingAnchor), downValueLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            upValueLabel.trailingAnchor.constraint(equalTo: trailingAnchor), upValueLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            downValueLabel.trailingAnchor.constraint(lessThanOrEqualTo: upValueLabel.leadingAnchor, constant: -12),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    func update(down: String, up: String) {
        downValueLabel.stringValue = down.trimmingCharacters(in: .whitespaces)
        upValueLabel.stringValue = up.trimmingCharacters(in: .whitespaces)
    }
}

/// The "App / Down / Up" column header row above the app table.
final class ColumnHeaderView: NSView {
    private let downButton = NSButton(title: "下载", target: nil, action: nil)
    private let upButton = NSButton(title: "上传", target: nil, action: nil)
    private let memoryHeader = NSTextField(labelWithString: "内存")
    var onSort: ((RankOrder) -> Void)?
    private var network = false
    private var selected: RankOrder = .total

    func setNetwork(_ enabled: Bool) {
        network = enabled
        selected = .total
        updateButtons()
    }
    private func updateButtons() {
        downButton.isHidden = !network
        upButton.isHidden = !network
        memoryHeader.isHidden = network
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let muted = dark ? NSColor(calibratedWhite: 0.78, alpha: 1) : NSColor(calibratedWhite: 0.30, alpha: 1)
        let accent = dark ? NSColor(calibratedRed: 0.38, green: 0.68, blue: 1, alpha: 1) : NSColor(calibratedRed: 0.0, green: 0.35, blue: 0.74, alpha: 1)
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        downButton.attributedTitle = NSAttributedString(string: selected == .download ? "下载 ↓" : "下载", attributes: [.foregroundColor: selected == .download ? accent : muted, .font: font])
        upButton.attributedTitle = NSAttributedString(string: network ? (selected == .upload ? "上传 ↓" : "上传") : "内存", attributes: [.foregroundColor: selected == .upload ? accent : muted, .font: font])
        downButton.toolTip = "按下载速度从高到低排序"
        upButton.toolTip = network ? "按上传速度从高到低排序" : nil
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateButtons() }
    @objc private func sortDownload() { selected = .download; updateButtons(); onSort?(.download) }
    @objc private func sortUpload() { guard network else { return }; selected = .upload; updateButtons(); onSort?(.upload) }
    func smokeSort(_ order: RankOrder) { if order == .download { sortDownload() } else if order == .upload { sortUpload() } }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let appLabel = NSTextField(labelWithString: "应用")
        appLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        appLabel.textColor = .labelColor
        downButton.target = self; downButton.action = #selector(sortDownload)
        upButton.target = self; upButton.action = #selector(sortUpload)
        for button in [downButton, upButton] {
            button.isBordered = false
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.alignment = .right
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
        }
        appLabel.translatesAutoresizingMaskIntoConstraints = false
        memoryHeader.translatesAutoresizingMaskIntoConstraints = false
        memoryHeader.font = .systemFont(ofSize: 11, weight: .medium)
        memoryHeader.textColor = .labelColor; memoryHeader.alignment = .right
        addSubview(appLabel); addSubview(memoryHeader)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: rowWidth), heightAnchor.constraint(equalToConstant: 20),
            appLabel.leadingAnchor.constraint(equalTo: leadingAnchor), appLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            downButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(valueColumnWidth + 8)),
            downButton.centerYAnchor.constraint(equalTo: centerYAnchor), downButton.widthAnchor.constraint(equalToConstant: valueColumnWidth),
            upButton.trailingAnchor.constraint(equalTo: trailingAnchor), upButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            upButton.widthAnchor.constraint(equalToConstant: valueColumnWidth),
            memoryHeader.trailingAnchor.constraint(equalTo: trailingAnchor), memoryHeader.centerYAnchor.constraint(equalTo: centerYAnchor),
            memoryHeader.widthAnchor.constraint(equalToConstant: valueColumnWidth),
        ])
        updateButtons()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

/// Compact meter with a neutral track and a system accent fill.
final class UsageBar: NSView {
    var fraction: Double? { didSet { needsDisplay = true } }
    var tint: NSColor = .systemBlue { didSet { needsDisplay = true } }
    override init(frame: NSRect) { super.init(frame: frame); translatesAutoresizingMaskIntoConstraints = false }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.separatorColor.withAlphaComponent(0.42).setFill(); track.fill()
        if let f = fraction, f > 0 {
            let width = max(bounds.height, bounds.width * CGFloat(min(1, max(0, f))))
            let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
            tint.setFill(); fill.fill()
        }
    }
}

final class PanelBackground: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .menu
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

/// One row of the app table: icon, name, down rate, up rate.
final class AppRowView: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let downLabel = NSTextField(labelWithString: "")
    private let upLabel = NSTextField(labelWithString: "")
    private var networkNameEnd: NSLayoutConstraint!
    private var memoryNameEnd: NSLayoutConstraint!

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
        downLabel.textColor = .systemTeal
        upLabel.font = font
        upLabel.alignment = .right
        upLabel.textColor = .systemRed

        for view in [iconView, nameLabel, downLabel, upLabel] {
            addSubview(view)
        }
        for label in [nameLabel, downLabel, upLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
        }

        networkNameEnd = nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: downLabel.leadingAnchor, constant: -6)
        memoryNameEnd = nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: upLabel.leadingAnchor, constant: -6)
        memoryNameEnd.isActive = true
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: rowWidth),
            heightAnchor.constraint(equalToConstant: 22),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            downLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(valueColumnWidth + 8)),
            downLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            downLabel.widthAnchor.constraint(equalToConstant: valueColumnWidth),

            upLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            upLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            upLabel.widthAnchor.constraint(equalToConstant: valueColumnWidth),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(with app: AppUsage, network: Bool) {
        networkNameEnd.isActive = network
        memoryNameEnd.isActive = !network
        iconView.image = app.icon
        nameLabel.stringValue = app.name
        nameLabel.toolTip = app.name
        downLabel.stringValue = network ? app.downText : ""
        downLabel.textColor = .systemTeal
        upLabel.textColor = network ? .systemIndigo : .labelColor
        upLabel.stringValue = network ? app.upText : ByteCountFormatter.string(fromByteCount: Int64(app.downRate), countStyle: .memory)
    }

    /// Blanks the row instead of hiding it, so the popover height never changes
    /// as the number of active apps goes up or down.
    func configureEmpty() {
        iconView.image = nil
        nameLabel.stringValue = ""
        nameLabel.toolTip = nil
        downLabel.stringValue = ""
        upLabel.stringValue = ""
    }
}

final class PopoverViewController: NSViewController {
    private let speedHeader = SpeedHeaderView()
    private let columnHeader = ColumnHeaderView()
    private let memoryBar = UsageBar(frame: .zero)
    private let diskBar = UsageBar(frame: .zero)
    var onSortChange: ((RankOrder) -> Void)?
    private var selectedOrder: RankOrder = .total
    private let selector = NSSegmentedControl(labels: ["内存占用", "网络占用"], trackingMode: .selectOne, target: nil, action: nil)
    var onModeChange: ((Bool) -> Void)?
    private var networkMode = false
    @objc private func changeRankingMode() {
        networkMode = selector.selectedSegment == 1
        selectedOrder = .total
        columnHeader.setNetwork(networkMode)
        listState.stringValue = networkMode ? "正在采样，约 2 秒后显示" : "正在读取内存占用"
        rows.forEach { $0.configureEmpty() }
        onModeChange?(networkMode)
    }
    private var rows: [AppRowView] = []
    private var lastCount = 0
    private var lastOrderValid = true
    private let listState = NSTextField(labelWithString: "正在采样，约 2 秒后显示")
    private let cpu = NSTextField(labelWithString: "CPU   采样中…")
    private let memory = NSTextField(labelWithString: "采样中…")
    private let memoryDetail = NSTextField(labelWithString: "")
    private let disk = NSTextField(labelWithString: "采样中…")
    private let temp = NSTextField(labelWithString: "CPU 温度   不可用")
    private let login = NSButton(checkboxWithTitle: "登录时启动", target: nil, action: nil)
    private var metricsTimer: Timer?
    private var lastTemperature: TimeInterval = 0
    private var lastDisk: TimeInterval = 0
    private var previousCPU: (UInt64, UInt64)?

    @objc private func toggleLogin() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            let alert = NSAlert()
            alert.messageText = "无法更改登录启动"
            alert.informativeText = "请在系统设置的登录项中检查，或将应用放在固定位置后重试。\n\(error.localizedDescription)"
            alert.runModal()
        }
    }
    @objc private func quitApp() { NSApplication.shared.terminate(nil) }
    func beginMetrics() {
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        cpu.stringValue = "CPU   采样中…"
        rows.forEach { $0.configureEmpty() }
        listState.stringValue = networkMode ? "正在采样，约 2 秒后显示" : "正在读取内存占用"
        refreshMetrics()
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshMetrics() }
    }
    func endMetrics() { metricsTimer?.invalidate(); metricsTimer = nil; previousCPU = nil }
    private func refreshMetrics() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastTemperature >= 5 {
            lastTemperature = now
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let value = read_cpu_temperature()
                DispatchQueue.main.async {
                    self?.temp.stringValue = value.isFinite ? String(format: "CPU 温度   %.1f °C", value) : "CPU 温度   不可用"
                    self?.temp.textColor = temperatureColor(value)
                }
            }
        }
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) } }
        if rc == KERN_SUCCESS {
            let ticks = info.cpu_ticks
            let idle = UInt64(ticks.2), total = UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3) + idle
            if let old = previousCPU, total > old.0, idle >= old.1 {
                cpu.stringValue = String(format: "CPU   %.1f%%", 100 * (1 - Double(idle - old.1) / Double(total - old.0)))
            }
            previousCPU = (total, idle)
        } else { cpu.stringValue = "CPU   不可用" }
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount) } }
        if vmResult == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let resident = UInt64(vm.active_count) + UInt64(vm.inactive_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
            let reclaimable = UInt64(vm.external_page_count) + UInt64(vm.purgeable_count)
            let used = (resident > reclaimable ? resident - reclaimable : 0) * page
            let total = ProcessInfo.processInfo.physicalMemory
            var swap = xsw_usage(); var size = MemoryLayout<xsw_usage>.size
            let swapOK = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0
            memoryBar.fraction = total > 0 ? Double(used) / Double(total) : nil
            memory.stringValue = String(format: "%.1f / %.1f GB  ·  %.0f%%", Double(used)/1e9, Double(total)/1e9, Double(used)*100/Double(total))
            memoryDetail.stringValue = String(format: "压缩 %.1f GB    交换 %@", Double(vm.compressor_page_count)*Double(page)/1e9, swapOK ? String(format: "%.1f GB", Double(swap.xsu_used)/1e9) : "不可用")
        } else { memory.stringValue = "不可用"; memoryDetail.stringValue = ""; memoryBar.fraction = nil }
        if now - lastDisk >= 30 {
        lastDisk = now
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"), let free = attrs[.systemFreeSize] as? NSNumber, let total = attrs[.systemSize] as? NSNumber {
            diskBar.fraction = total.doubleValue > 0 ? 1 - free.doubleValue / total.doubleValue : nil
            disk.stringValue = String(format: "可用 %.1f / %.1f GB", free.doubleValue/1e9, total.doubleValue/1e9)
        } else { disk.stringValue = "不可用"; diskBar.fraction = nil }
        }
    }

    override func loadView() {
        view = PanelBackground(frame: NSRect(x: 0, y: 0, width: 360, height: 510))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        func pairedRow(_ left: NSView, _ right: NSView, height: CGFloat) -> NSView {
            let row = NSView(); row.translatesAutoresizingMaskIntoConstraints = false
            for child in [left, right] { child.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(child) }
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalToConstant: rowWidth), row.heightAnchor.constraint(equalToConstant: height),
                left.leadingAnchor.constraint(equalTo: row.leadingAnchor), left.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                right.trailingAnchor.constraint(equalTo: row.trailingAnchor), right.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -8)
            ])
            return row
        }
        func separator() -> NSBox {
            let line = NSBox(); line.boxType = .separator; line.translatesAutoresizingMaskIntoConstraints = false
            line.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
            return line
        }
        func label(_ title: String, size: CGFloat = 11, weight: NSFont.Weight = .medium) -> NSTextField {
            let value = NSTextField(labelWithString: title)
            value.font = .systemFont(ofSize: size, weight: weight)
            value.textColor = .labelColor
            return value
        }
        let memoryTitle = label("内存 · 估算")
        let diskTitle = label("磁盘")
        let caption = label("应用占用", size: 13, weight: .semibold)
        for value in [cpu, temp, memory, disk] { value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium) }
        memory.alignment = .right; disk.alignment = .right; temp.alignment = .right
        memoryDetail.font = .systemFont(ofSize: 10); memoryDetail.textColor = .labelColor
        listState.font = .systemFont(ofSize: 10); listState.textColor = .labelColor
        selector.selectedSegment = 0; selector.target = self; selector.action = #selector(changeRankingMode)
        selector.controlSize = .small
        columnHeader.setNetwork(false)
        columnHeader.onSort = { [weak self] order in
            guard let self = self else { return }
            self.selectedOrder = order
            self.onSortChange?(order)
        }
        memoryBar.tint = .systemBlue; diskBar.tint = .systemTeal
        rows = (0..<10).map { _ in AppRowView() }
        let processList = NSStackView(views: rows)
        processList.orientation = .vertical; processList.alignment = .leading; processList.spacing = 0
        login.target = self; login.action = #selector(toggleLogin); login.controlSize = .small
        let quit = NSButton(title: "退出", target: self, action: #selector(quitApp)); quit.controlSize = .small
        let networkSeparator = separator(), listSeparator = separator()
        let cpuRow = pairedRow(cpu, temp, height: 18)
        let memoryRow = pairedRow(memoryTitle, memory, height: 17)
        let diskRow = pairedRow(diskTitle, disk, height: 17)
        let sectionRow = pairedRow(caption, selector, height: 26)
        let footer = pairedRow(login, quit, height: 24)
        let stack = NSStackView(views: [speedHeader, networkSeparator, cpuRow, memoryRow, memoryBar, memoryDetail, diskRow, diskBar, listSeparator, sectionRow, columnHeader, listState, processList, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        stack.setCustomSpacing(10, after: speedHeader)
        stack.setCustomSpacing(9, after: networkSeparator)
        stack.setCustomSpacing(8, after: cpuRow)
        stack.setCustomSpacing(3, after: memoryRow)
        stack.setCustomSpacing(3, after: memoryBar)
        stack.setCustomSpacing(8, after: memoryDetail)
        stack.setCustomSpacing(3, after: diskRow)
        stack.setCustomSpacing(10, after: diskBar)
        stack.setCustomSpacing(6, after: listSeparator)
        stack.setCustomSpacing(2, after: sectionRow)
        stack.setCustomSpacing(0, after: columnHeader)
        stack.setCustomSpacing(3, after: listState)
        stack.setCustomSpacing(6, after: processList)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -10),
            memoryBar.widthAnchor.constraint(equalToConstant: rowWidth), memoryBar.heightAnchor.constraint(equalToConstant: 5),
            diskBar.widthAnchor.constraint(equalToConstant: rowWidth), diskBar.heightAnchor.constraint(equalToConstant: 5),
        ])
    }

    func smokeSort(_ order: RankOrder) { columnHeader.smokeSort(order) }
    func previewAppearance(_ name: NSAppearance.Name) { view.appearance = NSAppearance(named: name) }
    func savePreview(_ path: String, appearance: NSAppearance.Name) {
        view.appearance = NSAppearance(named: appearance)
        view.layoutSubtreeIfNeeded()
        func invalidate(_ item: NSView) { item.needsDisplay = true; item.subviews.forEach(invalidate) }
        invalidate(view)
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
    }
    func smokeSetNetwork(_ value: Bool) {
        selector.selectedSegment = value ? 1 : 0
        changeRankingMode()
    }
    func diagnosticText() -> String {
        return [cpu.stringValue, temp.stringValue, memory.stringValue, disk.stringValue, listState.stringValue, "rows=\(lastCount) order=\(lastOrderValid)"].joined(separator: " | ")
    }
    func updateSpeed(down: String, up: String) {
        speedHeader.update(down: down, up: up)
    }

    func showSamplingError(network: Bool) {
        listState.stringValue = network ? "网络排行读取失败，正在重试" : "内存排行读取失败，正在重试"
        rows.forEach { $0.configureEmpty() }
        lastCount = 0
    }

    func updateApps(_ apps: [AppUsage]) {
        lastCount = apps.count
        lastOrderValid = apps.map(\.pid) == sortedUsage(apps, order: selectedOrder).map(\.pid)
        listState.stringValue = apps.isEmpty ? (networkMode ? "暂无可见网络活动" : "未能读取内存数据") : (networkMode ? (selectedOrder == .download ? "按下载速度排序" : selectedOrder == .upload ? "按上传速度排序" : "按上传与下载总速率排序") : "按驻留内存排序，含辅助进程")
        for (index, row) in rows.enumerated() {
            if index < apps.count {
                row.configure(with: apps[index], network: networkMode)
            } else {
                row.configureEmpty()
            }
        }
    }
}

// MARK: - App delegate wiring NSStatusItem + menu panel

final class StatusText: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: MenuPanel!
    private var globalClickMonitor: Any?
    private var localEventMonitor: Any?
    private var panelOpen = false
    private let monitor = NetworkMonitor()
    private let popoverViewController = PopoverViewController()
    private let downStatus = StatusText(labelWithString: "--")
    private let upStatus = StatusText(labelWithString: "--")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: statusTextWidth + 4)
        if let button = statusItem.button {
            for label in [upStatus, downStatus] {
                label.font = statusFont
                label.textColor = .labelColor
                label.isSelectable = false
                button.addSubview(label)
            }
        }
        updateStatus(down: "--", up: "--")

        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        panel = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 510),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.contentViewController = popoverViewController

        popoverViewController.onSortChange = { [weak self] order in self?.monitor.selectSort(order) }
        popoverViewController.onModeChange = { [weak self] network in self?.monitor.selectNetwork(network) }
        monitor.onSpeedUpdate = { [weak self] downText, upText in
            self?.updateStatus(down: compactStatus(downText), up: compactStatus(upText))
            self?.popoverViewController.updateSpeed(down: downText, up: upText)
        }
        monitor.onAppsUpdate = { [weak self] apps in
            self?.popoverViewController.updateApps(apps)
        }
        monitor.onAppsError = { [weak self] network in
            self?.popoverViewController.showSamplingError(network: network)
        }
        monitor.start()
        if CommandLine.arguments.contains("--smoke") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self = self, let button = self.statusItem.button else { return }
                self.updateStatus(down: compactStatus("123.4 KB/s"), up: compactStatus("7.8 KB/s"))
                let topIsUpload = button.isFlipped ? self.upStatus.frame.midY < self.downStatus.frame.midY : self.upStatus.frame.midY > self.downStatus.frame.midY
                print("SMOKE status flipped=\(button.isFlipped) topUpload=\(topIsUpload) width=\(self.statusItem.length)")
                precondition(topIsUpload)
                let wide = self.statusItem.length
                self.updateStatus(down: compactStatus("1.0 KB/s"), up: compactStatus("2.0 KB/s"))
                precondition(self.statusItem.length == wide)
                precondition(self.upStatus.stringValue == "2.0K/s" && self.downStatus.stringValue == "1.0K/s")
                self.togglePopover()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.popoverViewController.previewAppearance(.darkAqua)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self = self else { return }
                print("SMOKE memory \(self.popoverViewController.diagnosticText())")
                self.popoverViewController.savePreview("build/panel-memory-dark.png", appearance: .darkAqua)
                self.popoverViewController.previewAppearance(.aqua)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self = self else { return }
                self.popoverViewController.savePreview("build/panel-memory-light.png", appearance: .aqua)
                self.popoverViewController.smokeSetNetwork(true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
                guard let self = self else { return }
                self.popoverViewController.smokeSort(.download)
                print("SMOKE download \(self.popoverViewController.diagnosticText())")
                self.popoverViewController.smokeSort(.upload)
                print("SMOKE upload \(self.popoverViewController.diagnosticText())")
                self.popoverViewController.savePreview("build/panel-light.png", appearance: .aqua)
                self.popoverViewController.savePreview("build/panel-dark.png", appearance: .darkAqua)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self = self else { return }
                print("SMOKE panel=\(self.panel.isVisible) \(self.popoverViewController.diagnosticText())")
                precondition(self.panel.isVisible && self.panelOpen)
                precondition(self.panel.animationBehavior == .none && self.panel.styleMask.contains(.borderless))
                if let screen = self.statusItem.button?.window?.screen, let rect = self.statusRect() {
                    let bounds = screen.visibleFrame
                    precondition(self.panel.frame.minX >= bounds.minX && self.panel.frame.maxX <= bounds.maxX)
                    precondition(self.panel.frame.maxY <= rect.minY)
                    print("SMOKE panel belowStatus=true onScreen=true")
                }
                if let background = self.popoverViewController.view as? NSVisualEffectView {
                    precondition(background.material == .menu && background.blendingMode == .behindWindow)
                    print("SMOKE systemMenuMaterial=true")
                } else { preconditionFailure("missing visual effect") }
                self.hidePanel()
                precondition(!self.panel.isVisible && !self.panelOpen && self.globalClickMonitor == nil && self.localEventMonitor == nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApplication.shared.terminate(nil) }
            }
        }
        if CommandLine.arguments.contains("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.togglePopover() }
        }
    }

    private func updateStatus(down: String, up: String) {
        guard let button = statusItem.button else { return }
        upStatus.stringValue = up
        downStatus.stringValue = down
        let width = statusTextWidth
        let lineHeight: CGFloat = 10
        let margin = max(0, (button.bounds.height - lineHeight * 2) / 2)
        let top = button.isFlipped ? margin : button.bounds.height - margin - lineHeight
        let bottom = button.isFlipped ? button.bounds.height - margin - lineHeight : margin
        upStatus.frame = NSRect(x: 2, y: top, width: width, height: lineHeight)
        downStatus.frame = NSRect(x: 2, y: bottom, width: width, height: lineHeight)
        button.toolTip = "上：上传  下：下载"
    }

    private func statusRect() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    @objc private func togglePopover() {
        if panelOpen { hidePanel(); return }
        guard let rect = statusRect(), let screen = statusItem.button?.window?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = panel.frame.width, height = panel.frame.height
        let x = min(max(rect.midX - width / 2, visible.minX + 6), max(visible.minX + 6, visible.maxX - width - 6))
        let top = min(rect.minY - 3, visible.maxY)
        let y = max(visible.minY + 6, top - height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panelOpen = true
        monitor.popoverOpened()
        popoverViewController.beginMetrics()
        panel.makeKeyAndOrderFront(nil)

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.panelOpen else { return }
                let location = NSEvent.mouseLocation
                if !self.panel.frame.contains(location) && !(self.statusRect()?.contains(location) ?? false) { self.hidePanel() }
            }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self = self, self.panelOpen else { return event }
            if event.type == .keyDown && event.keyCode == 53 { self.hidePanel(); return nil }
            if event.type != .keyDown && event.window !== self.panel {
                let location = NSEvent.mouseLocation
                if !(self.statusRect()?.contains(location) ?? false) { self.hidePanel() }
            }
            return event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hidePanel()
    }

    private func hidePanel() {
        guard panelOpen else { return }
        panelOpen = false
        panel.orderOut(nil)
        if let token = globalClickMonitor { NSEvent.removeMonitor(token); globalClickMonitor = nil }
        if let token = localEventMonitor { NSEvent.removeMonitor(token); localEventMonitor = nil }
        monitor.popoverClosed()
        popoverViewController.endMetrics()
    }

}

if CommandLine.arguments.contains("--runner-test") {
    let runner = SamplingCommandRunner()
    let quick = runner.run("/usr/bin/printf", arguments: ["ok"], generation: 0, timeout: 2)
    precondition(quick == "ok")
    let start = ProcessInfo.processInfo.systemUptime
    let timed = runner.run("/bin/sleep", arguments: ["30"], generation: 0)
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    precondition(timed == nil && elapsed >= 4.8 && elapsed < 8 && runner.activePID == nil)
    print("runner timeout: \(String(format: "%.2f", elapsed))s, process reaped")
    runner.advance(to: 1)
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        let result = runner.run("/bin/sleep", arguments: ["30"], generation: 1, timeout: 5)
        precondition(result == nil)
        finished.signal()
    }
    let limit = ProcessInfo.processInfo.systemUptime + 2
    while runner.activePID == nil && ProcessInfo.processInfo.systemUptime < limit { Thread.sleep(forTimeInterval: 0.01) }
    guard let child = runner.activePID else { fatalError("sampler did not start") }
    runner.advance(to: 2)
    precondition(finished.wait(timeout: .now() + 2) == .success)
    precondition(runner.activePID == nil && kill(child, 0) == -1 && errno == ESRCH)
    let stale = runner.run("/bin/sleep", arguments: ["30"], generation: 1, timeout: 5)
    precondition(stale == nil && runner.activePID == nil)
    precondition(runner.run("/usr/bin/printf", arguments: ["recovered"], generation: 2, timeout: 2) == "recovered")
    print("runner cancellation: child reaped; stale job blocked; new generation recovered")
    exit(0)
}
if CommandLine.arguments.contains("--self-test") {
    let parsed = parseNettop(",bytes_in,bytes_out,\nMicrosoft Edge Helper.123,12345,678,\ninvalid,0,0,\n")
    precondition(parsed.count == 1 && parsed[0].pid == 123 && parsed[0].bytesIn == 12345 && parsed[0].bytesOut == 678)
    precondition(formatRateTable(2048).contains("2"))
    precondition(compactStatus(" 12.3 KB/s") == "12.3K/s")
    precondition(compactStatus("  3.0 MB/s") == "3.0M/s")
    precondition(compactStatus("999.4 KB/s") == "999K/s")
    precondition(compactStatus("999.9 KB/s") == "1.0M/s")
    for example in ["0.0 KB/s", "99.9 KB/s", "999.4 KB/s", "999.9 KB/s", "999.9 MB/s", "999999999 GB/s"] {
        let result = compactStatus(example)
        precondition((result as NSString).size(withAttributes: [.font: statusFont]).width <= statusTextWidth)
    }
    let sample = [AppUsage(pid: 1, name: "A", icon: nil, downRate: 100, upRate: 2), AppUsage(pid: 2, name: "B", icon: nil, downRate: 3, upRate: 200), AppUsage(pid: 3, name: "C", icon: nil, downRate: 20, upRate: 20)]
    precondition(sortedUsage(sample, order: .download).map(\.pid) == [1,3,2])
    precondition(sortedUsage(sample, order: .upload).map(\.pid) == [2,3,1])
    precondition(temperatureColor(59.9) == .systemBlue && temperatureColor(60) == .systemOrange && temperatureColor(80) == .systemRed)
    let selfTestRunner = SamplingCommandRunner()
    let processes = memorySnapshot(using: selfTestRunner, generation: 0) ?? []
    precondition(!processes.isEmpty && processes.allSatisfy { $0.down > 0 })
    print("memory processes: \(processes.count)")
    let temp = read_cpu_temperature()
    print("network interfaces: \(currentNetworkBytes().count); CPU temperature: \(temp.isFinite ? String(format: "%.1f", temp) : "unavailable") °C; parser: OK")
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
