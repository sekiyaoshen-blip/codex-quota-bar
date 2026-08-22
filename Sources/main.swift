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
            applicationToRestore.activate(options: [.activateIgnoringOtherApps])
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

        let hint = NSTextField(labelWithString: "放松眼睛，喝几口水 · 30 秒后自动恢复")
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

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 30
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
        request.setValue("codex-quota-bar/1.2.2", forHTTPHeaderField: "User-Agent")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let session = makeSession()
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

    private func discoverProxyURL() -> URL? {
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

    private func validProxyURL<S: StringProtocol>(_ value: S) -> URL? {
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum WaterReminderDefaults {
        static let enabled = "waterReminder.enabled"
        static let intervalMinutes = "waterReminder.intervalMinutes"
    }

    private let client = CodexRateLimitClient()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let fiveHourItem = NSMenuItem(title: "5 小时额度：等待数据", action: nil, keyEquivalent: "")
    private let fiveResetItem = NSMenuItem(title: "重置时间：—", action: nil, keyEquivalent: "")
    private let fiveHourSeparator = NSMenuItem.separator()
    private let weekItem = NSMenuItem(title: "一周额度：等待数据", action: nil, keyEquivalent: "")
    private let weekResetItem = NSMenuItem(title: "重置时间：—", action: nil, keyEquivalent: "")
    private let resetCreditsItem = NSMenuItem(title: "剩余重置次数：等待数据", action: nil, keyEquivalent: "")
    private let updateItem = NSMenuItem(title: "正在连接 Codex…", action: nil, keyEquivalent: "")
    private let waterReminderRootItem = NSMenuItem(title: "喝水提醒：已关闭", action: nil, keyEquivalent: "")
    private let waterReminderToggleItem = NSMenuItem(title: "开启喝水提醒", action: nil, keyEquivalent: "")
    private let nextWaterReminderItem = NSMenuItem(title: "下次提醒：—", action: nil, keyEquivalent: "")
    private let hydrationOverlay = HydrationOverlayController()
    private var latestSnapshot: RateLimitSnapshot?
    private var lastUpdated: Date?
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
            self.render(merged)
        }
        client.onStateChange = { [weak self] state in self?.render(state) }
        client.start()
        if waterReminderEnabled {
            resetWaterReminderSchedule()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        waterReminderTimer?.invalidate()
        hydrationOverlay.stop()
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

        [fiveHourItem, fiveResetItem, weekItem, weekResetItem, resetCreditsItem, updateItem].forEach { $0.isEnabled = false }
        menu.addItem(fiveHourItem)
        menu.addItem(fiveResetItem)
        menu.addItem(fiveHourSeparator)
        menu.addItem(weekItem)
        menu.addItem(weekResetItem)
        menu.addItem(.separator())
        menu.addItem(resetCreditsItem)
        menu.addItem(.separator())
        menu.addItem(updateItem)

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

    private func render(_ snapshot: RateLimitSnapshot) {
        var statusParts: [String] = []
        if let fiveHour = snapshot.fiveHour {
            statusParts.append("5h \(fiveHour.remainingPercent)%")
        }
        if let weekly = snapshot.weekly {
            statusParts.append("周 \(weekly.remainingPercent)%")
        }
        let resets = snapshot.resetCreditsCount.map(String.init) ?? "—"
        statusParts.append("↻\(resets)")
        statusItem.button?.title = statusParts.joined(separator: " · ")

        fiveHourItem.isHidden = snapshot.fiveHour == nil
        fiveResetItem.isHidden = snapshot.fiveHour == nil
        fiveHourSeparator.isHidden = snapshot.fiveHour == nil || snapshot.weekly == nil
        weekItem.isHidden = snapshot.weekly == nil
        weekResetItem.isHidden = snapshot.weekly == nil
        fiveHourItem.title = detailTitle(label: "5 小时额度", window: snapshot.fiveHour)
        fiveResetItem.title = "重置时间：\(resetText(snapshot.fiveHour?.resetsAt))"
        weekItem.title = detailTitle(label: "一周额度", window: snapshot.weekly)
        weekResetItem.title = "重置时间：\(resetText(snapshot.weekly?.resetsAt))"
        if let count = snapshot.resetCreditsCount {
            resetCreditsItem.title = "剩余重置次数：\(count)"
        } else {
            resetCreditsItem.title = "剩余重置次数：未提供"
        }
        updateItem.title = "刚刚更新 · 每 1 分钟自动刷新"
    }

    private func render(_ state: CodexRateLimitClient.State) {
        switch state {
        case .starting:
            if latestSnapshot == nil { statusItem.button?.title = "Codex …" }
            updateItem.title = "正在读取 Codex 额度…"
        case .ready:
            if let lastUpdated {
                updateItem.title = "上次更新：\(timeFormatter.string(from: lastUpdated)) · 每 1 分钟"
            } else {
                updateItem.title = "正在读取额度…"
            }
        case .error(let message):
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
