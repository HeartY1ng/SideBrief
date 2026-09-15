import Foundation
import Darwin

public struct RetryState: Codable, Equatable, Sendable {
    public var failures: Int
    public var nextAttempt: Date?
    public var generationDay: String?
    public var generationsToday = 0
    public init(failures: Int = 0, nextAttempt: Date? = nil) { self.failures = failures; self.nextAttempt = nextAttempt }
    public mutating func recordFailure(now: Date = Date()) {
        failures = min(failures + 1, 12)
        let delay: TimeInterval = [300, 900, 1800, 3600][min(failures - 1, 3)]
        nextAttempt = now.addingTimeInterval(delay)
    }
    public mutating func recordGeneration(now: Date = Date(), timeZone: TimeZone) {
        let key = DailySchedule.dayKey(for: now, timeZone: timeZone)
        if generationDay != key { generationDay = key; generationsToday = 0 }
        generationsToday += 1
    }
    public func permitsAutomaticGeneration(now: Date, timeZone: TimeZone) -> Bool {
        generationDay != DailySchedule.dayKey(for: now, timeZone: timeZone) || generationsToday < 3
    }
}

public final class BriefStore {
    public let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    public init(directory: URL) throws {
        self.directory = directory
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("history"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public func loadSettings() throws -> AppSettings {
        let value: AppSettings = try read("settings.json") ?? AppSettings()
        try value.validate()
        return value
    }
    public func saveSettings(_ settings: AppSettings) throws {
        try settings.validate()
        try write(settings, name: "settings.json")
    }
    public func loadLatest() throws -> BriefEdition? {
        let history = try loadHistory().first
        do {
            if let edition: BriefEdition = try read("latest.json") {
                try validate(edition)
                return history.map { $0.createdAt > edition.createdAt ? $0 : edition } ?? edition
            }
        } catch { if let history { return history }; throw error }
        return history
    }
    public func loadHistory() throws -> [BriefEdition] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("history"), includingPropertiesForKeys: nil)
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), data.count < 2_000_000,
                  let edition = try? decoder.decode(BriefEdition.self, from: data), (try? validate(edition)) != nil else { return nil }
            return edition
        }.sorted { $0.createdAt > $1.createdAt }.prefix(30).map { $0 }
    }
    public func saveEdition(_ edition: BriefEdition) throws {
        try validate(edition)
        guard !edition.isDemo else { throw BriefError.invalidDigest("演示数据不会写入正式简报") }
        let timestamp = Int(edition.createdAt.timeIntervalSince1970 * 1000)
        try write(edition, name: "history/\(timestamp)-\(UUID().uuidString).json")
        // History is the durable commit; latest.json is a recoverable convenience copy.
        try? write(edition, name: "latest.json")
        // Retention only touches this application's own history records.
        let folder = directory.appendingPathComponent("history")
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey]))?
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for url in (urls ?? []).dropFirst(30) { try? FileManager.default.removeItem(at: url) }
    }
    public func loadRetry() -> RetryState { (try? read("retry.json")) ?? RetryState() }
    public func saveRetry(_ value: RetryState) throws { try write(value, name: "retry.json") }
    private func read<T: Decodable>(_ name: String) throws -> T? {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count < 2_000_000 else { throw BriefError.invalidDigest("本地文件过大") }
        return try decoder.decode(T.self, from: data)
    }
    private func write<T: Encodable>(_ value: T, name: String) throws {
        let url = directory.appendingPathComponent(name)
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func validate(_ edition: BriefEdition) throws {
        guard edition.dayKey.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              !edition.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, edition.items.count <= 17,
              Set(edition.items.map(\.id)).count == edition.items.count,
              edition.items.allSatisfy({ URLSafety.isWeb($0.url) && !$0.title.isEmpty }) else {
            throw BriefError.invalidDigest("本地简报格式不完整")
        }
    }
}

public final class GenerationLock {
    private var descriptor: Int32 = -1
    public init(directory: URL) throws {
        let url = directory.appendingPathComponent("generation.lock")
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw BriefError.invalidSettings("无法创建本地任务锁，请检查数据目录权限。") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw BriefError.invalidSettings("另一个 SideBrief 正在更新，请稍后重试。")
        }
        descriptor = fd
    }
    public func release() {
        if descriptor >= 0 { flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1 }
    }
    deinit { release() }
}

extension AppSettings {
    public func validate() throws {
        guard (0...23).contains(hour), (0...59).contains(minute) else { throw BriefError.invalidSettings("更新时间需要在 00:00 到 23:59 之间。") }
        guard TimeZone(identifier: timeZoneID) != nil else { throw BriefError.invalidSettings("请输入有效时区，例如 Asia/Shanghai。") }
        guard !interests.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, interests.count <= 1500 else { throw BriefError.invalidSettings("关注方向不能为空，且不能超过 1500 字。") }
        guard codexPath.isEmpty || codexPath.hasPrefix("/") || codexPath.hasPrefix("~/") else { throw BriefError.invalidSettings("Codex 路径需使用完整路径，或留空自动检测。") }
        guard !sources.isEmpty, sources.count <= 30, sources.contains(where: \.enabled) else { throw BriefError.invalidSettings("请启用至少一个资讯源，最多添加 30 个。") }
        guard Set(sources.map(\.id)).count == sources.count else { throw BriefError.invalidSettings("资讯源标识重复，请移除重复来源。") }
        guard sources.allSatisfy({ URLSafety.isFeed($0.url) && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 80 }) else { throw BriefError.invalidSettings("资讯源需要名称和有效的 HTTPS 地址。") }
    }
}
