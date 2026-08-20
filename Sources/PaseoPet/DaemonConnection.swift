import Foundation

enum ActivityStatus {
    case running, completed
}

struct ActivityEvent {
    let agentId: String
    let id: String
    let title: String
    let subtitle: String?
    let status: ActivityStatus
}

@MainActor
final class DaemonConnection {
    private let session = URLSession(configuration: .default)
    private let onStateChange: (PetState) -> Void
    private let onActivity: (ActivityEvent) -> Void
    private let clientId = "paseo-pet-\(UUID().uuidString.prefix(8))"
    private let port: String
    private let password: String?
    private var task: URLSessionWebSocketTask?
    private var connected = false
    private var pollTimer: DispatchSourceTimer?
    private var latestAgentId: String?
    private var agentStatuses: [String: SessionStatus] = [:]
    private var agentPermissionCounts: [String: Int] = [:]
    private(set) var serverId: String?

    var onPermission: ((PermissionNotification) -> Void)?
    var onPermissionCleared: ((String) -> Void)?
    var onSessionNotification: ((SessionNotification) -> Void)?
    var onAgentRemoved: ((String) -> Void)?
    var onPermissionResolved: ((String, String) -> Void)?

    init(onStateChange: @escaping (PetState) -> Void, onActivity: @escaping (ActivityEvent) -> Void) {
        let environment = ProcessInfo.processInfo.environment
        self.port = environment["PASEO_PORT"] ?? "6767"
        let environmentPassword = environment["PASEO_PASSWORD"]
        self.password = environmentPassword?.isEmpty == false ? environmentPassword : CredentialStore.loadPassword()
        self.onStateChange = onStateChange
        self.onActivity = onActivity
#if DEBUG
        CredentialStore.assertSecurityRules()
#endif
    }

    func connect() {
        guard let url = URL(string: "ws://localhost:\(port)/ws") else { return }

        disconnect()
        let protocols = password.map { ["paseo.bearer.\($0)"] }
        task = session.webSocketTask(with: url, protocols: protocols ?? [])
        task?.resume()
        sendHello()
        receiveLoop()
        appendDebugLog("connecting to \(url)")
    }

    private func appendDebugLog(_ msg: String) {
        guard ProcessInfo.processInfo.environment["PASEO_PET_DEBUG"] == "1" else { return }
        let line = "[PaseoPet] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaseoPet", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("debug.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        pollTimer?.cancel()
        pollTimer = nil
        connected = false
    }

    // MARK: - Protocol

    private func sendHello() {
        let hello: [String: Any] = [
            "type": "hello",
            "clientId": clientId,
            "clientType": "browser",
            "protocolVersion": 1,
        ]
        send(hello)
    }

    private func send(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let str = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(str)) { _ in }
    }

    func respondToPermission(agentId: String, requestId: String, behavior: String, selectedActionId: String) {
        sendSession([
            "type": "agent_permission_response",
            "agentId": agentId,
            "requestId": requestId,
            "response": [
                "behavior": behavior,
                "selectedActionId": selectedActionId,
            ],
        ])
    }

    // MARK: - Receive

    private func receiveLoop() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message {
                        self.handleMessage(text)
                    }
                    self.receiveLoop()
                case .failure(let error):
                    self.appendDebugLog("ws failure: \(error.localizedDescription)")
                    try? await Task.sleep(for: .seconds(5))
                    self.connect()
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let type = json["type"] as? String
        if type == "session", let message = json["message"] as? [String: Any] {
            handleSessionMessage(message)
        }
    }

    private func handleSessionMessage(_ msg: [String: Any]) {
        let type = msg["type"] as? String

        if type == "status", let payload = msg["payload"] as? [String: Any],
           payload["status"] as? String == "server_info" {
            connected = true
            serverId = payload["serverId"] as? String
            agentStatuses.removeAll()
            agentPermissionCounts.removeAll()
            appendDebugLog("daemon connected")
            startPolling()
            sendFetchAgents()
            return
        }

        if type == "agent_update", let payload = msg["payload"] as? [String: Any] {
            handleAgentUpdate(payload)
            return
        }

        if type == "fetch_agents_response", let payload = msg["payload"] as? [String: Any] {
            let entries = payload["entries"] as? [[String: Any]] ?? []
            appendDebugLog("fetch_agents_response entries=\(entries.count)")
            handleFetchAgentsResponse(payload)
            return
        }

        if type == "agent_stream", let payload = msg["payload"] as? [String: Any] {
            handleAgentStream(payload)
        }
    }

    // Codex: poll running sessions every 15s so expiry/staleness stays fresh

    private func startPolling() {
        guard pollTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 15, repeating: 15)
        t.setEventHandler { [weak self] in
            self?.sendFetchAgents()
        }
        t.resume()
        pollTimer = t
    }

    private func sendFetchAgents() {
        // subscribe: true makes the daemon push agent_update for every lifecycle change
        sendSession([
            "type": "fetch_agents_request",
            "requestId": UUID().uuidString,
            "scope": "active",
            "subscribe": ["subscriptionId": "paseo-pet"],
        ])
    }

    func stopAgent(agentId: String) {
        // Codex "Stop": interrupt the running turn, not archive
        sendSession([
            "type": "send_agent_message_request",
            "requestId": UUID().uuidString,
            "agentId": agentId,
            "text": "",
            "activeTurnBehavior": "interrupt",
        ])
    }

    // All RPC messages go through the session envelope: {type:"session", message:{...}}
    private func sendSession(_ message: [String: Any]) {
        send(["type": "session", "message": message])
    }

    private func handleAgentUpdate(_ payload: [String: Any]) {
        let kind = payload["kind"] as? String

        if kind == "remove", let agentId = payload["agentId"] as? String {
            agentStatuses.removeValue(forKey: agentId)
            agentPermissionCounts.removeValue(forKey: agentId)
            onAgentRemoved?(agentId)
            onStateChange(aggregateState())
            return
        }

        guard kind == "upsert",
              let agent = payload["agent"] as? [String: Any] else { return }

        let status = agent["status"] as? String ?? "idle"
        let perms = (agent["pendingPermissions"] as? [Any])?.count ?? 0
        appendDebugLog("agent_update status=\(status) perms=\(perms)")
        let agentId = agent["id"] as? String ?? ""
        let title = agent["title"] as? String ?? "Agent"
        let requiresAttention = agent["requiresAttention"] as? Bool ?? false

        // Codex session status: waiting > failed > review > running > idle
        // closed/initializing are not visible states
        let sessionStatus: SessionStatus
        if perms > 0 {
            sessionStatus = .waiting
        } else if status == "error" {
            sessionStatus = .failed
        } else if requiresAttention {
            sessionStatus = .review
        } else if status == "running" {
            sessionStatus = .running
        } else if status == "closed" || status == "initializing" {
            sessionStatus = .idle
        } else {
            sessionStatus = .idle
        }

        // Track per-agent status so the aggregate is stable across updates
        agentStatuses[agentId] = sessionStatus
        agentPermissionCounts[agentId] = perms

        // When pending permissions clear (approved/denied from another client),
        // dismiss the waiting notification for that agent
        if perms == 0 {
            onPermissionCleared?(agentId)
        }

        let notif = SessionNotification(
            id: agentId,
            agentId: agentId,
            title: title,
            subtitle: nil,
            status: sessionStatus
        )

        onStateChange(aggregateState())
        let isActive = sessionStatus != .idle && status != "closed" && status != "initializing"
        if isActive {
            onSessionNotification?(notif)
        } else {
            onAgentRemoved?(agentId)
        }
    }

    // Codex: pet state = highest-priority session across all agents
    private func aggregateState() -> PetState {
        if agentStatuses.values.contains(.waiting) { return .waiting }
        if agentStatuses.values.contains(.failed) { return .failed }
        if agentStatuses.values.contains(.review) { return .review }
        if agentStatuses.values.contains(.running) { return .running }
        return .idle
    }

    private func handleFetchAgentsResponse(_ payload: [String: Any]) {
        guard let entries = payload["entries"] as? [[String: Any]] else { return }
        for entry in entries {
            guard let agent = entry["agent"] as? [String: Any] else { continue }
            handleAgentUpdate(["kind": "upsert", "agent": agent])
        }
    }

    private func handleAgentStream(_ payload: [String: Any]) {
        guard let event = payload["event"] as? [String: Any],
              let agentId = payload["agentId"] as? String, !agentId.isEmpty else { return }
        latestAgentId = agentId
        let eventType = event["type"] as? String

        if eventType == "permission_requested", let request = event["request"] as? [String: Any] {
            agentStatuses[agentId] = .waiting
            agentPermissionCounts[agentId] = max(1, agentPermissionCounts[agentId] ?? 0)
            onStateChange(aggregateState())
            onPermission?(makePermissionNotification(agentId: agentId, request: request))
            return
        }

        if eventType == "permission_resolved",
           let requestId = event["requestId"] as? String {
            onPermissionResolved?(agentId, requestId)
            sendFetchAgents()
        }

        if eventType == "timeline", let item = event["item"] as? [String: Any],
           item["type"] as? String == "tool_call" {
            let toolStatus = item["status"] as? String
            let callId = item["callId"] as? String ?? UUID().uuidString
            let name = item["name"] as? String ?? "tool"
            let detail = item["detail"] as? [String: Any]
            let (title, subtitle) = formatActivityParts(name: name, detail: detail, status: toolStatus ?? "completed")
            let actStatus: ActivityStatus = toolStatus == "running" ? .running : .completed
            let activity = ActivityEvent(agentId: agentId, id: callId, title: title, subtitle: subtitle, status: actStatus)
#if DEBUG
            assert(activity.agentId == agentId, "Tool activity must stay attached to its session")
#endif
            onActivity(activity)
        }
    }

    // Extract the command/path from a permission detail payload
    private func detailDescription(_ detail: [String: Any]) -> String? {
        let type = detail["type"] as? String
        switch type {
        case "shell":
            return detail["command"] as? String
        case "read", "edit", "write":
            return detail["filePath"] as? String
        case "search":
            return detail["query"] as? String
        case "fetch":
            return detail["url"] as? String
        default:
            return nil
        }
    }

    private func makePermissionNotification(agentId: String, request: [String: Any]) -> PermissionNotification {
        let requestId = request["id"] as? String ?? UUID().uuidString
        let name = request["name"] as? String ?? "Permission"
        let title = request["title"] as? String ?? name
        let kind = request["kind"] as? String ?? "other"

        // Codex shows the actual command/path under the title
        var description = request["description"] as? String
        if description == nil || description?.isEmpty == true,
           let detail = request["detail"] as? [String: Any] {
            description = detailDescription(detail)
        }

        var actions: [(id: String, label: String, behavior: String, variant: String?)] = []
        if let rawActions = request["actions"] as? [[String: Any]] {
            for a in rawActions {
                let id = a["id"] as? String ?? ""
                let label = a["label"] as? String ?? ""
                let behavior = a["behavior"] as? String ?? "allow"
                let variant = a["variant"] as? String
                actions.append((id: id, label: label, behavior: behavior, variant: variant))
            }
        }
        if actions.isEmpty {
            actions = [
                (id: "allow", label: "Allow", behavior: "allow", variant: "primary"),
                (id: "deny", label: "Deny", behavior: "deny", variant: "secondary"),
            ]
        }

        return PermissionNotification(
            agentId: agentId,
            requestId: requestId,
            title: title,
            description: description,
            kind: kind,
            actions: actions
        )
    }

    func sendMessage(to agentId: String? = nil, text: String) {
        let targetAgent = agentId ?? latestAgentId ?? ""
        guard !targetAgent.isEmpty else { return }
        sendSession([
            "type": "send_agent_message_request",
            "requestId": UUID().uuidString,
            "agentId": targetAgent,
            "text": text,
        ])
    }

    // Codex: subtitle over 60 chars falls back to the plain short copy
    private static let activityTextLimit = 60

    private func formatActivityParts(name: String, detail: [String: Any]?, status: String) -> (title: String, subtitle: String?) {
        let done = status != "running"
        func sub(_ s: String?) -> String? {
            guard let s, !s.isEmpty else { return nil }
            let cleaned = cleanActivityText(s)
            guard let cleaned else { return nil }
            return cleaned.count > Self.activityTextLimit ? nil : cleaned
        }
        guard let detail else {
            let label = name.replacingOccurrences(of: "_", with: " ")
            return (done ? "Called \(label)" : "Calling \(label)", nil)
        }
        let type = detail["type"] as? String
        switch type {
        case "shell":
            let cmd = detail["command"] as? String
            return (done ? "Ran command" : "Running command", sub(cmd))
        case "edit", "write":
            let path = detail["filePath"] as? String
            return (done ? "Edited files" : "Editing files", sub(path.map(basename)))
        case "read":
            let path = detail["filePath"] as? String
            return (done ? "Read files" : "Reading files", sub(path.map(basename)))
        case "search":
            let query = detail["query"] as? String
            return (done ? "Searched web" : "Searching web", sub(query.map { "Searched \"\($0)\"" } ?? "Searched web"))
        case "fetch":
            let url = detail["url"] as? String
            return (done ? "Searched web" : "Searching web", sub(url))
        default:
            let label = name.replacingOccurrences(of: "_", with: " ")
            return (done ? "Called \(label)" : "Calling \(label)", nil)
        }
    }

    // Codex: strip markdown markers, collapse whitespace; empty → nil
    private func cleanActivityText(_ raw: String) -> String? {
        var t = raw
        t = t.replacingOccurrences(of: #"^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"__([^_]+)__"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\*([^*]+)\*"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"_([^_]+)_"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    private func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
