// Codex Desktop HUD — independent, window-bounded companion; no injection.
import AppKit
import CoreGraphics
import Foundation

private enum Palette {
    static let background = NSColor(white: 0.135, alpha: 1)
    static let hover = NSColor(white: 0.16, alpha: 1)
    static let border = NSColor(white: 0.26, alpha: 1)
    static let text = NSColor(white: 0.94, alpha: 1)
    static let muted = NSColor(white: 0.67, alpha: 1)
    static let green = NSColor(calibratedRed: 0.58, green: 0.83, blue: 0.70, alpha: 1)
    static let yellow = NSColor(calibratedRed: 0.95, green: 0.76, blue: 0.48, alpha: 1)
    static let red = NSColor(calibratedRed: 0.98, green: 0.54, blue: 0.52, alpha: 1)

    static func quota(_ value: Int?) -> NSColor {
        guard let value = value else { return muted }
        return value > 50 ? green : value > 20 ? yellow : red
    }
}

struct HUDPresentation: Equatable {
    var source: String
    var fiveHour: Int?
    var weekly: Int?
    var context: Int?
    var turns: String
    var steps: String
    var cache: String
    var plan: String
    var expanded: Bool
    var resetLabel: String? = nil
}

final class HUDView: NSView {
    private var presentation = HUDPresentation(source: "读取中", fiveHour: nil, weekly: nil, context: nil,
                                               turns: "—", steps: "—", cache: "—", plan: "—", expanded: false)
    private var tracking: NSTrackingArea?
    private var hovered = false
    var onDrag: ((CGPoint) -> Void)?
    var onClick: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    private var startMouse = CGPoint.zero
    private var startOrigin = CGPoint.zero
    private var moved = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 11
        setAccessibilityLabel("Codex 用量，点击展开，拖动移动，右键设置")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ value: HUDPresentation, tooltip: String) {
        guard value != presentation || toolTip != tooltip else { return }
        presentation = value
        toolTip = tooltip
        setAccessibilityValue(tooltip)
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    static func resetWidth(_ label: String?) -> CGFloat {
        guard let label = label else { return 0 }
        return ceil((label as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)]).width)
    }
    static func preferredWidth(resetLabel: String?) -> CGFloat {
        380 + (resetLabel == nil ? 0 : resetWidth(resetLabel) + 4)
    }
    static func headerHeight(width: CGFloat, resetLabel: String?) -> CGFloat {
        resetLabel != nil && width < preferredWidth(resetLabel: resetLabel) ? 50 : 36
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10.5, yRadius: 10.5)
        (hovered ? Palette.hover : Palette.background).setFill()
        outline.fill()
        Palette.border.setStroke()
        outline.lineWidth = 1
        outline.stroke()
        let hasReset = presentation.resetLabel != nil
        let inlineReset = hasReset && bounds.width >= Self.preferredWidth(resetLabel: presentation.resetLabel)
        let shift: CGFloat = inlineReset ? Self.resetWidth(presentation.resetLabel) + 4 : 0
        let top = bounds.height - Self.headerHeight(width: bounds.width, resetLabel: presentation.resetLabel)
        let row = bounds.height - 36
        func text(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat = 11,
                  color: NSColor = Palette.text, weight: NSFont.Weight = .medium, digits: Bool = false) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
            (value as NSString).draw(in: CGRect(x: x, y: y, width: width, height: size + 5), withAttributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        }
        // A quiet grip and a persistent source badge keep interaction and provenance visible.
        Palette.muted.withAlphaComponent(hovered ? 0.9 : 0.5).setFill()
        for x: CGFloat in [13, 17] {
            for y: CGFloat in [14, 18, 22] {
                NSBezierPath(ovalIn: CGRect(x: x, y: row + y, width: 1.6, height: 1.6)).fill()
            }
        }
        NSColor(white: 1, alpha: 0.055).setFill()
        NSBezierPath(roundedRect: CGRect(x: 27, y: row + 8, width: 39, height: 21), xRadius: 5, yRadius: 5).fill()
        text(presentation.source, x: 32, y: row + 10, width: 33, size: 10,
             color: presentation.source == "失效" ? Palette.yellow : Palette.muted)
        Palette.border.setFill()
        NSRect(x: 76, y: row + 11, width: 1, height: 15).fill()
        func percent(_ value: Int?) -> String { value.map { "\($0)%" } ?? "—" }
        text("5h", x: 88, y: row + 11, width: 19, color: Palette.muted)
        text(percent(presentation.fiveHour), x: 108, y: row + 9.5, width: 43, size: 13,
             color: Palette.quota(presentation.fiveHour), weight: .semibold, digits: true)
        if let reset = presentation.resetLabel {
            text(reset, x: inlineReset ? 154 : 88, y: inlineReset ? row + 11 : top + 1,
                 width: Self.resetWidth(reset) + 1, size: 10, color: Palette.muted, digits: true)
        }
        text("周", x: 165 + shift, y: row + 11, width: 17, color: Palette.muted)
        text(percent(presentation.weekly), x: 184 + shift, y: row + 9.5, width: 49, size: 13,
             color: Palette.quota(presentation.weekly), weight: .semibold, digits: true)
        text("上下文", x: 237 + shift, y: row + 11, width: 38, color: Palette.muted)
        let context = presentation.context.map { "≈\($0)%" } ?? "—"
        text(context, x: 279 + shift, y: row + 9.5, width: 64, size: 13, weight: .semibold, digits: true)
        let chevron = NSBezierPath()
        let cy = row + 18
        let direction: CGFloat = presentation.expanded ? -1 : 1
        chevron.move(to: CGPoint(x: bounds.width - 23, y: cy + direction * 2))
        chevron.line(to: CGPoint(x: bounds.width - 19, y: cy - direction * 2))
        chevron.line(to: CGPoint(x: bounds.width - 15, y: cy + direction * 2))
        chevron.lineWidth = 1.3
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        Palette.muted.setStroke()
        chevron.stroke()

        if presentation.expanded {
            Palette.border.setFill()
            NSRect(x: 16, y: top, width: bounds.width - 32, height: 0.5).fill()
            let column = (bounds.width - 32) / 4
            for (index, pair) in [("轮数", presentation.turns), ("工具步数", presentation.steps),
                                  ("累计缓存", presentation.cache), ("订阅", presentation.plan)].enumerated() {
                let x = 17 + CGFloat(index) * column
                text(pair.1, x: x, y: 28, width: column - 9, size: 15, weight: .semibold, digits: true)
                text(pair.0, x: x, y: 12, width: column - 9, size: 10, color: Palette.muted)
            }
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onMenu?(event); return }
        startMouse = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        moved = false
    }
    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        let delta = CGPoint(x: p.x - startMouse.x, y: p.y - startMouse.y)
        if abs(delta.x) + abs(delta.y) > 3 { moved = true }
        if moved { onDrag?(CGPoint(x: startOrigin.x + delta.x, y: startOrigin.y + delta.y)) }
    }
    override func mouseUp(with event: NSEvent) { if !moved { onClick?() } }
    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }
}

final class Controller: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var bar: HUDView!
    private var snapshot: [String: Any] = [:]
    private var snapshotBusy = false
    private var quotaBusy = false
    private var lastQuotaTime: Date = .distantPast
    private let defaultsKey = "codexHUD.planOverride"
    private let defaults = UserDefaults.standard
    private var host: CGRect?
    private var windowTitle = ""
    private var sessions: [[String: Any]] = []
    private var lastSessionList = Date.distantPast
    private var selectionGeneration = 0
    private var expanded = false
    private var ownerPID: pid_t?
    private var timer: Timer?

    private var position: CGPoint? {
        guard defaults.object(forKey: "positionX") != nil else { return nil }
        return CGPoint(x: defaults.double(forKey: "positionX"), y: defaults.double(forKey: "positionY"))
    }
    private var threadID: String? { defaults.string(forKey: "threadID") }
    private func selectedPlan() -> String { defaults.string(forKey: defaultsKey) ?? "auto" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 36),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        bar = HUDView(frame: panel.contentView!.bounds)
        bar.autoresizingMask = [.width, .height]
        panel.contentView = bar
        bar.onDrag = { [weak self] origin in self?.drag(to: origin) }
        bar.onClick = { [weak self] in self?.toggleExpanded() }
        bar.onMenu = { [weak self] event in self?.showMenu(event) }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(self, selector: #selector(workspaceChanged(_:)), name: name, object: nil)
        }
        tick()
        refreshQuota()
        refreshSession()
        timer = Timer(timeInterval: 0.15, target: self, selector: #selector(followWindow), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
        _ = Timer.scheduledTimer(timeInterval: 2.5, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    }

    @objc private func workspaceChanged(_ notification: Notification) {
        if notification.name == NSWorkspace.didTerminateApplicationNotification,
           let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           (app.processIdentifier == ownerPID || app.bundleIdentifier == "com.openai.codex") { NSApp.terminate(nil); return }
        followWindow()
    }

    @objc private func followWindow() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == "com.openai.codex" || front.localizedName?.lowercased() == "codex",
              !front.isHidden,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            panel.orderOut(nil); return
        }
        ownerPID = front.processIdentifier
        var found: CGRect?
        var title = ""
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == front.processIdentifier,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 420, rect.height > 260 else { continue }
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            found = CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
            title = info[kCGWindowName as String] as? String ?? ""
            break
        }
        guard let found = found else { panel.orderOut(nil); host = nil; return }
        host = found
        if windowTitle != title {
            windowTitle = title
            if threadID == nil { invalidateSelection() }
        }
        place()
        panel.orderFrontRegardless()
    }

    private func place() {
        guard let host = host else { return }
        let reset = resetLabel()
        let preferredWidth = HUDView.preferredWidth(resetLabel: reset)
        let actualWidth = min(preferredWidth, host.width - 16)
        let height = HUDView.headerHeight(width: actualWidth, resetLabel: reset) + (expanded ? 60 : 0)
        let frame = HUDGeometry.frame(host: host, width: preferredWidth, height: height, position: position)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        render(width: frame.width)
    }
    private func drag(to origin: CGPoint) {
        // Recheck visibility before each drag; never leave the host bounds.
        followWindow()
        guard panel.isVisible, let host = host else { return }
        let pos = HUDGeometry.position(origin: origin, host: host, size: panel.frame.size)
        defaults.set(pos.x, forKey: "positionX")
        defaults.set(pos.y, forKey: "positionY")
        place()
    }
    @objc private func toggleExpanded() { expanded.toggle(); place() }
    @objc private func resetPosition() {
        defaults.removeObject(forKey: "positionX")
        defaults.removeObject(forKey: "positionY")
        expanded = false
        place()
    }
    @objc private func changePlan(_ sender: NSMenuItem) {
        defaults.set(sender.representedObject as? String, forKey: defaultsKey)
        place()
    }
    @objc private func bindSession(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { defaults.set(id, forKey: "threadID") }
        else { defaults.removeObject(forKey: "threadID") }
        invalidateSelection()
        refreshSession()
    }
    private func invalidateSelection() {
        selectionGeneration += 1
        snapshot = [:]
        render(width: panel.frame.width)
    }
    @objc private func forceRefresh() { lastQuotaTime = .distantPast; refreshQuota() }
    @objc private func quitHUD() { NSApp.terminate(nil) }

    private func showMenu(_ event: NSEvent) {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add(expanded ? "收起指标" : "展开全部指标", #selector(toggleExpanded))
        add("恢复右上角位置", #selector(resetPosition))
        add("立即刷新额度", #selector(forceRefresh))
        let binding = NSMenu()
        let automatic = NSMenuItem(title: "自动匹配（无法识别时显示最近活动）", action: #selector(bindSession(_:)), keyEquivalent: "")
        automatic.target = self
        automatic.state = threadID == nil ? .on : .off
        binding.addItem(automatic)
        for session in sessions.prefix(30) {
            guard let id = session["id"] as? String else { continue }
            let item = NSMenuItem(title: String((session["title"] as? String ?? id).prefix(55)), action: #selector(bindSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = threadID == id ? .on : .off
            binding.addItem(item)
        }
        let parent = NSMenuItem(title: "绑定聊天", action: nil, keyEquivalent: "")
        menu.addItem(parent)
        menu.setSubmenu(binding, for: parent)
        let plans = NSMenu()
        for value in ["auto", "Plus", "Pro x5", "Pro x10"] {
            let item = NSMenuItem(title: value == "auto" ? "自动识别" : value, action: #selector(changePlan(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = selectedPlan() == value ? .on : .off
            plans.addItem(item)
        }
        let planParent = NSMenuItem(title: "订阅标签", action: nil, keyEquivalent: "")
        menu.addItem(planParent)
        menu.setSubmenu(plans, for: planParent)
        let source = snapshot["source"] as? String ?? "读取中"
        let status = NSMenuItem(title: "会话来源：\(source)", action: nil, keyEquivalent: "")
        menu.addItem(status)
        menu.addItem(NSMenuItem(title: "上下文为日志估算，非实时精确值", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        add("退出 HUD", #selector(quitHUD))
        NSMenu.popUpContextMenu(menu, with: event, for: bar)
    }
    private func collectorURL() -> URL {
        Bundle.main.resourceURL!.appendingPathComponent("tracker.py")
    }
    private func worker(_ arguments: [String], completion: @escaping ([String: Any]?) -> Void) {
        let url = collectorURL()
        var environment = ProcessInfo.processInfo.environment
        if environment["CODEX_HUD_BINARY"] == nil,
           let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            let binary = bundle.appendingPathComponent("Contents/Resources/codex").path
            if FileManager.default.isExecutableFile(atPath: binary) { environment["CODEX_HUD_BINARY"] = binary }
        }
        if environment["CODEX_HUD_BINARY"] == nil,
           let path = try? String(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("codex-path"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           FileManager.default.isExecutableFile(atPath: path) { environment["CODEX_HUD_BINARY"] = path }
        let python = (try? String(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("python-path"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "python3"
        let workerEnvironment = environment
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.environment = workerEnvironment
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [python, url.path] + arguments
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            var result: [String: Any]? = nil
            do {
                try p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                }
            } catch {
                NSLog("HUD collector error: %@", error.localizedDescription)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }


    private func refreshSession() {
        guard !snapshotBusy else { return }
        snapshotBusy = true
        let generation = selectionGeneration
        var args: [String] = []
        if let id = threadID { args = ["--thread-id", id] }
        else if !windowTitle.isEmpty { args = ["--window-title", windowTitle] }
        worker(args) { [weak self] result in
            guard let self = self else { return }
            self.snapshotBusy = false
            if generation != self.selectionGeneration { self.refreshSession(); return }
            self.snapshot = result ?? [:]
            self.render(width: self.panel.frame.width)
        }
    }
    private func refreshQuota() {
        guard !quotaBusy else { return }
        quotaBusy = true
        lastQuotaTime = Date()
        worker(["--quota"]) { [weak self] _ in
            guard let self = self else { return }
            self.quotaBusy = false
            self.refreshSession()
        }
    }
    @objc private func tick() {
        followWindow()
        refreshSession()
        if Date().timeIntervalSince(lastQuotaTime) >= 90 { refreshQuota() }
        if Date().timeIntervalSince(lastSessionList) >= 30 {
            lastSessionList = Date()
            worker(["--sessions"]) { [weak self] result in self?.sessions = result?["sessions"] as? [[String: Any]] ?? [] }
        }
    }
    private func value(_ key: String) -> Int? {
        if let n = snapshot[key] as? NSNumber { return n.intValue }
        return nil
    }
    private func plain(_ key: String) -> String {
        if let n = value(key) { return String(n) }
        return "--"
    }
    private func prettyPlan() -> String {
        let override = selectedPlan()
        if override != "auto" { return override }
        guard let raw = snapshot["plan"] as? String else { return "套餐 --" }
        switch raw.lowercased() {
            case "plus": return "Plus"
            case "pro": return "Pro"
            case "free": return "Free"
            case "team": return "Team"
            case "business": return "Business"
            case "enterprise": return "Enterprise"
            default: return raw.capitalized
        }
    }
    private func resetLabel() -> String? {
        HUDTime.resetLabel(timestamp: (snapshot["five_hour_resets_at"] as? NSNumber)?.doubleValue)
    }
    private func render(width: CGFloat) {
        guard bar != nil else { return }
        let source = snapshot["source"] as? String ?? ""
        let label: String
        switch source {
        case "bound-session": label = "锁定"
        case "window-title": label = "当前"
        case "binding-unavailable": label = "失效"
        case "": label = "读取中"
        default: label = "最近"
        }
        let presentation = HUDPresentation(source: label, fiveHour: value("five_hour"), weekly: value("weekly"),
                                           context: value("context_percent"), turns: plain("turns"), steps: plain("steps"),
                                           cache: value("cache_percent").map { "\($0)%" } ?? "—", plan: prettyPlan(), expanded: expanded, resetLabel: resetLabel())
        let tooltip = "第 \(plain("turns")) 轮 · \(plain("steps")) 工具步 · 上下文 ≈\(plain("context_percent"))% · 累计缓存 \(plain("cache_percent"))% · \(prettyPlan())\n5h 剩余 \(plain("five_hour"))% · \(resetLabel() ?? "重置时间不可用") · 周剩余 \(plain("weekly"))%\n拖动调整位置 · 点击展开/收起 · 右键设置\n会话：\(label)（\(source)）｜额度：\(snapshot["quota_source"] ?? "--")"
        bar.update(presentation, tooltip: tooltip)
    }

}

@main
struct HUDApplication {
    static func main() {
        let app = NSApplication.shared
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
            renderPreview(at: CommandLine.arguments[index + 1])
            return
        }
        let controller = Controller()
        app.delegate = controller
        app.run()
        withExtendedLifetime(controller) {}
    }
}

// Render only this app's own views with explicit sample data; never capture the host.
private func renderPreview(at path: String) {
    let directory = URL(fileURLWithPath: path)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, expanded, five, week, context) in [("compact", false, 77, 96, 7), ("expanded", true, 77, 96, 7), ("low-quota", false, 12, 38, 89), ("narrow", false, 77, 96, 7)] {
        let size = NSSize(width: name == "narrow" ? 414 : HUDView.preferredWidth(resetLabel: "14:30 重置"), height: name == "narrow" ? 50 : expanded ? 96 : 36)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        let view = HUDView(frame: NSRect(origin: .zero, size: size))
        window.contentView = view
        view.update(HUDPresentation(source: "预览", fiveHour: five, weekly: week, context: context,
                                    turns: "35", steps: "1,203", cache: "99%", plan: "Plus", expanded: expanded, resetLabel: "14:30 重置"), tooltip: "示例数据")
        window.layoutIfNeeded()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
