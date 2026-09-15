import AppKit
import SwiftUI
import BriefCore

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: AppModel
    private var panel: FloatingPanel!
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var isCollapsed = false
    private var screenObserver: NSObjectProtocol?
    private var savedExpandedOrigin: NSPoint?
    private var anchorScreenID: CGDirectDisplayID?

    init(model: AppModel) { self.model = model }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installApplicationMenu()
        createPanel()
        model.onOpenSettings = { [weak self] in self?.showSettings() }
        model.onCloseSettings = { [weak self] in self?.settingsWindow?.close() }
        model.onCollapse = { [weak self] in self?.collapse() }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.badge.star", accessibilityDescription: "SideBrief")
        statusItem.button?.toolTip = "SideBrief · 每日精选"
        let menu = NSMenu()
        addMenu("显示侧读", action: #selector(showPanel), key: "", to: menu)
        addMenu("立即更新", action: #selector(refresh), key: "", to: menu)
        addMenu("设置…", action: #selector(showSettings), key: ",", to: menu)
        menu.addItem(.separator())
        addMenu("退出 SideBrief", action: #selector(quit), key: "q", to: menu)
        statusItem.menu = menu; self.statusItem = statusItem
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.placePanel(reset: true) }
        }
        model.start()
    }

    private func addMenu(_ title: String, action: Selector, key: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
    }

    private func installApplicationMenu() {
        let bar = NSMenu()
        let applicationItem = NSMenuItem(); let applicationMenu = NSMenu(title: "SideBrief")
        addMenu("设置…", action: #selector(showSettings), key: ",", to: applicationMenu)
        applicationMenu.addItem(.separator())
        addMenu("退出 SideBrief", action: #selector(quit), key: "q", to: applicationMenu)
        applicationItem.submenu = applicationMenu; bar.addItem(applicationItem)
        let editItem = NSMenuItem(); let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        editItem.submenu = editMenu; bar.addItem(editItem)
        NSApp.mainMenu = bar
    }

    private func createPanel() {
        panel = FloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.title = "SideBrief · 侧读"
        panel.delegate = self
        installExpandedContent()
        placePanel(reset: true)
        panel.orderFrontRegardless()
    }

    private func screenForPanel() -> NSScreen? {
        if let anchorScreenID, let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == anchorScreenID }) { return screen }
        return panel?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func installExpandedContent() {
        panel.contentView = NSHostingView(rootView: BriefRootView(model: model))
    }

    private func placePanel(reset: Bool) {
        guard let screen = screenForPanel() else { return }
        let visible = screen.visibleFrame
        let size = isCollapsed ? NSSize(width: 30, height: 112) : NSSize(width: min(392, visible.width - 24), height: min(650, visible.height - 28))
        var origin = NSPoint(x: visible.maxX - size.width - (isCollapsed ? 0 : 14), y: visible.maxY - size.height - 18)
        if !reset, !isCollapsed, let savedExpandedOrigin { origin = savedExpandedOrigin }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func collapse() {
        guard !isCollapsed else { return }
        savedExpandedOrigin = panel.frame.origin
        anchorScreenID = (panel.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        isCollapsed = true
        panel.contentView = NSHostingView(rootView: CollapsedTabView(onExpand: { [weak self] in self?.showPanel() }))
        placePanel(reset: true)
        panel.orderFrontRegardless()
    }

    @objc func showPanel() {
        isCollapsed = false; installExpandedContent(); placePanel(reset: false)
        panel.orderFrontRegardless()
    }
    @objc private func refresh() { model.refresh() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc func showSettings() {
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "SideBrief 设置"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.delegate = self
        window.center(); settingsWindow = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settingsWindow { settingsWindow = nil }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
}
