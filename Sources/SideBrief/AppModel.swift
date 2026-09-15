import AppKit
import SwiftUI
import Network
import BriefCore

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = AppSettings()
    @Published var edition: BriefEdition?
    @Published var isRefreshing = false
    @Published var phaseText = "每天一点，值得关注的进展。"
    @Published var errorMessage: String?
    @Published var canRetryGeneration = false
    @Published var isOnline = true
    @Published var connectionStatus = "检测本机 Codex 后即可开始"
    @Published var toast: String?
    @Published var isDemo = false
    var onOpenSettings: (() -> Void)?
    var onCloseSettings: (() -> Void)?
    var onCollapse: (() -> Void)?
    private let store: BriefStore?
    private let service = CodexService()
    private let monitor = NWPathMonitor()
    private var retry = RetryState()
    private var task: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var toastTask: Task<Void, Never>?
    private var wasOffline = false
    private var connectionCheckID = UUID()

    init(directory: URL, demo: Bool = false) {
        isDemo = demo
        do {
            let store = try BriefStore(directory: directory)
            self.store = store
            do { settings = try store.loadSettings() }
            catch { errorMessage = "设置文件无法读取，请打开设置检查并重新保存。\(error.localizedDescription)" }
            do { edition = try store.loadLatest() }
            catch { errorMessage = "上期简报暂时无法读取，可重新生成。" }
            retry = store.loadRetry()
        } catch {
            store = nil
            errorMessage = "无法打开数据目录：\(error.localizedDescription)"
        }
        if demo { edition = DemoContent.edition; phaseText = "演示模式 · 内容仅用于体验界面" }
    }

    var canRefresh: Bool { !isRefreshing && isOnline && store != nil && !isDemo }
    var lastUpdatedText: String {
        guard let edition else { return "还没有生成简报" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = settings.timeZone
        formatter.dateFormat = "MM.dd HH:mm"
        let prefix = edition.dayKey == DailySchedule.dayKey(for: Date(), timeZone: settings.timeZone) ? "更新于 " : "上一期 "
        return prefix + formatter.string(from: edition.createdAt)
    }
    var scheduleText: String {
        guard settings.automaticUpdates else { return "自动更新已关闭 · 可手动更新" }
        let zone = settings.timeZoneID == "Asia/Shanghai" ? "北京时间" : settings.timeZoneID
        return String(format: "每天 %02d:%02d · %@", settings.hour, settings.minute, zone)
    }

    func start() {
        guard !isDemo else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isOnline = connected
                if !connected { self.wasOffline = true }
                else if self.wasOffline {
                    self.wasOffline = false
                    self.resetRetryDelay()
                    self.maybeRefresh()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.sidebrief.network"))
        timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.maybeRefresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.maybeRefresh() }
        }
        checkCodex()
        maybeRefresh()
    }

    func stop() {
        task?.cancel(); connectionTask?.cancel(); toastTask?.cancel(); monitor.cancel(); timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
    func openSettings() { onOpenSettings?() }
    func closeSettings() { onCloseSettings?() }
    func collapse() { onCollapse?() }

    @discardableResult
    func saveSettings(_ value: AppSettings) -> Bool {
        canRetryGeneration = false
        guard !isRefreshing else { errorMessage = "请等待当前更新结束，或先取消更新再保存设置。"; return false }
        do {
            guard let store else { throw BriefError.invalidSettings("数据目录不可写，暂时无法保存。") }
            var normalized = value
            normalized.codexPath = value.codexPath.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.interests = value.interests.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.timeZoneID = value.timeZoneID.trimmingCharacters(in: .whitespacesAndNewlines)
            try store.saveSettings(normalized)
            settings = normalized; errorMessage = nil
            resetRetryDelay()
            connectionTask?.cancel(); connectionTask = nil
            checkCodex(); showToast("设置已保存，下次更新时生效")
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func checkCodex() {
        guard connectionTask == nil, !isDemo else { return }
        connectionStatus = "正在检测 Codex…"
        let path = settings.codexPath
        let checkID = UUID(); connectionCheckID = checkID
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.connectionCheckID == checkID { self.connectionTask = nil } }
            do {
                let connection = try await service.checkConnection(configuredPath: path)
                try Task.checkCancellation()
                if self.connectionCheckID == checkID { self.connectionStatus = connection.message }
            } catch is CancellationError { }
            catch { if self.connectionCheckID == checkID { self.connectionStatus = error.localizedDescription } }
        }
    }

    private func resetRetryDelay() {
        guard let store else { return }
        do {
            let lock = try GenerationLock(directory: store.directory)
            defer { lock.release() }
            retry = store.loadRetry()
            retry.nextAttempt = nil; retry.failures = 0
            try store.saveRetry(retry)
        } catch {
            // An active generation owns the counter; never write an older in-memory copy.
            retry = store.loadRetry()
        }
    }

    func startSetup() {
        guard canRefresh else { return }
        var value = settings; value.hasCompletedSetup = true
        do { try store?.saveSettings(value); settings = value; refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func refresh() {
        if !settings.hasCompletedSetup { startSetup(); return }
        beginRefresh(manual: true)
    }
    private func maybeRefresh() {
        guard isOnline, !isRefreshing, !isDemo,
              DailySchedule.shouldRefresh(now: Date(), settings: settings, latest: edition, retry: retry) else { return }
        beginRefresh(manual: false)
    }

    private func beginRefresh(manual: Bool) {
        guard !isRefreshing, !isDemo, let store else { return }
        guard isOnline else { if manual { errorMessage = "当前离线。已保存的简报仍可阅读，联网后会补更。" }; return }
        isRefreshing = true; errorMessage = nil; canRetryGeneration = false; phaseText = "正在获取公开资讯…"
        let configuration = settings
        let requestedAt = Date()
        let requestedDay = DailySchedule.dayKey(for: requestedAt, timeZone: configuration.timeZone)
        task = Task { [weak self] in
            guard let self else { return }
            var generationLock: GenerationLock?
            defer { generationLock?.release(); self.isRefreshing = false; self.task = nil }
            do {
                try configuration.validate()
                generationLock = try GenerationLock(directory: store.directory)
                self.retry = store.loadRetry()
                if !manual {
                    let storedEdition = try store.loadLatest()
                    if !DailySchedule.shouldRefresh(now: requestedAt, settings: configuration, latest: storedEdition, retry: self.retry) {
                        self.edition = storedEdition ?? self.edition
                        self.phaseText = "已同步本机最新简报"
                        return
                    }
                }
                // Persist while owning the lock; another instance must not overwrite an
                // in-flight attempt count, and a crash must not create a tight retry loop.
                self.retry.nextAttempt = Date().addingTimeInterval(300)
                try store.saveRetry(self.retry)
                let batch = try await FeedService().fetch(sources: configuration.sources)
                try Task.checkCancellation()
                self.phaseText = "Codex 正在筛选 \(batch.articles.count) 条资讯…"
                self.retry.recordGeneration(now: requestedAt, timeZone: configuration.timeZone)
                try store.saveRetry(self.retry)
                let generated = try await service.generate(articles: batch.articles, settings: configuration, previous: (try? store.loadHistory()) ?? [])
                try Task.checkCancellation()
                let now = Date()
                let result = BriefEdition(dayKey: requestedDay, createdAt: now, timeZoneID: configuration.timeZoneID, headline: generated.headline, items: generated.items, sources: batch.reports)
                self.edition = result
                do { try store.saveEdition(result) }
                catch {
                    self.errorMessage = "精选已生成，但本地保存失败。当前窗口仍可阅读，请检查数据目录权限。"
                    self.retry.generationsToday = max(self.retry.generationsToday, 3)
                    try? store.saveRetry(self.retry)
                    self.phaseText = "已生成 · 保存需要处理"
                    return
                }
                self.retry.nextAttempt = nil; self.retry.failures = 0; try? store.saveRetry(self.retry)
                self.phaseText = "今天的精选已备好"
                self.connectionStatus = "本机 Codex · 已连接"
            } catch is CancellationError {
                self.phaseText = "已取消更新，保留上一期"
                self.retry.nextAttempt = Date().addingTimeInterval(3600)
                if generationLock != nil { try? store.saveRetry(self.retry) }
            } catch {
                self.canRetryGeneration = true
                self.errorMessage = error.localizedDescription
                self.phaseText = "更新暂未完成"
                self.retry.recordFailure()
                if generationLock != nil { try? store.saveRetry(self.retry) }
                if !self.retry.permitsAutomaticGeneration(now: Date(), timeZone: configuration.timeZone) {
                    self.errorMessage = (self.errorMessage ?? "更新失败") + " 今日自动生成次数已达上限，可在排查后手动重试。"
                }
            }
        }
    }

    func cancelRefresh() { task?.cancel(); phaseText = "正在取消…" }
    func openArticle(_ item: BriefItem) {
        canRetryGeneration = false
        guard URLSafety.isWeb(item.url) else { errorMessage = "这个链接无法安全打开。"; return }
        if !NSWorkspace.shared.open(item.url) { errorMessage = "浏览器未能打开链接，请稍后重试。" }
    }
    func copyResearch(_ item: BriefItem) {
        canRetryGeneration = false
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(item.researchPrompt, forType: .string) { showToast("研究指令已复制，粘贴到 Codex 即可") }
        else { errorMessage = "复制未完成，请重试。" }
    }
    private func showToast(_ value: String) {
        toastTask?.cancel(); toast = value
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
