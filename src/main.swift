import Cocoa
import ServiceManagement

// MARK: - 持久化键
enum Keys {
    static let masterOn = "appdim.masterOn"
    static let dimLevel = "appdim.dimLevel"
    static let enabled = "appdim.enabledBundles"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    // bundleID -> 遮罩窗口
    var overlays: [String: NSWindow] = [:]

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

    /// 已勾选变暗的 App（bundleID 集合），持久化
    var enabledBundles: Set<String> {
        get {
            let arr = UserDefaults.standard.stringArray(forKey: Keys.enabled)
                ?? ["com.tencent.xinWeChat", "com.xingin.discover"]
            return Set(arr)
        }
        set { UserDefaults.standard.set(Array(newValue), forKey: Keys.enabled) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.update()
        }
        timer?.tolerance = 0.03
        update()
    }

    // MARK: - 遮罩窗口工厂：普通层级，插到目标窗口正上方
    private func makeOverlay() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        w.backgroundColor = .black
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
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "circle.lefthalf.filled",
                accessibilityDescription: "AppDim"
            )
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
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
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // 暗度滑杆
        let slider = NSSlider(frame: NSRect(x: 14, y: 0, width: 190, height: 24))
        slider.minValue = 15
        slider.maxValue = 60
        slider.doubleValue = Double(dimLevel * 100)
        slider.target = self
        slider.action = #selector(dimChanged(_:))
        let sliderItem = NSMenuItem()
        sliderItem.view = slider
        menu.addItem(sliderItem)

        let label = NSMenuItem(
            title: "暗度 \(Int((dimLevel * 100).rounded()))%（15%–60%）",
            action: nil,
            keyEquivalent: ""
        )
        label.isEnabled = false
        menu.addItem(label)
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
    @objc private func toggleMaster(_ sender: NSMenuItem) {
        masterOn = !masterOn
        sender.state = masterOn ? .on : .off
        update()
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
        dimLevel = CGFloat(sender.doubleValue / 100.0)
        for w in overlays.values { w.alphaValue = dimLevel }
        if let menu = statusItem.menu {
            for item in menu.items where item.title.hasPrefix("暗度 ") {
                item.title = "暗度 \(Int((dimLevel * 100).rounded()))%（15%–60%）"
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
            overlay.alphaValue = dimLevel
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
