import Testing
import Foundation
@testable import BriefCore

struct StorageScheduleTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func edition(at now: Date = Date()) -> BriefEdition {
        BriefEdition(dayKey: "2026-09-15", createdAt: now, headline: "测试",
                     items: [.init(id: "a", title: "真实来源", summary: "简要说明", reason: "有用", section: .highlights, tag: "开源", sourceName: "Example", url: URL(string: "https://example.org/a")!)], sources: [])
    }
    @Test func testBeijingScheduleIgnoresMachineTimeZoneAndCatchesUp() {
        var settings = AppSettings(); settings.hasCompletedSetup = true
        let before = date("2026-09-14T23:59:59Z"), due = date("2026-09-15T00:00:00Z")
        #expect(!(DailySchedule.shouldRefresh(now: before, settings: settings, latest: nil)))
        #expect(DailySchedule.shouldRefresh(now: due, settings: settings, latest: nil))
        #expect(DailySchedule.shouldRefresh(now: date("2026-09-15T10:30:00Z"), settings: settings, latest: nil))
        #expect(!(DailySchedule.shouldRefresh(now: due, settings: settings, latest: edition(at: due))))
    }
    @Test func testSetupAndAutoUpdateSwitchPreventBackgroundCharges() {
        var settings = AppSettings(); let now = date("2026-09-15T04:00:00Z")
        #expect(!(DailySchedule.shouldRefresh(now: now, settings: settings, latest: nil)))
        settings.hasCompletedSetup = true; settings.automaticUpdates = false
        #expect(!(DailySchedule.shouldRefresh(now: now, settings: settings, latest: nil)))
    }
    @Test func testManualBriefBeforeBreakfastDoesNotSkipMorningUpdate() {
        var settings = AppSettings(); settings.hasCompletedSetup = true
        let early = edition(at: date("2026-09-14T18:00:00Z")) // Sept 15, 02:00 Beijing.
        #expect(DailySchedule.shouldRefresh(now: date("2026-09-15T00:00:00Z"), settings: settings, latest: early))
        let morning = edition(at: date("2026-09-15T00:02:00Z"))
        #expect(!DailySchedule.shouldRefresh(now: date("2026-09-15T01:00:00Z"), settings: settings, latest: morning))
    }
    @Test func testDSTNonexistentTimeAdvancesToNextValidTime() {
        var settings = AppSettings(); settings.timeZoneID = "America/Los_Angeles"; settings.hour = 2; settings.minute = 30
        let result = DailySchedule.scheduledTime(on: date("2026-03-08T15:00:00Z"), settings: settings)
        #expect((result) == ( date("2026-03-08T10:00:00Z")))
    }
    @Test func testRepeatedDSTTimeUsesFirstOccurrence() {
        var settings = AppSettings(); settings.timeZoneID = "America/Los_Angeles"; settings.hour = 1; settings.minute = 30
        #expect((DailySchedule.scheduledTime(on: date("2026-11-01T16:00:00Z"), settings: settings)) == ( date("2026-11-01T08:30:00Z")))
    }
    @Test func testRetryBackoffAndDueTime() {
        let now = date("2026-09-15T04:00:00Z"); var retry = RetryState()
        retry.recordFailure(now: now); #expect((retry.nextAttempt) == ( now.addingTimeInterval(300)))
        retry.recordFailure(now: now); #expect((retry.nextAttempt) == ( now.addingTimeInterval(900)))
        for _ in 0..<20 { retry.recordFailure(now: now) }
        #expect((retry.nextAttempt) == ( now.addingTimeInterval(3600)))
        var settings = AppSettings(); settings.hasCompletedSetup = true
        #expect(!(DailySchedule.shouldRefresh(now: now, settings: settings, latest: nil, retry: retry)))
        #expect(DailySchedule.shouldRefresh(now: now.addingTimeInterval(3600), settings: settings, latest: nil, retry: retry))
    }
    @Test func testAutomaticGenerationIsCappedAndResetsNextBeijingDay() {
        let now = date("2026-09-15T00:00:00Z"); let zone = AppSettings().timeZone
        var retry = RetryState()
        for _ in 0..<3 { retry.recordGeneration(now: now, timeZone: zone) }
        #expect(!retry.permitsAutomaticGeneration(now: now, timeZone: zone))
        #expect(retry.permitsAutomaticGeneration(now: date("2026-09-16T00:00:00Z"), timeZone: zone))
        retry.recordGeneration(now: date("2026-09-16T00:00:00Z"), timeZone: zone)
        #expect(retry.generationsToday == 1)
    }
    @Test func testAtomicStorageRecoversFromCorruptedLatestAndRejectsDemo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BriefStore(directory: directory), value = edition(at: date("2026-09-15T00:00:00Z"))
        try store.saveEdition(value); #expect((try store.loadLatest()) == ( value))
        try Data("{broken".utf8).write(to: directory.appendingPathComponent("latest.json"))
        #expect((try store.loadLatest()) == ( value))
        var demo = value; demo.isDemo = true
        #expect(throws: (any Error).self) { _ = try store.saveEdition(demo) }
        #expect((try store.loadHistory().count) == ( 1))
    }
    @Test func testMalformedCacheCannotOpenExecutableURLs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BriefStore(directory: directory); var bad = edition()
        bad.items[0].url = URL(string: "file:///etc/passwd")!
        #expect(throws: (any Error).self) { _ = try store.saveEdition(bad) }
        #expect((try store.loadLatest()) == nil)
    }
    @Test func testEmptySuccessfulEditionIsPersistedWithoutTriggeringRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BriefStore(directory: directory)
        var empty = edition(at: date("2026-09-15T00:00:00Z")); empty.items = []; empty.headline = "本期没有值得新增的精选"
        try store.saveEdition(empty)
        #expect(try store.loadLatest() == empty)
        var settings = AppSettings(); settings.hasCompletedSetup = true
        #expect(!DailySchedule.shouldRefresh(now: date("2026-09-15T01:00:00Z"), settings: settings, latest: try store.loadLatest()))
    }
    @Test func testCommittedHistoryRecoversWhenLatestCopyCannotBeWritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BriefStore(directory: directory)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("latest.json"), withIntermediateDirectories: true)
        let value = edition(at: date("2026-09-15T00:00:00Z"))
        try store.saveEdition(value)
        #expect(try store.loadLatest() == value)
    }
    @Test func testTwoProcessesCannotGenerateAtOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = try GenerationLock(directory: directory)
        #expect(throws: (any Error).self) { _ = try GenerationLock(directory: directory) }
        lock.release()
        let second = try GenerationLock(directory: directory); second.release()
    }
    @Test func testSettingsValidationAndUnsafeURLs() {
        var settings = AppSettings(); #expect(throws: Never.self) { try settings.validate() }
        settings.timeZoneID = "Mars/Olympus"; #expect(throws: (any Error).self) { _ = try settings.validate() }
        #expect(!(URLSafety.isWeb(URL(string: "javascript:alert(1)")!)))
        #expect(!(URLSafety.isWeb(URL(string: "https://key:secret@example.com/")!)))
        #expect(!(URLSafety.isFeed(URL(string: "http://example.com/feed")!)))
    }
    @Test func testStableIDsIgnoreFragmentButKeepPaths() {
        #expect((CandidateArticle.stableID(url: URL(string: "https://example.org/a#one")!)) == ( CandidateArticle.stableID(url: URL(string: "https://example.org/a#two")!)))
        #expect((CandidateArticle.stableID(url: URL(string: "https://example.org/a")!)) != ( CandidateArticle.stableID(url: URL(string: "https://example.org/b")!)))
    }
}
