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

    var displayName: String {
        switch self {
        case .official: return "OpenAI 官方"
        case .deepseek: return "DeepSeek 官方"
        case .aliyun: return "阿里百炼 Token Plan"
        }
    }
}

struct BailianPlanSnapshot {
    let usedPercent: Double
    let resetsAt: Date?

    var remainingPercent: Double { max(0, 100 - usedPercent) }
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

    func refresh(completion: @escaping (Result<CodexProvider, Error>) -> Void) {
        run(command: "status") { result in
            completion(result.flatMap { output in
                for rawLine in output.split(separator: "\n") {
                    let line = String(rawLine)
                    guard line.contains("模型 provider"), let colon = line.firstIndex(of: ":") else { continue }
                    let value = line[line.index(after: colon)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let provider = CodexProvider(rawValue: value) { return .success(provider) }
                }
                return .failure(SwitchError.invalidStatus)
            })
        }
    }

    func activate(_ provider: CodexProvider, completion: @escaping (Result<Void, Error>) -> Void) {
        run(command: provider.rawValue) { result in completion(result.map { _ in () }) }
    }

    private func run(command: String, completion: @escaping (Result<String, Error>) -> Void) {
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
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome: URL
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], !configured.isEmpty {
            codexHome = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        }
        let script = codexHome
            .appendingPathComponent("skills/model-switch/scripts/codex-switch.sh")
        return FileManager.default.isReadableFile(atPath: script.path) ? script : nil
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

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = ["usage", "token-plan", "--output", "json"]
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
            requestInFlight = false
            guard process.terminationStatus == 0 else {
                let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                publishState(.error(message.isEmpty ? "百炼额度读取失败" : message))
                return
            }
            guard let object = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any],
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
        } catch {
            requestInFlight = false
            publishState(.error(error.localizedDescription))
        }
    }

    private func publishSnapshot(_ snapshot: BailianPlanSnapshot) {
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
        request.setValue("codex-quota-bar/1.4.1", forHTTPHeaderField: "User-Agent")
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
    private let providerSwitcher = CodexProviderSwitcher()
    private let autoUpdater = AutoUpdater()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let providerRootItem = NSMenuItem(title: "模型供应商：正在识别…", action: nil, keyEquivalent: "")
    private let providerStatusItem = NSMenuItem(title: "正在读取当前配置…", action: nil, keyEquivalent: "")
    private let openAIQuotaTitleItem = NSMenuItem(title: "OpenAI 官方额度", action: nil, keyEquivalent: "")
    private let fiveHourItem = NSMenuItem(title: "5 小时额度：等待数据", action: nil, keyEquivalent: "")
    private let fiveResetItem = NSMenuItem(title: "重置时间：—", action: nil, keyEquivalent: "")
    private let fiveHourSeparator = NSMenuItem.separator()
    private let weekItem = NSMenuItem(title: "一周额度：等待数据", action: nil, keyEquivalent: "")
    private let weekResetItem = NSMenuItem(title: "重置时间：—", action: nil, keyEquivalent: "")
    private let resetCreditsItem = NSMenuItem(title: "剩余重置次数：等待数据", action: nil, keyEquivalent: "")
    private let bailianQuotaTitleItem = NSMenuItem(title: "阿里百炼 Token Plan 额度", action: nil, keyEquivalent: "")
    private let bailianWeekItem = NSMenuItem(title: "百炼一周额度：等待数据", action: nil, keyEquivalent: "")
    private let bailianResetItem = NSMenuItem(title: "重置时间：—", action: nil, keyEquivalent: "")
    private let quotaUnavailableItem = NSMenuItem(title: "DeepSeek 官方暂未提供套餐额度查询", action: nil, keyEquivalent: "")
    private let openAIUpdateItem = NSMenuItem(title: "正在连接 OpenAI…", action: nil, keyEquivalent: "")
    private let bailianUpdateItem = NSMenuItem(title: "正在连接百炼…", action: nil, keyEquivalent: "")
    private let waterReminderRootItem = NSMenuItem(title: "喝水提醒：已关闭", action: nil, keyEquivalent: "")
    private let waterReminderToggleItem = NSMenuItem(title: "开启喝水提醒", action: nil, keyEquivalent: "")
    private let nextWaterReminderItem = NSMenuItem(title: "下次提醒：—", action: nil, keyEquivalent: "")
    private let hydrationOverlay = HydrationOverlayController()
    private var latestSnapshot: RateLimitSnapshot?
    private var latestBailianSnapshot: BailianPlanSnapshot?
    private var lastUpdated: Date?
    private var lastBailianUpdated: Date?
    private var currentProvider: CodexProvider?
    private var providerItems: [CodexProvider: NSMenuItem] = [:]
    private var openAIHasError = false
    private var bailianHasError = false
    private var waterReminderIntervalItems: [NSMenuItem] = []
    private var waterReminderTimer: Timer?
    private var nextWaterReminderDate: Date?
    private var waterReminderEnabled = false
    private var waterReminderIntervalMinutes = 60

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
            self.lastUpdated = Date()
            self.renderCurrentQuota()
            if !isPartial { self.autoUpdater.checkIfNeeded() }
        }
        client.onStateChange = { [weak self] state in self?.render(state) }
        bailianClient.onSnapshot = { [weak self] snapshot in
            self?.latestBailianSnapshot = snapshot
            self?.lastBailianUpdated = Date()
            self?.renderCurrentQuota()
        }
        bailianClient.onStateChange = { [weak self] state in self?.render(state) }
        client.start()
        bailianClient.start()
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
        let title = NSMenuItem(title: "Codex 剩余额度", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        configureProviderMenu()
        menu.addItem(providerRootItem)
        menu.addItem(quotaUnavailableItem)
        menu.addItem(.separator())

        [openAIQuotaTitleItem, fiveHourItem, fiveResetItem, weekItem, weekResetItem, resetCreditsItem,
         bailianQuotaTitleItem, bailianWeekItem, bailianResetItem, quotaUnavailableItem,
         openAIUpdateItem, bailianUpdateItem].forEach { $0.isEnabled = false }
        menu.addItem(openAIQuotaTitleItem)
        menu.addItem(fiveHourItem)
        menu.addItem(fiveResetItem)
        menu.addItem(fiveHourSeparator)
        menu.addItem(weekItem)
        menu.addItem(weekResetItem)
        menu.addItem(resetCreditsItem)
        menu.addItem(openAIUpdateItem)
        menu.addItem(.separator())
        menu.addItem(bailianQuotaTitleItem)
        menu.addItem(bailianWeekItem)
        menu.addItem(bailianResetItem)
        menu.addItem(bailianUpdateItem)
        menu.addItem(.separator())

        let usageItem = NSMenuItem(title: "打开 Codex 用量页面", action: #selector(openUsagePage), keyEquivalent: "")
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
        updateQuotaVisibility()
    }

    private func configureProviderMenu() {
        let submenu = NSMenu(title: "模型供应商")
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
        submenu.addItem(.separator())
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
        updateStatusTitle()
    }

    private func updateQuotaVisibility() {
        fiveHourItem.isHidden = latestSnapshot?.fiveHour == nil
        fiveResetItem.isHidden = fiveHourItem.isHidden
        fiveHourSeparator.isHidden = latestSnapshot?.fiveHour == nil
            || latestSnapshot?.weekly == nil
        weekItem.isHidden = latestSnapshot?.weekly == nil
        weekResetItem.isHidden = weekItem.isHidden
        quotaUnavailableItem.isHidden = currentProvider != .deepseek
    }

    private func updateStatusTitle() {
        let openAIText: String
        if let snapshot = latestSnapshot {
            let percentages = [snapshot.fiveHour, snapshot.weekly]
                .compactMap { $0?.remainingPercent }
                .map(String.init)
            openAIText = percentages.isEmpty ? "O —" : "O \(percentages.joined(separator: "/"))%"
        } else {
            openAIText = openAIHasError ? "O ⚠︎" : "O …"
        }

        let bailianText: String
        if let snapshot = latestBailianSnapshot {
            bailianText = "B \(percentText(snapshot.remainingPercent))%"
        } else {
            bailianText = bailianHasError ? "B ⚠︎" : "B …"
        }
        let resets = latestSnapshot?.resetCreditsCount.map(String.init) ?? "—"
        statusItem.button?.title = "\(openAIText)·\(bailianText)·↻\(resets)"
    }

    private func render(_ snapshot: RateLimitSnapshot) {
        updateQuotaVisibility()
        fiveHourItem.title = detailTitle(label: "5 小时额度", window: snapshot.fiveHour)
        fiveResetItem.title = "重置时间：\(resetText(snapshot.fiveHour?.resetsAt))"
        weekItem.title = detailTitle(label: "一周额度", window: snapshot.weekly)
        weekResetItem.title = "重置时间：\(resetText(snapshot.weekly?.resetsAt))"
        if let count = snapshot.resetCreditsCount {
            resetCreditsItem.title = "剩余重置次数：\(count)"
        } else {
            resetCreditsItem.title = "剩余重置次数：未提供"
        }
        openAIHasError = false
        openAIUpdateItem.title = "刚刚更新 · 每 1 分钟自动刷新"
        updateStatusTitle()
    }

    private func render(_ snapshot: BailianPlanSnapshot) {
        let remaining = percentText(snapshot.remainingPercent)
        let used = percentText(snapshot.usedPercent)
        bailianWeekItem.title = "百炼一周额度：剩余 \(remaining)% · 已用 \(used)%"
        bailianResetItem.title = "重置时间：\(resetText(snapshot.resetsAt))"
        bailianHasError = false
        bailianUpdateItem.title = "刚刚更新 · 每 5 分钟自动刷新"
        updateStatusTitle()
    }

    private func render(_ state: CodexRateLimitClient.State) {
        switch state {
        case .starting:
            openAIUpdateItem.title = "正在读取 OpenAI 额度…"
        case .ready:
            if let lastUpdated {
                openAIUpdateItem.title = "上次更新：\(timeFormatter.string(from: lastUpdated)) · 每 1 分钟"
            } else {
                openAIUpdateItem.title = "正在读取 OpenAI 额度…"
            }
        case .error(let message):
            openAIHasError = true
            openAIUpdateItem.title = message
        }
        updateStatusTitle()
    }

    private func render(_ state: BailianPlanUsageClient.State) {
        switch state {
        case .starting:
            bailianUpdateItem.title = "正在读取百炼 Token Plan 额度…"
        case .ready:
            if let lastBailianUpdated {
                bailianUpdateItem.title = "上次更新：\(timeFormatter.string(from: lastBailianUpdated)) · 每 5 分钟"
            }
        case .error(let message):
            bailianHasError = true
            bailianUpdateItem.title = concise(message)
        }
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
        waterReminderToggleItem.state = waterReminderEnabled ? .on : .off
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
            switch result {
            case .success(let provider):
                self.currentProvider = provider
                self.providerStatusItem.title = "当前：\(provider.displayName)"
            case .failure(let error):
                self.providerStatusItem.title = self.concise(error.localizedDescription)
            }
            self.updateProviderMenu()
            self.renderCurrentQuota()
        }
    }

    private func updateProviderMenu(isSwitching: Bool = false) {
        let title = currentProvider?.displayName ?? "无法识别"
        providerRootItem.title = "模型供应商：\(title)"
        providerItems.forEach { provider, item in
            item.state = provider == currentProvider ? .on : .off
            item.isEnabled = !isSwitching
        }
    }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard CodexProvider.allCases.indices.contains(sender.tag) else { return }
        let provider = CodexProvider.allCases[sender.tag]
        guard provider != currentProvider else {
            providerStatusItem.title = "当前已是 \(provider.displayName)"
            return
        }

        providerStatusItem.title = "正在切换到 \(provider.displayName)…"
        updateProviderMenu(isSwitching: true)
        providerSwitcher.activate(provider) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.currentProvider = provider
                self.providerStatusItem.title = "已切换，正在重启 Codex…"
                self.updateProviderMenu()
                self.renderCurrentQuota()
                if provider == .aliyun { self.bailianClient.refresh() }
                self.restartCodexIfRunning()
            case .failure(let error):
                self.providerStatusItem.title = "切换失败：\(self.concise(error.localizedDescription, limit: 70))"
                self.updateProviderMenu()
            }
        }
    }

    private func restartCodexIfRunning() {
        let bundleIdentifier = "com.openai.codex"
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard !applications.isEmpty else {
            providerStatusItem.title = "切换完成；下次打开 Codex 时生效"
            return
        }
        applications.forEach { $0.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                self?.providerStatusItem.title = "切换完成；请手动重开 Codex"
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
                DispatchQueue.main.async {
                    self?.providerStatusItem.title = error == nil
                        ? "切换完成，Codex 已重启"
                        : "切换完成；请手动重开 Codex"
                }
            }
        }
    }

    @objc private func openUsagePage() {
        if let url = URL(string: "https://chatgpt.com/codex/settings/usage") {
            NSWorkspace.shared.open(url)
        }
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
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

CodexQuotaBarMain.main()
