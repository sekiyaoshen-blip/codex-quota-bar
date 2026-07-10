import AppKit
import Foundation

struct RateLimitWindow {
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Date?

    var remainingPercent: Int { max(0, 100 - usedPercent) }
}

struct RateLimitSnapshot {
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
}

final class CodexRateLimitClient {
    enum State: Equatable {
        case starting
        case ready
        case error(String)
    }

    var onSnapshot: ((RateLimitSnapshot) -> Void)?
    var onStateChange: ((State) -> Void)?

    private let queue = DispatchQueue(label: "com.seki.codexquotabar.client")
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = Data()
    private var initialized = false
    private var requestInFlight = false
    private var nextRequestID = 1
    private var refreshTimer: DispatchSourceTimer?
    private var restartWorkItem: DispatchWorkItem?
    private var stopped = false

    func start() {
        queue.async { [weak self] in self?.launchServer() }
    }

    func stop() {
        queue.sync {
            stopped = true
            restartWorkItem?.cancel()
            refreshTimer?.cancel()
            refreshTimer = nil
            terminateServer()
        }
    }

    func refresh() {
        queue.async { [weak self] in self?.requestRateLimits() }
    }

    private func launchServer() {
        guard !stopped, process == nil else { return }

        guard let codexPath = findCodexExecutable() else {
            publishState(.error("未找到 Codex，请先安装或登录 Codex"))
            scheduleRestart(after: 30)
            return
        }

        initialized = false
        requestInFlight = false
        outputBuffer.removeAll(keepingCapacity: true)
        publishState(.starting)

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()

        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let preferredPaths = [
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        let existingPath = environment["PATH"] ?? ""
        environment["PATH"] = (preferredPaths + [existingPath]).joined(separator: ":")
        environment["HOME"] = home
        process.environment = environment

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consume(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.serverTerminated() }
        }

        do {
            try process.run()
            self.process = process
            inputPipe = input
            outputPipe = output
            errorPipe = errors
            send([
                "method": "initialize",
                "id": 0,
                "params": [
                    "clientInfo": [
                        "name": "codex_quota_bar",
                        "title": "Codex Quota Bar",
                        "version": "1.0.0"
                    ]
                ]
            ])
            send(["method": "initialized", "params": [String: Any]()])
        } catch {
            terminateServer()
            publishState(.error("Codex 启动失败：\(error.localizedDescription)"))
            scheduleRestart(after: 15)
        }
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let message = object as? [String: Any] else { continue }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        if let id = message["id"] as? NSNumber, id.intValue == 0, message["result"] != nil {
            initialized = true
            publishState(.ready)
            startRefreshTimer()
            requestRateLimits()
            return
        }

        if let id = message["id"] as? NSNumber, id.intValue > 0 {
            requestInFlight = false
            if let result = message["result"] as? [String: Any],
               let snapshot = parseSnapshot(from: result) {
                publishSnapshot(snapshot)
                publishState(.ready)
            } else if let error = message["error"] as? [String: Any],
                      let detail = error["message"] as? String {
                publishState(.error("读取失败：\(detail)"))
            }
            return
        }

        if message["method"] as? String == "account/rateLimits/updated",
           let params = message["params"] as? [String: Any],
           let snapshot = parseSnapshot(from: params) {
            publishSnapshot(snapshot)
        }
    }

    private func parseSnapshot(from container: [String: Any]) -> RateLimitSnapshot? {
        var raw = container["rateLimits"] as? [String: Any]
        if let buckets = container["rateLimitsByLimitId"] as? [String: Any],
           let codex = buckets["codex"] as? [String: Any] {
            raw = codex
        }
        guard let snapshot = raw else { return nil }
        return RateLimitSnapshot(
            primary: parseWindow(snapshot["primary"]),
            secondary: parseWindow(snapshot["secondary"])
        )
    }

    private func parseWindow(_ value: Any?) -> RateLimitWindow? {
        guard let dictionary = value as? [String: Any],
              let used = dictionary["usedPercent"] as? NSNumber else { return nil }
        let duration = (dictionary["windowDurationMins"] as? NSNumber)?.intValue
        let resetTimestamp = (dictionary["resetsAt"] as? NSNumber)?.doubleValue
        return RateLimitWindow(
            usedPercent: used.intValue,
            windowDurationMins: duration,
            resetsAt: resetTimestamp.map(Date.init(timeIntervalSince1970:))
        )
    }

    private func requestRateLimits() {
        guard initialized, !requestInFlight, process?.isRunning == true else { return }
        requestInFlight = true
        let requestID = nextRequestID
        nextRequestID += 1
        send(["method": "account/rateLimits/read", "id": requestID])

        queue.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self, self.requestInFlight else { return }
            self.requestInFlight = false
            self.publishState(.error("读取超时，将在下一分钟重试"))
        }
    }

    private func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.requestRateLimits() }
        timer.resume()
        refreshTimer = timer
    }

    private func send(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        do {
            try inputPipe?.fileHandleForWriting.write(contentsOf: data)
        } catch {
            publishState(.error("无法连接 Codex：\(error.localizedDescription)"))
        }
    }

    private func serverTerminated() {
        guard process != nil else { return }
        terminateServer()
        initialized = false
        requestInFlight = false
        refreshTimer?.cancel()
        refreshTimer = nil
        if !stopped {
            publishState(.error("Codex 连接已断开，正在重连"))
            scheduleRestart(after: 5)
        }
    }

    private func terminateServer() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning { process.terminate() }
        try? inputPipe?.fileHandleForWriting.close()
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
    }

    private func scheduleRestart(after delay: TimeInterval) {
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.launchServer() }
        restartWorkItem = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func findCodexExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/codex",
            "\(home)/.codex/packages/standalone/current/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func publishSnapshot(_ snapshot: RateLimitSnapshot) {
        DispatchQueue.main.async { [weak self] in self?.onSnapshot?(snapshot) }
    }

    private func publishState(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client = CodexRateLimitClient()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let fiveHourItem = NSMenuItem(title: "5 小时额度：等待数据", action: nil, keyEquivalent: "")
    private let fiveResetItem = NSMenuItem(title: "重置时间：—", action: nil, keyEquivalent: "")
    private let weekItem = NSMenuItem(title: "一周额度：等待数据", action: nil, keyEquivalent: "")
    private let weekResetItem = NSMenuItem(title: "重置时间：—", action: nil, keyEquivalent: "")
    private let updateItem = NSMenuItem(title: "正在连接 Codex…", action: nil, keyEquivalent: "")
    private let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r")
    private var latestSnapshot: RateLimitSnapshot?
    private var lastUpdated: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureMenu()

        client.onSnapshot = { [weak self] snapshot in
            self?.latestSnapshot = snapshot
            self?.lastUpdated = Date()
            self?.render(snapshot)
        }
        client.onStateChange = { [weak self] state in self?.render(state) }
        client.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        client.stop()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.title = "Codex …"
        button.toolTip = "Codex 剩余额度"
        if let image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "Codex 额度") {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
        }
    }

    private func configureMenu() {
        let menu = NSMenu()
        let title = NSMenuItem(title: "Codex 剩余额度", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        [fiveHourItem, fiveResetItem, weekItem, weekResetItem, updateItem].forEach { $0.isEnabled = false }
        menu.addItem(fiveHourItem)
        menu.addItem(fiveResetItem)
        menu.addItem(.separator())
        menu.addItem(weekItem)
        menu.addItem(weekResetItem)
        menu.addItem(.separator())
        menu.addItem(updateItem)
        menu.addItem(refreshItem)

        let usageItem = NSMenuItem(title: "打开 Codex 用量页面", action: #selector(openUsagePage), keyEquivalent: "")
        usageItem.target = self
        menu.addItem(usageItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        refreshItem.target = self
        statusItem.menu = menu
    }

    private func render(_ snapshot: RateLimitSnapshot) {
        let short = snapshot.primary.map { "5h \($0.remainingPercent)%" } ?? "5h —"
        let weekly = snapshot.secondary.map { "周 \($0.remainingPercent)%" } ?? "周 —"
        statusItem.button?.title = "\(short) · \(weekly)"

        fiveHourItem.title = detailTitle(label: "5 小时额度", window: snapshot.primary)
        fiveResetItem.title = "重置时间：\(resetText(snapshot.primary?.resetsAt))"
        weekItem.title = detailTitle(label: "一周额度", window: snapshot.secondary)
        weekResetItem.title = "重置时间：\(resetText(snapshot.secondary?.resetsAt))"
        updateItem.title = "刚刚更新 · 每 1 分钟自动刷新"
    }

    private func render(_ state: CodexRateLimitClient.State) {
        switch state {
        case .starting:
            if latestSnapshot == nil { statusItem.button?.title = "Codex …" }
            updateItem.title = "正在连接 Codex，首次启动可能稍慢…"
            refreshItem.isEnabled = false
        case .ready:
            refreshItem.isEnabled = true
            if let lastUpdated {
                updateItem.title = "上次更新：\(timeFormatter.string(from: lastUpdated)) · 每 1 分钟"
            } else {
                updateItem.title = "已连接，正在读取额度…"
            }
        case .error(let message):
            refreshItem.isEnabled = true
            updateItem.title = message
            if latestSnapshot == nil { statusItem.button?.title = "Codex ⚠︎" }
        }
    }

    private func detailTitle(label: String, window: RateLimitWindow?) -> String {
        guard let window else { return "\(label)：暂无数据" }
        return "\(label)：剩余 \(window.remainingPercent)% · 已用 \(window.usedPercent)%"
    }

    private func resetText(_ date: Date?) -> String {
        guard let date else { return "—" }
        if Calendar.current.isDateInToday(date) {
            return "今天 \(timeFormatter.string(from: date))"
        }
        return dateFormatter.string(from: date)
    }

    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    @objc private func refreshNow() {
        updateItem.title = "正在刷新…"
        refreshItem.isEnabled = false
        client.refresh()
    }

    @objc private func openUsagePage() {
        if let url = URL(string: "https://chatgpt.com/codex/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

enum CodexQuotaBarMain {
    static func runSelfTest() {
        let client = CodexRateLimitClient()
        var finished = false
        client.onSnapshot = { snapshot in
            let primary = snapshot.primary.map { "5h_remaining=\($0.remainingPercent)%" } ?? "5h_remaining=none"
            let secondary = snapshot.secondary.map { "week_remaining=\($0.remainingPercent)%" } ?? "week_remaining=none"
            print("SELF_TEST_OK \(primary) \(secondary)")
            finished = true
            CFRunLoopStop(CFRunLoopGetMain())
        }
        client.onStateChange = { state in
            if case .error(let message) = state { fputs("SELF_TEST_STATE \(message)\n", stderr) }
        }
        client.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 65) {
            if !finished {
                fputs("SELF_TEST_TIMEOUT\n", stderr)
                CFRunLoopStop(CFRunLoopGetMain())
            }
        }
        CFRunLoopRun()
        client.stop()
        exit(finished ? 0 : 1)
    }

    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            runSelfTest()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

CodexQuotaBarMain.main()
