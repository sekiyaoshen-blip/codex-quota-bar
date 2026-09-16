import AppKit
import CFNetwork
import Foundation

struct RateLimitWindow {
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Date?

    var remainingPercent: Int { max(0, 100 - usedPercent) }
}

struct RateLimitSnapshot {
    let fiveHour: RateLimitWindow?
    let weekly: RateLimitWindow?
    let resetCreditsCount: Int?
}

enum CodexProvider: String, CaseIterable {
    case official
    case deepseek
    case aliyun
    case apiopencc
    case felixxxxx

    var displayName: String {
        switch self {
        case .official: return "OpenAI 官方"
        case .deepseek: return "DeepSeek 官方"
        case .aliyun: return "阿里百炼 Token Plan"
        case .apiopencc: return "apiopencc"
        case .felixxxxx: return "Felixxxxx"
        }
    }

    var menuName: String {
        switch self {
        case .official: return "OpenAI"
        case .deepseek: return "DeepSeek"
        case .aliyun: return "百炼 Token Plan"
        case .apiopencc: return "apiopencc"
        case .felixxxxx: return "Felixxxxx"
        }
    }

    var usagePageTitle: String {
        switch self {
        case .official: return "打开 Codex 用量页面"
        case .deepseek: return "打开 DeepSeek 用量页面"
        case .aliyun: return "打开百炼 Token Plan 用量页面"
        case .apiopencc: return "打开 apiopencc 控制台"
        case .felixxxxx: return "打开 Felixxxxx 网关"
        }
    }

    var usagePageURL: URL? {
        switch self {
        case .official: return URL(string: "https://chatgpt.com/codex/settings/usage")
        case .deepseek: return URL(string: "https://platform.deepseek.com/usage")
        case .aliyun: return URL(string: "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/overview")
        case .apiopencc: return URL(string: "https://apiopencc.com/console")
        case .felixxxxx: return URL(string: "https://codex.felixxxxx.uk/")
        }
    }
}

struct BailianPlanSnapshot {
    let usedPercent: Double
    let resetsAt: Date?

    var remainingPercent: Double { max(0, 100 - usedPercent) }
}

struct DeepSeekBalanceSnapshot {
    let currency: String
    let total: Double

    var displayText: String {
        switch currency.uppercased() {
        case "CNY": return String(format: "¥%.2f", total)
        case "USD": return String(format: "$%.2f", total)
        default: return String(format: "%.2f %@", total, currency)
        }
    }
}

struct CodexProviderStatus {
    let current: CodexProvider
    let available: Set<CodexProvider>
}

enum LocalExecutable {
    static func find(_ name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let standardDirectories = [
            home.appendingPathComponent(".local/share/mise/shims", isDirectory: true),
            home.appendingPathComponent(".local/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/bin", isDirectory: true),
            URL(fileURLWithPath: "/bin", isDirectory: true)
        ]
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        for directory in pathDirectories + standardDirectories {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

final class CodexProviderSwitcher {
    enum SwitchError: LocalizedError {
        case missingScript
        case failed(String)
        case invalidStatus

        var errorDescription: String? {
            switch self {
            case .missingScript: return "未找到 model-switch 切换脚本"
            case .failed(let message): return message
            case .invalidStatus: return "无法识别当前模型供应商"
            }
        }
    }

    private let queue = DispatchQueue(label: "com.seki.codexquotabar.provider-switcher")

    func refresh(completion: @escaping (Result<CodexProviderStatus, Error>) -> Void) {
        run(command: "status") { result in
            completion(result.flatMap { output in
                var current: CodexProvider?
                for rawLine in output.split(separator: "\n") {
                    let line = String(rawLine)
                    guard line.contains("模型 provider"), let colon = line.firstIndex(of: ":") else { continue }
                    let value = line[line.index(after: colon)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    current = CodexProvider(rawValue: value)
                    if current != nil { break }
                }
                guard let current else { return .failure(SwitchError.invalidStatus) }

                var available: Set<CodexProvider> = [.official, current]
                if output.contains("DeepSeek vault: 已保存密钥")
                    || output.contains("有 OPENAI_API_KEY")
                    || !(ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] ?? "").isEmpty {
                    available.insert(.deepseek)
                }
                if self.hasCredential(named: "deepseek-aliyun-key") {
                    available.insert(.aliyun)
                }
                if output.contains("apiopencc access: 已配置") {
                    available.insert(.apiopencc)
                }
                if output.contains("Felixxxxx access: 已配置") {
                    available.insert(.felixxxxx)
                }
                return .success(CodexProviderStatus(current: current, available: available))
            })
        }
    }

    func activate(_ provider: CodexProvider, completion: @escaping (Result<String, Error>) -> Void) {
        run(command: provider.rawValue, migrateRecent: true, completion: completion)
    }

    private func run(command: String, migrateRecent: Bool = false, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            guard let script = self.scriptURL() else {
                DispatchQueue.main.async { completion(.failure(SwitchError.missingScript)) }
                return
            }

            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path, command]
            if migrateRecent {
                guard let python = LocalExecutable.find("python3"),
                      let helper = Bundle.main.url(forResource: "switch-recent", withExtension: "py") else {
                    DispatchQueue.main.async { completion(.failure(SwitchError.failed("缺少 Python 3 或会话迁移脚本"))) }
                    return
                }
                process.executableURL = python
                process.arguments = [helper.path, command]
            }
            process.standardOutput = output
            process.standardError = errors
            do {
                try process.run()
                process.waitUntilExit()
                let stdout = String(
                    data: output.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let stderr = String(
                    data: errors.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let result: Result<String, Error>
                if process.terminationStatus == 0 {
                    result = .success(stdout)
                } else {
                    let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    result = .failure(SwitchError.failed(message.isEmpty ? "切换失败" : message))
                }
                DispatchQueue.main.async { completion(result) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func scriptURL() -> URL? {
        let script = codexHomeURL()
            .appendingPathComponent("skills/model-switch/scripts/codex-switch.sh")
        return FileManager.default.isReadableFile(atPath: script.path) ? script : nil
    }

    private func codexHomeURL() -> URL {
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private func hasCredential(named name: String) -> Bool {
        let url = codexHomeURL().appendingPathComponent("codex-switch/\(name)")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return false }
        return size.int64Value > 0
    }
}

final class BailianPlanUsageClient {
    enum State {
        case starting
        case ready
        case error(String)
    }

    var onSnapshot: ((BailianPlanSnapshot) -> Void)?
    var onStateChange: ((State) -> Void)?

    private let queue = DispatchQueue(label: "com.seki.codexquotabar.bailian-usage")
    private var refreshTimer: DispatchSourceTimer?
    private var requestInFlight = false
    private var stopped = false

    func start() {
        queue.async { [weak self] in
            guard let self, self.refreshTimer == nil else { return }
            self.stopped = false
            self.publishState(.starting)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 5 * 60, repeating: 5 * 60, leeway: .seconds(5))
            timer.setEventHandler { [weak self] in self?.requestUsage() }
            timer.resume()
            self.refreshTimer = timer
            self.requestUsage()
        }
    }

    func refresh() {
        queue.async { [weak self] in self?.requestUsage() }
    }

    func stop() {
        queue.sync {
            stopped = true
            refreshTimer?.cancel()
            refreshTimer = nil
        }
    }

    private func requestUsage() {
        guard !stopped, !requestInFlight else { return }
        requestInFlight = true
        guard let executable = LocalExecutable.find("bl") else {
            requestInFlight = false
            publishState(.error("未找到百炼 CLI（bl）"))
            return
        }

        var attempt = Self.runUsage(executable: executable, extraArguments: [])
        // The console login token lives in the `default` profile, while the
        // token-plan profile only carries the API key; fall back to it.
        if attempt.status != 0, Self.needsProfileFallback(stderr: attempt.stderr) {
            let fallback = Self.runUsage(executable: executable, extraArguments: ["--config", "default"])
            if fallback.status == 0 { attempt = fallback }
        }
        requestInFlight = false
        guard attempt.status == 0 else {
            let message = Self.readableErrorMessage(from: attempt.stderr)
            publishState(.error(message.isEmpty ? "百炼额度读取失败" : message))
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: attempt.stdout) as? [String: Any],
              let fraction = (object["per1WeekPercentage"] as? NSNumber)?.doubleValue else {
            publishState(.error("百炼额度数据格式已变化"))
            return
        }
        let resetMilliseconds = (object["per1WeekResetTime"] as? NSNumber)?.doubleValue
        let snapshot = BailianPlanSnapshot(
            usedPercent: min(100, max(0, fraction * 100)),
            resetsAt: resetMilliseconds.map { Date(timeIntervalSince1970: $0 / 1_000) }
        )
        publishSnapshot(snapshot)
        publishState(.ready)
    }

    static func runUsage(
        executable: URL,
        extraArguments: [String]
    ) -> (status: Int32, stdout: Data, stderr: String) {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = ["usage", "token-plan"] + extraArguments + ["--output", "json"]
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
            process.waitUntilExit()
            let stdout = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            return (process.terminationStatus, stdout, stderr)
        } catch {
            return (1, Data(), error.localizedDescription)
        }
    }

    static func needsProfileFallback(stderr: String) -> Bool {
        stderr.contains("\"code\": 3")
            || stderr.contains("\"code\":3")
            || stderr.localizedCaseInsensitiveContains("No console access token")
    }

    static func readableErrorMessage(from stderr: String) -> String {
        if let openingBrace = stderr.firstIndex(of: "{"),
           let closingBrace = stderr.lastIndex(of: "}"),
           openingBrace <= closingBrace {
            let jsonText = String(stderr[openingBrace...closingBrace])
            if let data = jsonText.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = object["error"] as? [String: Any] {
                let code = (error["code"] as? NSNumber)?.intValue
                let message = (error["message"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if code == 3 || message.localizedCaseInsensitiveContains("not logged in")
                    || message.localizedCaseInsensitiveContains("expired") {
                    return "登录已过期，请重新登录"
                }
                if !message.isEmpty { return message }
            }
        }

        return stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter {
                !$0.isEmpty && $0 != "{" && $0 != "}"
                    && !$0.hasPrefix("(node:") && !$0.hasPrefix("(Use `node")
            }
            .last ?? ""
    }

    private func publishSnapshot(_ snapshot: BailianPlanSnapshot) {
        DispatchQueue.main.async { [weak self] in self?.onSnapshot?(snapshot) }
    }

    private func publishState(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
    }
}

final class DeepSeekBalanceClient {
    enum State {
        case starting
        case ready
        case error(String)
    }

    static let endpoint = URL(string: "https://api.deepseek.com/user/balance")!

    var onSnapshot: ((DeepSeekBalanceSnapshot) -> Void)?
    var onStateChange: ((State) -> Void)?

    private let queue = DispatchQueue(label: "com.seki.codexquotabar.deepseek-balance")
    private var refreshTimer: DispatchSourceTimer?
    private var session: URLSession?
    private var requestInFlight = false
    private var active = false
    private var stopped = false

    func start() {
        queue.async { [weak self] in
            guard let self, self.refreshTimer == nil else { return }
            self.stopped = false
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(2))
            timer.setEventHandler { [weak self] in self?.requestBalance() }
            timer.resume()
            self.refreshTimer = timer
        }
    }

    /// DeepSeek balance is only polled while DeepSeek is the active channel.
    func setActive(_ value: Bool) {
        queue.async { [weak self] in
            guard let self, self.active != value else { return }
            self.active = value
            if value { self.requestBalance() }
        }
    }

    func refresh() {
        queue.async { [weak self] in self?.requestBalance() }
    }

    func stop() {
        queue.sync {
            stopped = true
            refreshTimer?.cancel()
            refreshTimer = nil
            session?.invalidateAndCancel()
            session = nil
            requestInFlight = false
        }
    }

    private func requestBalance() {
        guard !stopped, active, !requestInFlight else { return }
        guard let key = Self.storedKey() else {
            publishState(.error("未找到 DeepSeek 密钥"))
            return
        }
        requestInFlight = true

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-quota-bar/1.6.2", forHTTPHeaderField: "User-Agent")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        self.session = session

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                session.finishTasksAndInvalidate()
                self.session = nil
                self.requestInFlight = false
                guard !self.stopped, self.active else { return }
                if let error {
                    self.publishState(.error(error.localizedDescription))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self.publishState(.error("DeepSeek 余额读取失败"))
                    return
                }
                guard http.statusCode == 200, let data else {
                    let message = http.statusCode == 401 || http.statusCode == 403
                        ? "DeepSeek 密钥无效或已失效"
                        : "DeepSeek 余额读取失败（HTTP \(http.statusCode)）"
                    self.publishState(.error(message))
                    return
                }
                guard let snapshot = Self.parseBalance(data) else {
                    self.publishState(.error("DeepSeek 余额数据格式已变化"))
                    return
                }
                self.publishSnapshot(snapshot)
                self.publishState(.ready)
            }
        }.resume()
    }

    static func storedKey() -> String? {
        if let environment = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !environment.isEmpty {
            return environment
        }
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        let url = codexHome.appendingPathComponent("codex-switch/deepseek-key")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func parseBalance(_ data: Data) -> DeepSeekBalanceSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = object["balance_infos"] as? [[String: Any]] else { return nil }
        let preferred = infos.first { (($0["currency"] as? String) ?? "").uppercased() == "CNY" }
            ?? infos.first
        guard let info = preferred,
              let currency = info["currency"] as? String,
              let totalText = info["total_balance"] as? String,
              let total = Double(totalText) else { return nil }
        return DeepSeekBalanceSnapshot(currency: currency, total: total)
    }

    private func publishSnapshot(_ snapshot: DeepSeekBalanceSnapshot) {
        DispatchQueue.main.async { [weak self] in self?.onSnapshot?(snapshot) }
    }

    private func publishState(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
    }
}

final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

final class HydrationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class HydrationOverlayController {
    private var windows: [HydrationWindow] = []
    private var countdownLabels: [NSTextField] = []
    private var countdownTimer: Timer?
    private var endDate: Date?
    private var completion: (() -> Void)?
    private var previousApplication: NSRunningApplication?

    var isShowing: Bool { endDate != nil }

    @discardableResult
    func show(duration: TimeInterval = 30, completion: @escaping () -> Void) -> Bool {
        guard !isShowing else { return false }

        self.completion = completion
        previousApplication = NSWorkspace.shared.frontmostApplication
        endDate = Date().addingTimeInterval(duration)
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_200, height: 800)
        let size = NSSize(width: min(680, visibleFrame.width - 40), height: min(430, visibleFrame.height - 40))
        let frame = NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        let window = HydrationWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = makeContentView()
        windows = [window]
        bringToFront()

        updateCountdown()
        let timer = Timer(timeInterval: 0.1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
        return true
    }

    func stop() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        countdownLabels.removeAll()
        endDate = nil
        let applicationToRestore = previousApplication
        previousApplication = nil
        if let applicationToRestore,
           applicationToRestore.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           !applicationToRestore.isTerminated {
            if #available(macOS 14.0, *) {
                applicationToRestore.activate(options: [])
            } else {
                applicationToRestore.activate(options: [.activateIgnoringOtherApps])
            }
        }
        let callback = completion
        completion = nil
        callback?()
    }

    private func makeContentView() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.96).cgColor
        view.layer?.cornerRadius = 28
        view.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "该喝水了")
        title.font = .systemFont(ofSize: 42, weight: .semibold)
        title.textColor = .white
        title.alignment = .center

        let countdown = NSTextField(labelWithString: "30")
        countdown.font = .monospacedDigitSystemFont(ofSize: 96, weight: .bold)
        countdown.textColor = .white
        countdown.alignment = .center
        countdownLabels.append(countdown)

        let hint = NSTextField(labelWithString: "别只盯着屏幕，去看看远方")
        hint.font = .systemFont(ofSize: 22, weight: .regular)
        hint.textColor = NSColor.white.withAlphaComponent(0.75)
        hint.alignment = .center

        let stack = NSStackView(views: [title, countdown, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        return view
    }

    @objc private func tick() {
        bringToFront()
        updateCountdown()
    }

    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        windows.forEach {
            $0.orderFrontRegardless()
            $0.makeKey()
        }
    }

    private func updateCountdown() {
        guard let endDate else { return }
        let remaining = max(0, endDate.timeIntervalSinceNow)
        let seconds = Int(ceil(remaining))
        countdownLabels.forEach { $0.stringValue = String(seconds) }
        if remaining <= 0 {
            stop()
        }
    }

    deinit {
        stop()
    }
}

final class CodexRateLimitClient {
    enum State: Equatable {
        case starting
        case ready
        case error(String)
    }

    var onSnapshot: ((RateLimitSnapshot, Bool) -> Void)?
    var onStateChange: ((State) -> Void)?

    private let queue = DispatchQueue(label: "com.seki.codexquotabar.client")
    private var requestInFlight = false
    private var currentSession: URLSession?
    private var currentTask: URLSessionDataTask?
    private var refreshTimer: DispatchSourceTimer?
    private var stopped = false

    fileprivate static func makeSession(
        requestTimeout: TimeInterval = 25,
        resourceTimeout: TimeInterval = 30
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        if let proxyURL = discoverProxyURL(), let host = proxyURL.host {
            let port = proxyURL.port ?? (proxyURL.scheme == "https" ? 443 : 80)
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: port
            ]
        }
        return URLSession(
            configuration: configuration,
            delegate: NoRedirectSessionDelegate(),
            delegateQueue: nil
        )
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.publishState(.starting)
            self.startRefreshTimer()
            self.requestRateLimits()
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            refreshTimer?.cancel()
            refreshTimer = nil
            currentTask?.cancel()
            currentTask = nil
            currentSession?.invalidateAndCancel()
            currentSession = nil
            requestInFlight = false
        }
    }

    private func parseSnapshot(from container: [String: Any]) -> RateLimitSnapshot? {
        guard let rateLimit = container["rate_limit"] as? [String: Any] else { return nil }
        let primary = parseWindow(rateLimit["primary_window"])
        let secondary = parseWindow(rateLimit["secondary_window"])
        let classified = classifyWindows(primary: primary, secondary: secondary)
        let resetCredits = container["rate_limit_reset_credits"] as? [String: Any]
        let resetCreditsCount = (resetCredits?["available_count"] as? NSNumber)?.intValue
        guard classified.fiveHour != nil || classified.weekly != nil || resetCreditsCount != nil else {
            return nil
        }
        return RateLimitSnapshot(
            fiveHour: classified.fiveHour,
            weekly: classified.weekly,
            resetCreditsCount: resetCreditsCount
        )
    }

    private func classifyWindows(
        primary: RateLimitWindow?,
        secondary: RateLimitWindow?
    ) -> (fiveHour: RateLimitWindow?, weekly: RateLimitWindow?) {
        var fiveHour: RateLimitWindow?
        var weekly: RateLimitWindow?

        for window in [primary, secondary].compactMap({ $0 }) {
            guard let duration = window.windowDurationMins else { continue }
            if duration == 300 {
                fiveHour = window
            } else if duration == 10_080 {
                weekly = window
            }
        }

        // Compatibility fallback for older responses that omit durations.
        if primary?.windowDurationMins == nil { fiveHour = primary }
        if secondary?.windowDurationMins == nil { weekly = secondary }
        if fiveHour == nil, weekly == nil, let primary {
            if (primary.windowDurationMins ?? 0) >= 1_440 {
                weekly = primary
            } else {
                fiveHour = primary
            }
        }
        if weekly == nil, let secondary, secondary.windowDurationMins ?? 0 >= 1_440 {
            weekly = secondary
        }
        return (fiveHour, weekly)
    }

    private func parseWindow(_ value: Any?) -> RateLimitWindow? {
        guard let dictionary = value as? [String: Any],
              let used = dictionary["used_percent"] as? NSNumber else { return nil }
        let durationSeconds = (dictionary["limit_window_seconds"] as? NSNumber)?.intValue
        let resetTimestamp = (dictionary["reset_at"] as? NSNumber)?.doubleValue
        return RateLimitWindow(
            usedPercent: min(100, max(0, Int(used.doubleValue.rounded()))),
            windowDurationMins: durationSeconds.map { $0 / 60 },
            resetsAt: resetTimestamp.map(Date.init(timeIntervalSince1970:))
        )
    }

    private func requestRateLimits() {
        guard !stopped, !requestInFlight else { return }
        requestInFlight = true

        let credentials: (accessToken: String, accountID: String?)
        do {
            credentials = try loadCredentials()
        } catch {
            self.requestInFlight = false
            publishState(.error("未找到有效登录，请先打开官方 ChatGPT 完成登录"))
            return
        }

        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            requestInFlight = false
            publishState(.error("官方用量地址无效"))
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-quota-bar/1.6.2", forHTTPHeaderField: "User-Agent")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let session = Self.makeSession()
        currentSession = session
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            self?.queue.async {
                self?.handleResponse(data: data, response: response, error: error)
            }
        }
        currentTask = task
        task.resume()
    }

    private func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.requestRateLimits() }
        timer.resume()
        refreshTimer = timer
    }

    private func handleResponse(data: Data?, response: URLResponse?, error: Error?) {
        requestInFlight = false
        currentTask = nil
        currentSession?.finishTasksAndInvalidate()
        currentSession = nil
        guard !stopped else { return }

        if let error = error as? URLError, error.code == .cancelled { return }
        guard error == nil else {
            publishState(.error("网络连接失败，将在下一分钟重试"))
            return
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            publishState(.error("官方用量接口没有返回有效响应"))
            return
        }
        switch httpResponse.statusCode {
        case 200:
            break
        case 401, 403:
            publishState(.error("登录已过期，请打开官方 ChatGPT 后重试"))
            return
        case 429:
            publishState(.error("官方用量接口暂时繁忙，将在下一分钟重试"))
            return
        default:
            publishState(.error("读取失败（HTTP \(httpResponse.statusCode)）"))
            return
        }

        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data),
              let container = object as? [String: Any],
              let snapshot = parseSnapshot(from: container) else {
            publishState(.error("官方用量数据格式已变化"))
            return
        }
        publishSnapshot(snapshot, isPartial: false)
        publishState(.ready)
    }

    fileprivate static func discoverProxyURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        for key in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"] {
            if let value = environment[key], let url = validProxyURL(value) {
                return url
            }
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            guard let commands = String(data: data, encoding: .utf8) else { return nil }
            let officialPrefixes = [
                "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT ",
                "/Applications/Codex.app/Contents/MacOS/Codex "
            ]
            for rawLine in commands.split(separator: "\n") {
                let line = String(rawLine).trimmingCharacters(in: .whitespaces)
                guard officialPrefixes.contains(where: line.hasPrefix),
                      let marker = line.range(of: "--proxy-server=") else { continue }
                let suffix = line[marker.upperBound...]
                let value = suffix.prefix { !$0.isWhitespace }
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                if let url = validProxyURL(value) { return url }
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func validProxyURL<S: StringProtocol>(_ value: S) -> URL? {
        guard let url = URL(string: String(value)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url
    }

    private func loadCredentials() throws -> (accessToken: String, accountID: String?) {
        let authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
        let data = try Data(contentsOf: authURL, options: .uncached)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (accessToken, tokens["account_id"] as? String)
    }

    private func publishSnapshot(_ snapshot: RateLimitSnapshot, isPartial: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onSnapshot?(snapshot, isPartial) }
    }

    private func publishState(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
    }
}

final class AutoUpdater {
    private enum DefaultsKey {
        static let lastCheckTime = "last_check_time"
        static let skippedVersion = "skipped_update_version"
    }

    private enum UpdateError: Error {
        case invalidResponse
        case missingUpdater
    }

    private let checkInterval: TimeInterval = 60 * 60
    private let versionURL = URL(
        string: "https://raw.githubusercontent.com/sekiyaoshen-blip/codex-quota-bar/main/Info.plist"
    )!
    private let defaults = UserDefaults.standard
    private var isChecking = false
    private var currentSession: URLSession?
    private var currentTask: URLSessionDataTask?

    func checkIfNeeded(now: Date = Date()) {
        guard !isChecking else { return }
        if let lastCheck = defaults.object(forKey: DefaultsKey.lastCheckTime) as? Date {
            let elapsed = now.timeIntervalSince(lastCheck)
            if elapsed >= 0, elapsed < checkInterval { return }
        }

        isChecking = true
        var request = URLRequest(
            url: versionURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("codex-quota-bar-update-check", forHTTPHeaderField: "User-Agent")

        let session = CodexRateLimitClient.makeSession(requestTimeout: 20, resourceTimeout: 25)
        currentSession = session
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            let result: Result<String, Error>
            if let error {
                result = .failure(error)
            } else if let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200,
                      let data,
                      let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
                      let plist = object as? [String: Any],
                      let version = plist["CFBundleShortVersionString"] as? String,
                      Self.versionComponents(version) != nil {
                result = .success(version)
            } else {
                result = .failure(UpdateError.invalidResponse)
            }
            DispatchQueue.main.async {
                self?.finishCheck(result: result, at: now)
            }
        }
        currentTask = task
        task.resume()
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        currentSession?.invalidateAndCancel()
        currentSession = nil
        isChecking = false
    }

    private func finishCheck(result: Result<String, Error>, at date: Date) {
        currentTask = nil
        currentSession?.finishTasksAndInvalidate()
        currentSession = nil
        isChecking = false
        defaults.set(date, forKey: DefaultsKey.lastCheckTime)

        guard case .success(let latestVersion) = result,
              let currentVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String,
              Self.isNewer(latestVersion, than: currentVersion),
              defaults.string(forKey: DefaultsKey.skippedVersion) != latestVersion else {
            return
        }

        // Mark before launching. A successful updater clears this value; any failure leaves it skipped.
        defaults.set(latestVersion, forKey: DefaultsKey.skippedVersion)
        do {
            try launchUpdater(version: latestVersion)
        } catch {
            return
        }
    }

    private func launchUpdater(version: String) throws {
        guard Self.versionComponents(version) != nil,
              let updaterURL = Bundle.main.url(forResource: "update", withExtension: "sh"),
              FileManager.default.isExecutableFile(atPath: updaterURL.path),
              let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw UpdateError.missingUpdater
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [updaterURL.path, version, Bundle.main.bundlePath, bundleIdentifier]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        if environment["HTTPS_PROXY"] == nil,
           environment["https_proxy"] == nil,
           let proxyURL = CodexRateLimitClient.discoverProxyURL() {
            environment["HTTPS_PROXY"] = proxyURL.absoluteString
            environment["HTTP_PROXY"] = proxyURL.absoluteString
        }
        process.environment = environment
        try process.run()
    }

    private static func versionComponents(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        let values = parts.compactMap { component -> Int? in
            guard !component.isEmpty, component.allSatisfy(\.isNumber) else { return nil }
            return Int(component)
        }
        return values.count == parts.count ? values : nil
    }

    private static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidateParts = versionComponents(candidate),
              let currentParts = versionComponents(current) else { return false }
        let count = max(candidateParts.count, currentParts.count)
        for index in 0..<count {
            let candidateValue = index < candidateParts.count ? candidateParts[index] : 0
            let currentValue = index < currentParts.count ? currentParts[index] : 0
            if candidateValue != currentValue { return candidateValue > currentValue }
        }
        return false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum WaterReminderDefaults {
        static let enabled = "waterReminder.enabled"
        static let intervalMinutes = "waterReminder.intervalMinutes"
    }

    private let client = CodexRateLimitClient()
    private let bailianClient = BailianPlanUsageClient()
    private let deepSeekClient = DeepSeekBalanceClient()
    private let providerSwitcher = CodexProviderSwitcher()
    private let autoUpdater = AutoUpdater()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let providerRootItem = NSMenuItem(title: "当前模型：正在识别…", action: nil, keyEquivalent: "")
    private let providerStatusItem = NSMenuItem(title: "正在读取当前配置…", action: nil, keyEquivalent: "")
    private let providerSectionSeparatorItem = NSMenuItem.separator()
    private let openAIQuotaTitleItem = NSMenuItem(title: "OpenAI", action: nil, keyEquivalent: "")
    private let fiveHourItem = NSMenuItem(title: "5 小时：等待数据", action: nil, keyEquivalent: "")
    private let weekItem = NSMenuItem(title: "一周：等待数据", action: nil, keyEquivalent: "")
    private let resetCreditsItem = NSMenuItem(title: "可用重置：等待数据", action: nil, keyEquivalent: "")
    private let bailianQuotaTitleItem = NSMenuItem(title: "百炼 Token Plan", action: nil, keyEquivalent: "")
    private let bailianWeekItem = NSMenuItem(title: "一周：等待数据", action: nil, keyEquivalent: "")
    private let deepSeekSectionSeparatorItem = NSMenuItem.separator()
    private let deepSeekQuotaTitleItem = NSMenuItem(title: "DeepSeek 官方", action: nil, keyEquivalent: "")
    private let deepSeekBalanceItem = NSMenuItem(title: "余额：等待数据", action: nil, keyEquivalent: "")
    private let openAIUpdateItem = NSMenuItem(title: "OpenAI：读取中…", action: nil, keyEquivalent: "")
    private let bailianSectionSeparatorItem = NSMenuItem.separator()
    private let bailianUpdateItem = NSMenuItem(title: "百炼：读取中…", action: nil, keyEquivalent: "")
    private let deepSeekUpdateItem = NSMenuItem(title: "DeepSeek：读取中…", action: nil, keyEquivalent: "")
    private let usageItem = NSMenuItem(title: "打开 Codex 用量页面", action: nil, keyEquivalent: "")
    private let waterReminderRootItem = NSMenuItem(title: "喝水提醒：已关闭", action: nil, keyEquivalent: "")
    private let waterReminderToggleItem = NSMenuItem(title: "开启喝水提醒", action: nil, keyEquivalent: "")
    private let nextWaterReminderItem = NSMenuItem(title: "下次提醒：—", action: nil, keyEquivalent: "")
    private let hydrationOverlay = HydrationOverlayController()
    private var latestSnapshot: RateLimitSnapshot?
    private var latestBailianSnapshot: BailianPlanSnapshot?
    private var latestDeepSeekSnapshot: DeepSeekBalanceSnapshot?
    private var currentProvider: CodexProvider?
    private var availableProviders: Set<CodexProvider> = [.official]
    private var providerItems: [CodexProvider: NSMenuItem] = [:]
    private var openAIHasError = false
    private var bailianHasError = false
    private var deepSeekHasError = false
    private var waterReminderIntervalItems: [NSMenuItem] = []
    private var waterReminderTimer: Timer?
    private var nextWaterReminderDate: Date?
    private var waterReminderEnabled = false
    private var waterReminderIntervalMinutes = 60
    private var providerSwitchInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loadWaterReminderPreferences()
        configureStatusItem()
        configureMenu()

        client.onSnapshot = { [weak self] snapshot, isPartial in
            guard let self else { return }
            let merged: RateLimitSnapshot
            if isPartial {
                merged = RateLimitSnapshot(
                    fiveHour: snapshot.fiveHour ?? self.latestSnapshot?.fiveHour,
                    weekly: snapshot.weekly ?? self.latestSnapshot?.weekly,
                    resetCreditsCount: snapshot.resetCreditsCount ?? self.latestSnapshot?.resetCreditsCount
                )
            } else {
                merged = snapshot
            }
            self.latestSnapshot = merged
            self.renderCurrentQuota()
            if !isPartial { self.autoUpdater.checkIfNeeded() }
        }
        client.onStateChange = { [weak self] state in self?.render(state) }
        bailianClient.onSnapshot = { [weak self] snapshot in
            self?.latestBailianSnapshot = snapshot
            self?.renderCurrentQuota()
        }
        bailianClient.onStateChange = { [weak self] state in self?.render(state) }
        deepSeekClient.onSnapshot = { [weak self] snapshot in
            self?.latestDeepSeekSnapshot = snapshot
            self?.renderCurrentQuota()
        }
        deepSeekClient.onStateChange = { [weak self] state in self?.render(state) }
        client.start()
        bailianClient.start()
        deepSeekClient.start()
        refreshCurrentProvider()
        if waterReminderEnabled {
            resetWaterReminderSchedule()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        waterReminderTimer?.invalidate()
        hydrationOverlay.stop()
        autoUpdater.stop()
        client.stop()
        bailianClient.stop()
        deepSeekClient.stop()
    }

    private func configureStatusItem() {
        statusItem.autosaveName = "io.github.sekiyaoshen-blip.codexquotabar.status-item"
        statusItem.isVisible = true
        guard let button = statusItem.button else { return }
        button.title = "…·↻—"
        button.toolTip = "Codex 模型与剩余额度"
    }

    private func configureMenu() {
        let menu = NSMenu()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let title = NSMenuItem(title: "Codex 额度 · v\(version)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        configureProviderMenu()
        menu.addItem(providerRootItem)
        menu.addItem(providerSectionSeparatorItem)

        [openAIQuotaTitleItem, fiveHourItem, weekItem, resetCreditsItem,
         bailianQuotaTitleItem, bailianWeekItem,
         deepSeekQuotaTitleItem, deepSeekBalanceItem,
         openAIUpdateItem, bailianUpdateItem, deepSeekUpdateItem].forEach { $0.isEnabled = false }
        menu.addItem(openAIQuotaTitleItem)
        menu.addItem(fiveHourItem)
        menu.addItem(weekItem)
        menu.addItem(resetCreditsItem)
        menu.addItem(openAIUpdateItem)
        menu.addItem(bailianSectionSeparatorItem)
        menu.addItem(bailianQuotaTitleItem)
        menu.addItem(bailianWeekItem)
        menu.addItem(bailianUpdateItem)
        menu.addItem(deepSeekSectionSeparatorItem)
        menu.addItem(deepSeekQuotaTitleItem)
        menu.addItem(deepSeekBalanceItem)
        menu.addItem(deepSeekUpdateItem)
        menu.addItem(.separator())

        usageItem.action = #selector(openUsagePage)
        usageItem.target = self
        menu.addItem(usageItem)

        let tiboItem = NSMenuItem(title: "打开 Tibo 的 X 主页", action: #selector(openTiboProfile), keyEquivalent: "")
        tiboItem.target = self
        menu.addItem(tiboItem)

        menu.addItem(.separator())

        configureWaterReminderMenu()
        menu.addItem(waterReminderRootItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateProviderMenu()
        updateQuotaVisibility()
    }

    private func configureProviderMenu() {
        let submenu = NSMenu(title: "模型供应商")
        for title in ["同时切换近 7 日未归档会话", "将重启 Codex，中断运行中的任务"] {
            let hint = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            hint.isEnabled = false
            submenu.addItem(hint)
        }
        submenu.addItem(.separator())
        providerItems = Dictionary(uniqueKeysWithValues: CodexProvider.allCases.enumerated().map { index, provider in
            let item = NSMenuItem(
                title: provider.displayName,
                action: #selector(selectProvider(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            submenu.addItem(item)
            return (provider, item)
        })
        providerStatusItem.isEnabled = false
        submenu.addItem(providerStatusItem)
        providerRootItem.submenu = submenu
    }

    private func configureWaterReminderMenu() {
        let submenu = NSMenu(title: "喝水提醒")
        waterReminderToggleItem.target = self
        waterReminderToggleItem.action = #selector(toggleWaterReminder)
        submenu.addItem(waterReminderToggleItem)
        submenu.addItem(.separator())

        let intervalTitle = NSMenuItem(title: "提醒间隔", action: nil, keyEquivalent: "")
        intervalTitle.isEnabled = false
        submenu.addItem(intervalTitle)
        waterReminderIntervalItems = [60, 90, 120].map { minutes in
            let item = NSMenuItem(
                title: "每 \(minutes) 分钟",
                action: #selector(selectWaterReminderInterval(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = minutes
            submenu.addItem(item)
            return item
        }
        submenu.addItem(.separator())
        nextWaterReminderItem.isEnabled = false
        submenu.addItem(nextWaterReminderItem)
        waterReminderRootItem.submenu = submenu
        updateWaterReminderMenu()
    }

    private func renderCurrentQuota() {
        updateQuotaVisibility()
        if let latestSnapshot { render(latestSnapshot) }
        if let latestBailianSnapshot { render(latestBailianSnapshot) }
        if let latestDeepSeekSnapshot { render(latestDeepSeekSnapshot) }
        updateStatusTitle()
    }

    private func updateQuotaVisibility() {
        let showBailian = availableProviders.contains(.aliyun) || latestBailianSnapshot != nil
        let showDeepSeek = currentProvider == .deepseek || latestDeepSeekSnapshot != nil
        fiveHourItem.isHidden = latestSnapshot?.fiveHour == nil
        weekItem.isHidden = latestSnapshot?.weekly == nil
        openAIUpdateItem.isHidden = latestSnapshot != nil && !openAIHasError
        bailianSectionSeparatorItem.isHidden = !showBailian
        bailianQuotaTitleItem.isHidden = !showBailian
        bailianWeekItem.isHidden = !showBailian
        bailianUpdateItem.isHidden = !showBailian || (latestBailianSnapshot != nil && !bailianHasError)
        deepSeekSectionSeparatorItem.isHidden = !showDeepSeek
        deepSeekQuotaTitleItem.isHidden = !showDeepSeek
        deepSeekBalanceItem.isHidden = !showDeepSeek
        deepSeekUpdateItem.isHidden = !showDeepSeek
            || (latestDeepSeekSnapshot != nil && !deepSeekHasError)
        updateUsageItem()
    }

    private func updateUsageItem() {
        guard let provider = currentProvider else {
            usageItem.title = "打开 Codex 用量页面"
            usageItem.isEnabled = false
            return
        }
        usageItem.title = provider.usagePageTitle
        usageItem.isEnabled = provider.usagePageURL != nil
    }

    private func updateStatusTitle() {
        switch currentProvider {
        case .aliyun:
            if let snapshot = latestBailianSnapshot {
                statusItem.button?.title = "\(percentText(snapshot.remainingPercent))%"
            } else {
                statusItem.button?.title = bailianHasError ? "⚠︎" : "…"
            }
        case .deepseek:
            if let snapshot = latestDeepSeekSnapshot {
                statusItem.button?.title = snapshot.displayText
            } else {
                statusItem.button?.title = deepSeekHasError ? "⚠︎" : "…"
            }
        case .apiopencc:
            statusItem.button?.title = "apiopencc"
        case .felixxxxx:
            statusItem.button?.title = "Felixxxxx"
        case .official, nil:
            let openAIText: String
            if let snapshot = latestSnapshot {
                let percentages = [snapshot.fiveHour, snapshot.weekly]
                    .compactMap { $0?.remainingPercent }
                    .map(String.init)
                openAIText = percentages.isEmpty ? "—" : "\(percentages.joined(separator: "/"))%"
            } else {
                openAIText = openAIHasError ? "⚠︎" : "…"
            }
            let resets = latestSnapshot?.resetCreditsCount.map(String.init) ?? "—"
            statusItem.button?.title = "\(openAIText)·↻\(resets)"
        }
    }

    private func render(_ snapshot: RateLimitSnapshot) {
        updateQuotaVisibility()
        fiveHourItem.title = detailTitle(label: "5 小时", window: snapshot.fiveHour)
        weekItem.title = detailTitle(label: "一周", window: snapshot.weekly)
        if let count = snapshot.resetCreditsCount {
            resetCreditsItem.title = "可用重置：\(count)"
        } else {
            resetCreditsItem.title = "可用重置：—"
        }
        openAIHasError = false
        updateQuotaVisibility()
        updateStatusTitle()
    }

    private func render(_ snapshot: BailianPlanSnapshot) {
        let remaining = percentText(snapshot.remainingPercent)
        bailianWeekItem.title = "一周：\(remaining)% · 重置 \(remainingText(until: snapshot.resetsAt))"
        bailianHasError = false
        updateQuotaVisibility()
        updateStatusTitle()
    }

    private func render(_ snapshot: DeepSeekBalanceSnapshot) {
        deepSeekBalanceItem.title = "余额：\(snapshot.displayText)"
        deepSeekHasError = false
        updateQuotaVisibility()
        updateStatusTitle()
    }

    private func render(_ state: CodexRateLimitClient.State) {
        switch state {
        case .starting:
            openAIUpdateItem.title = "OpenAI：读取中…"
        case .ready:
            break
        case .error(let message):
            openAIHasError = true
            openAIUpdateItem.title = "OpenAI：\(message)"
        }
        updateQuotaVisibility()
        updateStatusTitle()
    }

    private func render(_ state: BailianPlanUsageClient.State) {
        switch state {
        case .starting:
            bailianUpdateItem.title = "百炼：读取中…"
        case .ready:
            break
        case .error(let message):
            bailianHasError = true
            bailianUpdateItem.title = "百炼：\(concise(message))"
        }
        updateQuotaVisibility()
        updateStatusTitle()
    }

    private func render(_ state: DeepSeekBalanceClient.State) {
        switch state {
        case .starting:
            deepSeekUpdateItem.title = "DeepSeek：读取中…"
        case .ready:
            break
        case .error(let message):
            deepSeekHasError = true
            deepSeekUpdateItem.title = "DeepSeek：\(concise(message))"
        }
        updateQuotaVisibility()
        updateStatusTitle()
    }

    private func percentText(_ value: Double) -> String {
        if value >= 99.95 || value.rounded() == value { return String(format: "%.0f", value) }
        return String(format: "%.1f", value)
    }

    private func concise(_ message: String, limit: Int = 90) -> String {
        let normalized = message
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "操作失败"
        return normalized.count <= limit ? normalized : String(normalized.prefix(limit)) + "…"
    }

    private func detailTitle(label: String, window: RateLimitWindow?) -> String {
        guard let window else { return "\(label)：暂无数据" }
        return "\(label)：\(window.remainingPercent)% · 重置 \(remainingText(until: window.resetsAt))"
    }

    private func remainingText(until date: Date?) -> String {
        guard let date else { return "—" }
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return "即将重置" }
        if interval < 24 * 3_600 {
            let totalMinutes = max(1, Int(interval / 60))
            return "\(totalMinutes / 60) 小时 \(totalMinutes % 60) 分"
        }

        let hours = Int(ceil(interval / 3_600))
        let days = hours / 24
        let remainingHours = hours % 24
        if remainingHours == 0 { return "\(days) 天" }
        return "\(days) 天 \(remainingHours) 小时"
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

    private func loadWaterReminderPreferences() {
        let defaults = UserDefaults.standard
        waterReminderEnabled = defaults.bool(forKey: WaterReminderDefaults.enabled)
        let savedInterval = defaults.integer(forKey: WaterReminderDefaults.intervalMinutes)
        waterReminderIntervalMinutes = [60, 90, 120].contains(savedInterval) ? savedInterval : 60
    }

    private func resetWaterReminderSchedule() {
        nextWaterReminderDate = nextReminderBoundary(after: Date())
        scheduleWaterReminderTimer()
        updateWaterReminderMenu()
    }

    private func scheduleWaterReminderTimer() {
        waterReminderTimer?.invalidate()
        waterReminderTimer = nil
        guard waterReminderEnabled, let nextWaterReminderDate else { return }

        let timer = Timer(
            fireAt: nextWaterReminderDate,
            interval: 0,
            target: self,
            selector: #selector(waterReminderTimerFired),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .common)
        waterReminderTimer = timer
    }

    private func nextReminderBoundary(after date: Date) -> Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        components.second = 0
        components.nanosecond = 0
        if waterReminderIntervalMinutes == 90, (components.minute ?? 0) < 30 {
            components.minute = 30
            return calendar.date(from: components) ?? date.addingTimeInterval(30 * 60)
        }

        components.minute = 0
        let hourStart = calendar.date(from: components) ?? date
        return calendar.date(byAdding: .hour, value: 1, to: hourStart)
            ?? date.addingTimeInterval(30 * 60)
    }

    private func updateWaterReminderMenu() {
        waterReminderRootItem.title = waterReminderEnabled ? "喝水提醒：已开启" : "喝水提醒：已关闭"
        waterReminderToggleItem.title = waterReminderEnabled ? "关闭喝水提醒" : "开启喝水提醒"
        waterReminderToggleItem.state = .off
        waterReminderIntervalItems.forEach {
            $0.state = $0.tag == waterReminderIntervalMinutes ? .on : .off
        }
        if waterReminderEnabled, let nextWaterReminderDate {
            let text = Calendar.current.isDateInToday(nextWaterReminderDate)
                ? timeFormatter.string(from: nextWaterReminderDate)
                : dateFormatter.string(from: nextWaterReminderDate)
            nextWaterReminderItem.title = "下次提醒：\(text)"
        } else {
            nextWaterReminderItem.title = "下次提醒：—"
        }
    }

    @objc private func toggleWaterReminder() {
        waterReminderEnabled.toggle()
        UserDefaults.standard.set(waterReminderEnabled, forKey: WaterReminderDefaults.enabled)
        if waterReminderEnabled {
            resetWaterReminderSchedule()
        } else {
            waterReminderTimer?.invalidate()
            waterReminderTimer = nil
            nextWaterReminderDate = nil
            hydrationOverlay.stop()
            updateWaterReminderMenu()
        }
    }

    @objc private func selectWaterReminderInterval(_ sender: NSMenuItem) {
        guard [60, 90, 120].contains(sender.tag) else { return }
        waterReminderIntervalMinutes = sender.tag
        UserDefaults.standard.set(sender.tag, forKey: WaterReminderDefaults.intervalMinutes)
        if waterReminderEnabled {
            resetWaterReminderSchedule()
        } else {
            updateWaterReminderMenu()
        }
    }

    @objc private func waterReminderTimerFired() {
        waterReminderTimer = nil
        guard waterReminderEnabled else { return }

        let now = Date()
        let scheduledDate = nextWaterReminderDate ?? now
        let interval = TimeInterval(waterReminderIntervalMinutes * 60)
        var followingDate = scheduledDate.addingTimeInterval(interval)
        while followingDate <= now {
            followingDate = followingDate.addingTimeInterval(interval)
        }
        nextWaterReminderDate = followingDate
        scheduleWaterReminderTimer()
        updateWaterReminderMenu()

        // If the Mac was asleep and missed the boundary, skip the stale reminder
        // instead of showing it at a non-:00/:30 time after wake.
        guard now.timeIntervalSince(scheduledDate) <= 60 else { return }

        hydrationOverlay.show(duration: 30) { [weak self] in
            self?.updateWaterReminderMenu()
        }
    }

    private func refreshCurrentProvider() {
        providerSwitcher.refresh { [weak self] result in
            guard let self else { return }
            guard !self.providerSwitchInProgress else { return }
            switch result {
            case .success(let status):
                self.currentProvider = status.current
                self.availableProviders = status.available
                self.deepSeekClient.setActive(status.current == .deepseek)
                self.providerStatusItem.isHidden = true
            case .failure(let error):
                self.providerStatusItem.title = self.concise(error.localizedDescription)
                self.providerStatusItem.isHidden = false
            }
            self.updateProviderMenu()
            self.renderCurrentQuota()
        }
    }

    private func updateProviderMenu(isSwitching: Bool = false) {
        let title = currentProvider?.menuName ?? "无法识别"
        providerRootItem.title = "当前模型：\(title)"
        let showProviderSwitcher = availableProviders.count > 1
        providerRootItem.isHidden = !showProviderSwitcher
        providerSectionSeparatorItem.isHidden = !showProviderSwitcher
        providerItems.forEach { provider, item in
            item.state = provider == currentProvider ? .on : .off
            item.isEnabled = !isSwitching && !providerSwitchInProgress
            item.isHidden = !availableProviders.contains(provider)
        }
    }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard CodexProvider.allCases.indices.contains(sender.tag) else { return }
        guard !providerSwitchInProgress else { return }
        providerSwitchInProgress = true
        let provider = CodexProvider.allCases[sender.tag]
        providerStatusItem.title = "正在退出 Codex 并切换近 7 日会话…"
        providerStatusItem.isHidden = false
        updateProviderMenu(isSwitching: true)
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        let applicationURL = applications.first?.bundleURL
        applications.forEach { $0.terminate() }
        waitForCodexExit(deadline: Date().addingTimeInterval(20)) { [weak self] exited in
            guard let self else { return }
            guard exited else {
                self.providerSwitchInProgress = false
                self.providerStatusItem.title = "Codex 尚未退出，切换已取消"
                self.updateProviderMenu()
                return
            }
            self.providerSwitcher.activate(provider) { [weak self] result in
                guard let self else { return }
                self.providerSwitchInProgress = false
                switch result {
                case .success(let output):
                    self.currentProvider = provider
                    self.availableProviders.insert(provider)
                    self.deepSeekClient.setActive(provider == .deepseek)
                    let data = output.data(using: .utf8) ?? Data()
                    let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    let count = (info?["eligible"] as? Int).map(String.init) ?? "—"
                    self.providerStatusItem.title = "近 7 日 \(count) 个会话已切换"
                    self.providerStatusItem.isHidden = false
                    self.updateProviderMenu()
                    self.renderCurrentQuota()
                    if provider == .aliyun { self.bailianClient.refresh() }
                case .failure(let error):
                    self.providerStatusItem.title = "切换失败：\(self.concise(error.localizedDescription, limit: 70))"
                    self.providerStatusItem.isHidden = false
                    self.updateProviderMenu()
                }
                if let applicationURL { self.reopenCodex(at: applicationURL) }
            }
        }
    }

    private func waitForCodexExit(deadline: Date, completion: @escaping (Bool) -> Void) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty {
            completion(true)
            return
        }
        guard Date() < deadline else { completion(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.waitForCodexExit(deadline: deadline, completion: completion)
        }
    }

    private func reopenCodex(at applicationURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                if error != nil {
                    self?.providerStatusItem.title = "请手动重开 Codex"
                    self?.providerStatusItem.isHidden = false
                }
            }
        }
    }

    @objc private func openUsagePage() {
        guard let url = currentProvider?.usagePageURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openTiboProfile() {
        if let url = URL(string: "https://x.com/thsottiaux") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

enum CodexQuotaBarMain {
    static func runSelfTest() {
        let authError = """
        (node:123) [UNDICI-EHPA] Warning: experimental
        {
          "error": {
            "code": 3,
            "message": "Console session is not logged in or has expired."
          }
        }
        """
        guard BailianPlanUsageClient.readableErrorMessage(from: authError) == "登录已过期，请重新登录",
              BailianPlanUsageClient.readableErrorMessage(
                from: #"{"error":{"code":9,"message":"Service unavailable"}}"#
              ) == "Service unavailable",
              BailianPlanUsageClient.needsProfileFallback(stderr: authError),
              !BailianPlanUsageClient.needsProfileFallback(
                stderr: #"{"error":{"code":9,"message":"Service unavailable"}}"#
              ) else {
            fputs("SELF_TEST_BAILIAN_ERROR_PARSING_FAILED\n", stderr)
            exit(1)
        }

        let balanceFixture = Data(#"""
        {"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"1.50","granted_balance":"0.00","topped_up_balance":"1.50"},{"currency":"CNY","total_balance":"88.57","granted_balance":"0.00","topped_up_balance":"88.57"}]}
        """#.utf8)
        guard let balance = DeepSeekBalanceClient.parseBalance(balanceFixture),
              balance.currency == "CNY",
              balance.displayText == "¥88.57",
              DeepSeekBalanceClient.parseBalance(Data(#"{"balance_infos":[]}"#.utf8)) == nil,
              CodexProvider.allCases.allSatisfy({ $0.usagePageURL != nil }) else {
            fputs("SELF_TEST_DEEPSEEK_BALANCE_FAILED\n", stderr)
            exit(1)
        }

        let client = CodexRateLimitClient()
        var finished = false
        client.onSnapshot = { snapshot, _ in
            guard snapshot.fiveHour != nil || snapshot.weekly != nil else { return }
            let primary = snapshot.fiveHour.map { "5h_remaining=\($0.remainingPercent)%" } ?? "5h_remaining=none"
            let secondary = snapshot.weekly.map { "week_remaining=\($0.remainingPercent)%" } ?? "week_remaining=none"
            let resets = snapshot.resetCreditsCount.map(String.init) ?? "none"
            print("SELF_TEST_OK \(primary) \(secondary) reset_credits=\(resets)")
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
        if CommandLine.arguments.contains("--bailian-usage-test") {
            runBailianUsageTest()
            return
        }
        if CommandLine.arguments.contains("--deepseek-balance-test") {
            runDeepSeekBalanceTest()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    /// Real end-to-end check of the DeepSeek balance path (uses the local vault key).
    static func runDeepSeekBalanceTest() {
        let client = DeepSeekBalanceClient()
        var finished = false
        client.onSnapshot = { snapshot in
            print("DEEPSEEK_BALANCE_OK \(snapshot.displayText)")
            finished = true
            CFRunLoopStop(CFRunLoopGetMain())
        }
        client.onStateChange = { state in
            if case .error(let message) = state {
                fputs("DEEPSEEK_BALANCE_ERROR \(message)\n", stderr)
                finished = false
                CFRunLoopStop(CFRunLoopGetMain())
            }
        }
        client.start()
        client.setActive(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            if !finished {
                fputs("DEEPSEEK_BALANCE_TIMEOUT\n", stderr)
                CFRunLoopStop(CFRunLoopGetMain())
            }
        }
        CFRunLoopRun()
        client.stop()
        exit(finished ? 0 : 1)
    }

    /// Real end-to-end check of the Bailian Token Plan usage path (uses the `bl` CLI).
    static func runBailianUsageTest() {
        let client = BailianPlanUsageClient()
        var finished = false
        client.onSnapshot = { snapshot in
            print("BAILIAN_USAGE_OK remaining=\(String(format: "%.2f", snapshot.remainingPercent))%")
            finished = true
            CFRunLoopStop(CFRunLoopGetMain())
        }
        client.onStateChange = { state in
            if case .error(let message) = state {
                fputs("BAILIAN_USAGE_ERROR \(message)\n", stderr)
                finished = false
                CFRunLoopStop(CFRunLoopGetMain())
            }
        }
        client.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
            if !finished {
                fputs("BAILIAN_USAGE_TIMEOUT\n", stderr)
                CFRunLoopStop(CFRunLoopGetMain())
            }
        }
        CFRunLoopRun()
        client.stop()
        exit(finished ? 0 : 1)
    }
}

CodexQuotaBarMain.main()
