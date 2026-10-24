import Cocoa
import Carbon
import ServiceManagement

// MARK: - 持久化键
enum Keys {
    static let masterOn = "appdim.masterOn"
    static let dimLevel = "appdim.dimLevel"
    static let enabled = "appdim.enabledBundles"
    static let hkKeyCode = "appdim.hkKeyCode"
    static let hkModifiers = "appdim.hkModifiers"
    static let refreshInterval = "appdim.refreshInterval"
    static let cornerRadius = "appdim.cornerRadius"
    static let dimByBundle = "appdim.dimByBundle"
}

// Carbon 修饰键常量
private let kCmd: UInt32 = 256      // cmdKey
private let kShift: UInt32 = 512    // shiftKey
private let kOpt: UInt32 = 2048     // optionKey
private let kCtrl: UInt32 = 4096   // controlKey
// 默认 ⇧⌘D（keyCode 2 = ANSI D）
private let defaultKeyCode: UInt32 = 2
private let defaultModifiers: UInt32 = kCmd | kShift

// 圆角遮罩视图：只在圆角矩形内填黑，矩形四角保持透明，贴合目标窗口圆角
final class RoundedMaskView: NSView {
    var cornerRadius: CGFloat = 10 {
        didSet { needsDisplay = true }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let r = min(cornerRadius, bounds.width / 4, bounds.height / 4)
        let path = NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r)
        NSColor.black.setFill()
        path.fill()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    // bundleID -> 遮罩窗口
    var overlays: [String: NSWindow] = [:]
    // 每个 App 暗度滑杆 -> bundleID 的临时映射
    var sliderOwner: [ObjectIdentifier: String] = [:]

    var masterOn: Bool {
        get { UserDefaults.standard.object(forKey: Keys.masterOn) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.masterOn) }
    }

    var dimLevel: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: Keys.dimLevel)
            return v > 0 ? CGFloat(v) : 0.35
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: Keys.dimLevel) }
    }

    /// 遮罩跟随同步间隔（秒），默认 0.15；值越小跟随越跟手、CPU 略高
    var refreshInterval: Double {
        get {
            let v = UserDefaults.standard.double(forKey: Keys.refreshInterval)
            return v > 0 ? v : 0.15
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.refreshInterval) }
    }

    /// 遮罩圆角半径（pt），默认 10；0 为直角，可在菜单滑杆调节
    var cornerRadius: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: Keys.cornerRadius)
            return v >= 0 ? CGFloat(v) : 10
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: Keys.cornerRadius) }
    }

    /// 每个 App 单独的暗度（bundleID -> 0.01~0.99），未设置则用全局 dimLevel
    var dimByBundle: [String: CGFloat] {
        get {
            guard let d = UserDefaults.standard.dictionary(forKey: Keys.dimByBundle) as? [String: Double] else { return [:] }
            return d.mapValues { CGFloat($0) }
        }
        set { UserDefaults.standard.set(newValue.mapValues { Double($0) }, forKey: Keys.dimByBundle) }
    }

    /// 取某 App 的有效暗度：自定义优先，否则全局默认
    func effectiveDim(_ bid: String) -> CGFloat {
        dimByBundle[bid] ?? dimLevel
    }

    /// 已勾选变暗的 App（bundleID 集合），持久化
    var enabledBundles: Set<String> {
        get {
            let arr = UserDefaults.standard.stringArray(forKey: Keys.enabled)
                ?? ["com.tencent.xinWeChat", "com.xingin.discover"]
            return Set(arr)
        }
        set { UserDefaults.standard.set(Array(newValue), forKey: Keys.enabled) }
    }

    // MARK: - 全局快捷键
    var hotKeyRef: EventHotKeyRef?
    var hotKeyHandler: EventHandlerRef?
    var recordMonitor: Any?
    var recording = false

    var hkKeyCode: UInt32 {
        get { UInt32(UserDefaults.standard.integer(forKey: Keys.hkKeyCode)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: Keys.hkKeyCode) }
    }
    var hkModifiers: UInt32 {
        get {
            let v = UInt32(UserDefaults.standard.integer(forKey: Keys.hkModifiers))
            return v == 0 ? defaultModifiers : v
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: Keys.hkModifiers) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        Self.hotkeyTriggered = { [weak self] in
            DispatchQueue.main.async {
                self?.hkLog("hotkey fired -> toggle")
                self?.toggleMaster(nil)
            }
        }
        installHotkeyHandler()
        registerHotkey()
        restartTimer()
        update()
    }

    /// 按当前刷新间隔重建跟随定时器
    private func restartTimer() {
        timer?.invalidate()
        let iv = refreshInterval
        timer = Timer.scheduledTimer(withTimeInterval: iv, repeats: true) { [weak self] _ in
            self?.update()
        }
        timer?.tolerance = iv * 0.2
    }

    // MARK: - 遮罩窗口工厂：普通层级，插到目标窗口正上方
    private func makeOverlay() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        w.backgroundColor = .clear
        let mask = RoundedMaskView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        mask.autoresizingMask = [.width, .height]
        w.contentView = mask
        w.isOpaque = false
        w.ignoresMouseEvents = true          // 点击穿透，不拦截操作
        w.level = .normal
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.alphaValue = dimLevel
        return w
    }

    // MARK: - 菜单栏
    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        updateStatusIcon()
        rebuildMenu()
    }

    /// 总开/关对应的两个菜单栏图标（模板图，自动适配浅色/深色菜单栏）
    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let primary = masterOn ? "rectangle.lefthalf.filled" : "rectangle"
        let fallback = masterOn ? "circle.lefthalf.filled" : "circle"
        let img = NSImage(systemSymbolName: primary, accessibilityDescription: "AppDim")
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: "AppDim")
        img?.isTemplate = true
        button.image = img
        button.toolTip = masterOn ? "AppDim：窗口变暗已启用" : "AppDim：窗口变暗已关闭"
    }

    /// 每次打开菜单时重建，刷新正在运行的 App 列表与勾选态
    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        // 总开关
        let master = NSMenuItem(
            title: "启用窗口变暗",
            action: #selector(toggleMaster(_:)),
            keyEquivalent: ""
        )
        master.target = self
        master.state = masterOn ? .on : .off
        menu.addItem(master)
        menu.addItem(.separator())

        // 正在运行的 App，勾选即常驻变暗
        let header = NSMenuItem(title: "运行中的 App（勾选变暗）", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.bundleIdentifier != nil && $0.bundleIdentifier != "local.appdim" }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        for app in apps {
            guard let bid = app.bundleIdentifier else { continue }
            let item = NSMenuItem(
                title: app.localizedName ?? bid,
                action: #selector(toggleApp(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = bid
            item.state = enabledBundles.contains(bid) ? .on : .off
            item.submenu = perAppDimMenu(bid: bid)
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // 暗度滑杆：包一层容器，保证水平居中、不歪斜；范围 1%–99%
        let slider = NSSlider(frame: NSRect(x: 14, y: 6, width: 212, height: 18))
        slider.minValue = 1
        slider.maxValue = 99
        slider.doubleValue = Double((dimLevel * 100).rounded())
        slider.target = self
        slider.action = #selector(dimChanged(_:))
        slider.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        let sliderWrap = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        sliderWrap.addSubview(slider)
        let sliderItem = NSMenuItem()
        sliderItem.view = sliderWrap
        menu.addItem(sliderItem)

        let label = NSMenuItem(
            title: "暗度 \(Int((dimLevel * 100).rounded()))%（1%–99%）",
            action: nil,
            keyEquivalent: ""
        )
        label.isEnabled = false
        menu.addItem(label)
        menu.addItem(.separator())

        // 跟随刷新率（同步间隔）子菜单
        let refreshParent = NSMenuItem(title: "跟随刷新率", action: nil, keyEquivalent: "")
        let refreshSub = NSMenu()
        let refreshOptions: [(Double, String)] = [
            (0.05, "0.05s（20 次/秒，最跟手）"),
            (0.10, "0.10s（10 次/秒）"),
            (0.15, "0.15s（默认，7 次/秒）"),
            (0.25, "0.25s（4 次/秒，省电）"),
            (0.50, "0.50s（2 次/秒，最省）")
        ]
        for (iv, title) in refreshOptions {
            let it = NSMenuItem(title: title, action: #selector(selectRefresh(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = iv
            it.state = abs(refreshInterval - iv) < 0.001 ? .on : .off
            refreshSub.addItem(it)
        }
        refreshParent.submenu = refreshSub
        menu.addItem(refreshParent)
        menu.addItem(.separator())

        // 圆角半径滑杆：0 直角，最大 20pt，默认 10
        let cornerSlider = NSSlider(frame: NSRect(x: 14, y: 6, width: 212, height: 18))
        cornerSlider.minValue = 0
        cornerSlider.maxValue = 20
        cornerSlider.doubleValue = Double(cornerRadius)
        cornerSlider.target = self
        cornerSlider.action = #selector(cornerChanged(_:))
        cornerSlider.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        let cornerWrap = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        cornerWrap.addSubview(cornerSlider)
        let cornerSliderItem = NSMenuItem()
        cornerSliderItem.view = cornerWrap
        menu.addItem(cornerSliderItem)

        let cornerLabel = NSMenuItem(
            title: "圆角 \(Int(cornerRadius.rounded()))pt（0–20，默认 10）",
            action: nil,
            keyEquivalent: ""
        )
        cornerLabel.isEnabled = false
        menu.addItem(cornerLabel)
        menu.addItem(.separator())

        // 全局快捷键（默认 ⇧⌘D，可录制自定义）
        let hkHeader = NSMenuItem(title: "全局快捷键（开关变暗总览）", action: nil, keyEquivalent: "")
        hkHeader.isEnabled = false
        menu.addItem(hkHeader)

        let rec = NSMenuItem(
            title: recording ? "请按下新的组合键…（Esc 取消）" : "录制快捷键：\(hotkeyDisplay())",
            action: #selector(recordHotkey(_:)),
            keyEquivalent: ""
        )
        rec.target = self
        menu.addItem(rec)

        let reset = NSMenuItem(
            title: "恢复默认 ⇧⌘D",
            action: #selector(resetHotkey(_:)),
            keyEquivalent: ""
        )
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())

        // 开机自启
        let login = NSMenuItem(
            title: "开机自动启动",
            action: #selector(toggleLogin(_:)),
            keyEquivalent: ""
        )
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "退出 AppDim",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - 动作
    @objc private func toggleMaster(_ sender: NSMenuItem?) {
        masterOn = !masterOn
        if let s = sender { s.state = masterOn ? .on : .off }
        // 同步菜单里的总开关勾选态
        if let menu = statusItem.menu {
            for item in menu.items where item.title == "启用窗口变暗" {
                item.state = masterOn ? .on : .off
            }
        }
        update()
    }

    // MARK: - 全局快捷键（Carbon RegisterEventHotKey，无需辅助功能/输入监控权限）
    private func hkLog(_ s: String) {
        let line = "\(Date()): \(s)\n"
        if let fh = fopen("/tmp/appdim-hotkey.log", "a") {
            fputs(line, fh); fclose(fh)
        }
    }

    private func installHotkeyHandler() {
        let spec = [EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )]
        let target = GetEventDispatcherTarget()
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            target,
            { _, _, _ in
                AppDelegate.hotkeyTriggered?()
                return noErr
            },
            spec.count, spec, nil, &handler
        )
        hotKeyHandler = handler
        hkLog("installHandler status=\(status)")
    }

    static var hotkeyTriggered: (() -> Void)?

    private func registerHotkey() {
        if let r = hotKeyRef {
            UnregisterEventHotKey(r)
            hotKeyRef = nil
        }
        let key = hkKeyCode == 0 ? defaultKeyCode : hkKeyCode
        let hid = EventHotKeyID(signature: OSType(0x4144494D), id: 1) // 'ADIM'
        let status = RegisterEventHotKey(
            key,
            hkModifiers,
            hid,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        hkLog("register key=\(key) mods=\(hkModifiers) status=\(status) ref=\(hotKeyRef != nil ? "y" : "n")")
    }

    // MARK: - 快捷键录制
    @objc private func recordHotkey(_ sender: NSMenuItem) {
        recording = true
        NSApp.activate(ignoringOtherApps: true)
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Esc 取消
                self.finishRecording()
                return nil
            }
            let flags = event.modifierFlags
            var carbon: UInt32 = 0
            if flags.contains(.control) { carbon |= kCtrl }
            if flags.contains(.option) { carbon |= kOpt }
            if flags.contains(.shift) { carbon |= kShift }
            if flags.contains(.command) { carbon |= kCmd }
            // 至少带一个修饰键，避免和普通打字冲突
            guard carbon != 0 else { return nil }
            self.hkKeyCode = UInt32(event.keyCode)
            self.hkModifiers = carbon
            self.finishRecording()
            return nil
        }
        sender.title = "⌨️ 请按下新的组合键…（Esc 取消）"
    }

    @objc private func resetHotkey(_ sender: NSMenuItem) {
        hkKeyCode = defaultKeyCode
        hkModifiers = defaultModifiers
        finishRecording()
    }

    private func finishRecording() {
        recording = false
        if let m = recordMonitor { NSEvent.removeMonitor(m) }
        recordMonitor = nil
        registerHotkey()
        rebuildMenu()
    }

    /// 把当前快捷键格式化成菜单显示文本
    private func hotkeyDisplay() -> String {
        var parts: [String] = []
        if hkModifiers & kCtrl != 0 { parts.append("⌃") }
        if hkModifiers & kOpt != 0 { parts.append("⌥") }
        if hkModifiers & kShift != 0 { parts.append("⇧") }
        if hkModifiers & kCmd != 0 { parts.append("⌘") }
        parts.append(Self.keyLabel(hkKeyCode == 0 ? defaultKeyCode : hkKeyCode))
        return parts.joined()
    }

    private static func keyLabel(_ code: UInt32) -> String {
        let map: [UInt32: String] = [
            0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",10:"B",
            11:"Q",12:"W",13:"E",14:"R",15:"T",16:"Y",32:"U",34:"I",35:"O",36:"P",
            37:"L",38:"J",40:"K",45:"N",46:"M",
            18:"1",19:"2",20:"3",21:"4",22:"5",23:"6",24:"7",25:"8",26:"9",29:"0"
        ]
        return map[code] ?? "键\(code)"
    }

    @objc private func toggleApp(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        var set = enabledBundles
        if set.contains(bid) { set.remove(bid) } else { set.insert(bid) }
        enabledBundles = set
        sender.state = set.contains(bid) ? .on : .off
        update()
    }

    @objc private func dimChanged(_ sender: NSSlider) {
        let v = min(99.0, max(1.0, sender.doubleValue))
        dimLevel = CGFloat(v / 100.0)
        sender.doubleValue = v
        for (bid, w) in overlays { w.alphaValue = effectiveDim(bid) }
        if let menu = statusItem.menu {
            for item in menu.items where item.title.hasPrefix("暗度 ") {
                item.title = "暗度 \(Int(v.rounded()))%（1%–99%）"
            }
        }
    }

    /// 单个 App 的暗度子菜单：滑杆 + 当前值 + 恢复默认
    private func perAppDimMenu(bid: String) -> NSMenu {
        let sub = NSMenu()
        let s = NSSlider(frame: NSRect(x: 14, y: 6, width: 212, height: 18))
        s.minValue = 1
        s.maxValue = 99
        s.doubleValue = Double((effectiveDim(bid) * 100).rounded())
        s.target = self
        s.action = #selector(perAppDimChanged(_:))
        sliderOwner[ObjectIdentifier(s)] = bid
        s.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        let wrap = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        wrap.addSubview(s)
        let sliderItem = NSMenuItem()
        sliderItem.view = wrap
        sub.addItem(sliderItem)

        let custom = dimByBundle[bid] != nil
        let label = NSMenuItem(
            title: "当前 \(Int((effectiveDim(bid) * 100).rounded()))%\(custom ? "" : "（跟随全局默认）")",
            action: nil,
            keyEquivalent: ""
        )
        label.isEnabled = false
        sub.addItem(label)

        let reset = NSMenuItem(title: "恢复跟随全局默认", action: #selector(resetAppDim(_:)), keyEquivalent: "")
        reset.target = self
        reset.representedObject = bid
        sub.addItem(reset)
        return sub
    }

    @objc private func perAppDimChanged(_ sender: NSSlider) {
        let v = min(99.0, max(1.0, sender.doubleValue))
        sender.doubleValue = v
        guard let bid = sliderOwner[ObjectIdentifier(sender)] else { return }
        var d = dimByBundle
        d[bid] = CGFloat(v / 100.0)
        dimByBundle = d
        if let w = overlays[bid] { w.alphaValue = effectiveDim(bid) }
    }

    @objc private func resetAppDim(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        var d = dimByBundle
        d.removeValue(forKey: bid)
        dimByBundle = d
        if let w = overlays[bid] { w.alphaValue = effectiveDim(bid) }
        rebuildMenu()
    }

    @objc private func selectRefresh(_ sender: NSMenuItem) {
        guard let iv = sender.representedObject as? Double else { return }
        refreshInterval = iv
        restartTimer()
        rebuildMenu()
    }

    @objc private func cornerChanged(_ sender: NSSlider) {
        let v = min(20.0, max(0.0, sender.doubleValue))
        cornerRadius = CGFloat(v)
        sender.doubleValue = v
        for (_, w) in overlays {
            if let mask = w.contentView as? RoundedMaskView {
                // 全屏铺满时仍强制直角
                let disp = CGDisplayBounds(CGMainDisplayID())
                let r: CGFloat = (w.frame.width >= disp.width - 4 && w.frame.height >= disp.height - 4) ? 0 : cornerRadius
                mask.cornerRadius = r
            }
        }
        if let menu = statusItem.menu {
            for item in menu.items where item.title.hasPrefix("圆角 ") {
                item.title = "圆角 \(Int(v.rounded()))pt（0–20，默认 10）"
            }
        }
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法设置开机自启"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 核心：勾选的 App 常驻变暗；遮罩插到该 App 窗口正上方，不遮盖其他窗口
    private func update() {
        updateStatusIcon()
        // 收集当前运行且被勾选的 App
        let active: [NSRunningApplication]
        if masterOn {
            active = NSWorkspace.shared.runningApplications.filter {
                guard let bid = $0.bundleIdentifier else { return false }
                return enabledBundles.contains(bid)
            }
        } else {
            active = []
        }

        let alive = Set(active.compactMap { $0.bundleIdentifier })

        // 已不存在/未勾选的撤罩
        for (bid, w) in overlays {
            if !alive.contains(bid), w.isVisible {
                w.orderOut(nil)
            }
        }

        for app in active {
            guard let bid = app.bundleIdentifier else { continue }
            guard let info = mainWindow(pid: app.processIdentifier) else {
                hideOverlay(for: bid)
                continue
            }

            let overlay = overlays[bid] ?? makeOverlay()
            overlays[bid] = overlay

            let cocoa = convertCGToCocoa(cg: info.rect)
            // 四周留 1px 余量，避免边缘露出一条未变暗的边
            let pad: CGFloat = 1
            overlay.setFrame(cocoa.insetBy(dx: -pad, dy: -pad), display: true)
            // 铺满整屏（全屏/最大化）时用直角，否则用 macOS 标准 10pt 圆角贴合窗口
            let disp = CGDisplayBounds(CGMainDisplayID())
            let coversDisplay = cocoa.width >= disp.width - 4 && cocoa.height >= disp.height - 4
            if let mask = overlay.contentView as? RoundedMaskView {
                mask.cornerRadius = coversDisplay ? 0 : cornerRadius
            }
            overlay.alphaValue = effectiveDim(bid)
            // 插到目标窗口正上方；原本就在上面的窗口保持在上，不被遮罩盖住
            overlay.order(.above, relativeTo: Int(info.windowID))
            if !overlay.isVisible {
                overlay.orderFrontRegardless()
                overlay.order(.above, relativeTo: Int(info.windowID))
            }
        }
    }

    private func hideOverlay(for bundle: String) {
        if let w = overlays[bundle], w.isVisible {
            w.orderOut(nil)
        }
    }

    // MARK: - 通过 CGWindowList 读取目标主窗口位置与窗口号（无需辅助功能权限）
    private func mainWindow(pid: pid_t) -> (rect: NSRect, windowID: CGWindowID)? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
            as? [[String: Any]] else { return nil }

        var best: (rect: NSRect, windowID: CGWindowID, area: CGFloat)?
        for w in list {
            guard let owner = w[kCGWindowOwnerPID as String] as? Int32, owner == pid else { continue }
            guard (w[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"],
                  let ww = b["Width"], let hh = b["Height"],
                  ww > 80, hh > 80 else { continue }
            let rect = NSRect(x: x, y: y, width: ww, height: hh)
            let area = ww * hh
            let windowID = w[kCGWindowNumber as String] as? CGWindowID ?? 0
            if best == nil || area > best!.area {
                best = (rect, windowID, area)
            }
        }
        guard let b = best else { return nil }
        return (b.rect, b.windowID)
    }

    /// CGWindowList：主屏左上角原点、y 向下；NSWindow：主屏左下角原点、y 向上。
    private func convertCGToCocoa(cg: NSRect) -> NSRect {
        let mainH = CGDisplayBounds(CGMainDisplayID()).height
        let yBottom = mainH - cg.maxY
        return NSRect(x: cg.minX, y: yBottom, width: cg.width, height: cg.height)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
