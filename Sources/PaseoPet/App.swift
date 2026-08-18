import AppKit

private extension CharacterSet {
    static let paseoPathSegmentAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return allowed
    }()
}

@main
struct PaseoPetApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var petWindow: PetWindow!
    private var messagePanel: MessagePanelWindow!
    private var engine: SpriteEngine!
    private var lookTracker: LookTracker!
    private var daemonConnection: DaemonConnection!
    private var quickChat: QuickChatWindow!
    private var pets: [PetEntry] = []
    private var activePetId: String?
    private var petSize: CGFloat = 192

    private static let sizeKey = "petSize"
    private static let greetedPetsKey = "firstAwakePetIds"

    func applicationDidFinishLaunching(_ notification: Notification) {
        petSize = CGFloat(UserDefaults.standard.float(forKey: Self.sizeKey))
        if petSize < 80 { petSize = 192 }
        pets = PetCatalog.scan()
        petWindow = PetWindow()
        messagePanel = MessagePanelWindow(anchorWindow: petWindow, petSize: petWindow.frame.size)
        quickChat = QuickChatWindow(anchorWindow: petWindow) { [weak self] text in self?.daemonConnection?.sendMessage(text: text) }
        setupTray()
        if let first = pets.first { selectPet(first) }
        applySize(petSize)
        petWindow.orderFront(nil)
    }

    private func setupTray() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Paseo Pet")
        statusItem.button?.image?.size = NSSize(width: 16, height: 16)
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: activePetId ?? "No pet", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        for pet in pets {
            let item = NSMenuItem(title: pet.displayName, action: #selector(petMenuItemClicked(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = pet.id; item.state = pet.id == activePetId ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let sizeMenu = NSMenu()
        for size in [80, 120, 160, 192, 224] {
            let item = NSMenuItem(title: "\(size)px", action: #selector(sizeMenuItemClicked(_:)), keyEquivalent: "")
            item.target = self; item.tag = size; item.state = Int(petSize) == size ? .on : .off
            sizeMenu.addItem(item)
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: ""); sizeItem.submenu = sizeMenu; menu.addItem(sizeItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quick Chat", action: #selector(toggleQuickChat), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Set Daemon Password…", action: #selector(setPassword), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Show", action: #selector(showPet), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Hide", action: #selector(hidePet), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        return menu
    }

    @objc private func petMenuItemClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let pet = pets.first(where: { $0.id == id }) else { return }
        selectPet(pet); statusItem.menu = buildMenu()
    }

    @objc private func sizeMenuItemClicked(_ sender: NSMenuItem) { applySize(CGFloat(sender.tag)); statusItem.menu = buildMenu() }
    @objc private func toggleQuickChat() { quickChat.toggle() }

    @objc private func setPassword() {
        let alert = NSAlert(); alert.messageText = "Paseo Daemon Password"; alert.informativeText = "Enter the password for ws://localhost:6767"
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); input.placeholderString = "Password"; alert.accessoryView = input
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, !input.stringValue.isEmpty {
            if KeychainHelper.savePassword(input.stringValue) {
                reconnectDaemon()
            } else {
                let error = NSAlert()
                error.messageText = "Could not save password"
                error.informativeText = "Paseo Pet could not write to macOS Keychain."
                error.runModal()
            }
        }
    }

    private func reconnectDaemon() { daemonConnection?.disconnect(); daemonConnection = makeDaemonConnection(); daemonConnection.connect() }

    private func makeDaemonConnection() -> DaemonConnection {
        let conn = DaemonConnection(
            onStateChange: { [weak self] in self?.engine.setState($0) },
            onActivity: { [weak self] in self?.handleActivity($0) }
        )
        conn.onPermission = { [weak self] permission in self?.showPermission(permission) }
        conn.onPermissionResolved = { [weak self] _, requestId in self?.messagePanel.clearBubble(threadId: "perm-\(requestId)") }
        conn.onPermissionCleared = { [weak self] agentId in self?.messagePanel.clearPermissions(for: agentId) }
        conn.onSessionNotification = { [weak self] session in self?.showSession(session) }
        conn.onAgentRemoved = { [weak self] agentId in self?.messagePanel.clearAgent(agentId) }
        return conn
    }

    private func showSession(_ session: SessionNotification) {
        guard session.status != .idle else { messagePanel.clearBubble(threadId: session.agentId); return }
        var actions: [PetBubbleAction] = []
        if session.status == .running {
            actions = [PetBubbleAction(id: "stop", label: "Stop", handler: { [weak self] in self?.daemonConnection.stopAgent(agentId: session.agentId) })]
        }
        let bubble = PetBubble(
            title: session.title,
            detail: session.subtitle,
            indicator: session.status.indicator,
            actions: actions,
            onActivate: { [weak self] in self?.openAgent(session.agentId) }
        )
        let ttl: TimeInterval? = switch session.status {
        case .failed: 3600
        case .waiting: 86400
        case .review: 7 * 86400
        case .running, .idle: nil
        }
        messagePanel.setBubble(bubble, threadId: session.agentId, agentId: session.agentId, ttl: ttl)
    }

    private func showPermission(_ permission: PermissionNotification) {
        let actions = permission.actions.prefix(3).map { action in
            PetBubbleAction(
                id: action.id,
                label: action.label,
                tone: action.behavior == "allow" ? (action.variant == "danger" ? .danger : .primary) : .normal,
                handler: { [weak self] in
                    self?.daemonConnection.respondToPermission(
                        agentId: permission.agentId,
                        requestId: permission.requestId,
                        behavior: action.behavior,
                        selectedActionId: action.id
                    )
                }
            )
        }
        let bubble = PetBubble(title: permission.title, detail: permission.description, indicator: .waiting, actions: Array(actions), actionsRequireHover: false)
        messagePanel.setBubble(bubble, threadId: "perm-\(permission.requestId)", agentId: permission.agentId, ttl: 86400)
    }

    private func handleActivity(_ activity: ActivityEvent) {
        let indicator: PetBubbleIndicator = activity.status == .running ? .working : .success
        messagePanel.setBubble(
            PetBubble(title: activity.title, detail: activity.subtitle, indicator: indicator),
            threadId: "activity",
            ttl: activity.status == .completed ? 3 : nil
        )
    }

    @objc private func showPet() { petWindow.orderFront(nil); messagePanel.showWithPet() }
    @objc private func hidePet() { petWindow.orderOut(nil); messagePanel.hideWithPet() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func applySize(_ size: CGFloat) {
        petSize = max(80, min(224, size)); UserDefaults.standard.set(Float(petSize), forKey: Self.sizeKey)
        let ratio = petSize / 192; let newSize = NSSize(width: 192 * ratio, height: 208 * ratio)
        petWindow.setContentSize(newSize); petWindow.spriteView.frame = NSRect(origin: .zero, size: newSize)
        BoundsStore.clamp(window: petWindow)
        messagePanel.updatePetSize(newSize); messagePanel.reposition()
    }

    private func selectPet(_ pet: PetEntry) {
        activePetId = pet.id; petWindow.loadPet(pet)
        engine?.stop(); engine = SpriteEngine(rows: pet.rows)
        engine.onFrame = { [weak self] col, row, rows in DispatchQueue.main.async { self?.petWindow.spriteView.showFrame(col: col, row: row, rows: rows) } }
        engine.start()
        petWindow.spriteView.onHover = { [weak self] in self?.engine.setHovered($0) }
        petWindow.onDragStart = { [weak self] in self?.messagePanel.beginPetDrag() }
        petWindow.onDragDelta = { [weak self] dx in self?.engine.setDragDirection(dx); self?.messagePanel.reposition(); self?.quickChat.reposition() }
        petWindow.onDragEnd = { [weak self] in self?.engine.clearDragState(); self?.messagePanel.endPetDrag() }
        petWindow.onClick = { [weak self] in self?.openMainApp() }
        petWindow.onRightClick = { [weak self] in self?.showContextMenu(at: $0) }
        lookTracker?.stop(); lookTracker = LookTracker(petWindow: petWindow, rows: pet.rows) { [weak self] in self?.engine.setLookDirection($0) }; lookTracker.start()
        showFirstAwakeIfNeeded(pet)
        if daemonConnection == nil { daemonConnection = makeDaemonConnection(); daemonConnection.connect() }
    }

    private func showFirstAwakeIfNeeded(_ pet: PetEntry) {
        var greeted = Set(UserDefaults.standard.stringArray(forKey: Self.greetedPetsKey) ?? [])
        guard greeted.insert(pet.id).inserted else { return }
        UserDefaults.standard.set(Array(greeted), forKey: Self.greetedPetsKey)
        messagePanel.setBubble(PetBubble(title: "Hi, I'm \(pet.displayName)", detail: "I'm here to help keep your Paseo sessions moving", indicator: .none), threadId: "first-awake", ttl: 8)
    }

    private func openAgent(_ agentId: String) {
        guard
            let serverId = daemonConnection.serverId,
            let encodedServerId = serverId.addingPercentEncoding(withAllowedCharacters: .paseoPathSegmentAllowed),
            let encodedAgentId = agentId.addingPercentEncoding(withAllowedCharacters: .paseoPathSegmentAllowed),
            let url = URL(string: "paseo://h/\(encodedServerId)/agent/\(encodedAgentId)")
        else {
            openMainApp()
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func openMainApp() {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "sh.paseo.desktop").first {
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]); return
        }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Paseo.app"), configuration: .init()) { _, _ in }
    }

    private func showContextMenu(at location: NSPoint) {
        let menu = NSMenu(); menu.addItem(NSMenuItem(title: "Close pet", action: #selector(hidePet), keyEquivalent: "")); menu.addItem(.separator())
        for pet in pets {
            let item = NSMenuItem(title: pet.displayName, action: #selector(petMenuItemClicked(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = pet.id; item.state = pet.id == activePetId ? .on : .off; menu.addItem(item)
        }
        menu.addItem(.separator()); menu.addItem(NSMenuItem(title: "Hide", action: #selector(hidePet), keyEquivalent: ""))
        for item in menu.items where item.action != nil && item.target == nil { item.target = self }
        menu.popUp(positioning: nil, at: location, in: nil)
    }
}
