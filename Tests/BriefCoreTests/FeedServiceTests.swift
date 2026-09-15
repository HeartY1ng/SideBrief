import Foundation
import Testing
@testable import BriefCore

struct FeedServiceTests {
    private let now = Date(timeIntervalSince1970: 1_789_430_400) // 2026-09-15 00:00 UTC
    private var source: FeedSource { FeedSource(id: "fixture", name: "Fixture", url: URL(string: "https://example.com/news/feed.xml")!) }

    @Test func testRSSDecodesCDATAEntitiesNestedTextAndPublicationDates() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
          <channel><title>Feed title is not an article</title>
            <item><title>Local <b>knowledge</b> &amp; AI</title>
              <link>/posts/local?view=full&amp;utm_source=rss#section</link>
              <description><![CDATA[<p>Read &amp; organize&nbsp;your notes &#x1F4DA;.</p><script>unwanted()</script><p>Try it.</p>]]></description>
              <pubDate>Tue, 15 Sep 2026 08:00:00 +0800</pubDate>
            </item>
          </channel>
        </rss>
        """
        let article = try #require(parse(xml).first)
        #expect(article.title == "Local knowledge & AI")
        #expect(article.url.absoluteString == "https://example.com/posts/local?view=full")
        #expect(article.excerpt == "Read & organize your notes 📚. Try it.")
        #expect(article.publishedAt == now)
        #expect(article.sourceID == source.id)
        #expect(article.discoveredAt == now)
    }

    @Test func testAtomUsesAlternateLinkInheritedXMLBaseAndXHTMLContent() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom" xml:base="https://example.org/projects/">
          <entry xml:base="../releases/">
            <title type="html">Tool &amp;lt;strong&amp;gt;2.0&amp;lt;/strong&amp;gt;</title>
            <link rel="self" href="api/2" type="application/atom+xml"/>
            <link rel="alternate" href="v2" type="text/html"/>
            <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>First <b>line</b>.</p><p>Second line.</p><script>unwanted()</script></div></content>
            <published>2026-09-14T23:59:00.125Z</published><updated>2026-09-15T00:00:00Z</updated>
          </entry>
        </feed>
        """
        let article = try #require(parse(xml).first)
        #expect(article.title == "Tool 2.0")
        #expect(article.url.absoluteString == "https://example.org/releases/v2")
        #expect(article.excerpt == "First line. Second line.")
        #expect(abs((try #require(article.publishedAt).timeIntervalSince(now)) - (-59.875)) <= 0.001)
    }

    @Test func testMissingAndInvalidDatesStayUnknown() throws {
        let xml = """
        <rss><channel>
          <item><title>Undated</title><link>/undated</link></item>
          <item><title>Invalid date</title><link>/invalid</link><pubDate>definitely not a date</pubDate></item>
          <item><title>Invalid publication, valid update</title><link>/updated</link><pubDate>bad</pubDate><updated>2026-09-15T00:00:00Z</updated></item>
        </channel></rss>
        """
        let articles = try parse(xml)
        #expect(articles.count == 3)
        #expect(articles.allSatisfy { $0.publishedAt == nil })

        let atom = """
        <feed xmlns="http://www.w3.org/2005/Atom"><entry>
          <title>Only an update time</title><link href="https://example.com/updated-only"/>
          <updated>2026-09-15T00:00:00Z</updated>
        </entry></feed>
        """
        let updatedOnly = try #require(parse(atom).first)
        #expect(updatedOnly.publishedAt == nil)
    }

    @Test func testRejectsUnsafeLinksAndDeduplicatesFragmentsAndTrackingParameters() throws {
        let xml = """
        <rss><channel>
          <item><title>First</title><link>https://EXAMPLE.com:443/story?utm_medium=rss#one</link></item>
          <item><title>Duplicate</title><link>https://example.com/story#two</link></item>
          <item><title>File</title><link>file:///etc/passwd</link></item>
          <item><title>Script</title><link>javascript:alert(1)</link></item>
          <item><title>Credentials</title><link>https://user:secret@example.com/private</link></item>
          <item><title>Opaque GUID</title><guid isPermaLink="false">123456</guid></item>
          <item><title>URL GUID fallback</title><guid>https://example.com/fallback</guid></item>
          <item><title>Plain HTTP is supported</title><link>http://example.com/plain</link></item>
        </channel></rss>
        """
        let articles = try parse(xml)
        #expect(articles.map(\.title) == ["First", "URL GUID fallback", "Plain HTTP is supported"])
        #expect(articles.first?.url.absoluteString == "https://example.com/story")
    }

    @Test func testRejectsEntityDeclarationsWithoutResolvingThem() {
        let external = """
        <?xml version="1.0"?><!DOCTYPE rss [<!ENTITY steal SYSTEM "file:///sidebrief-test-must-not-read">]>
        <rss><channel><item><title>&steal;</title><link>https://example.com/a</link></item></channel></rss>
        """
        let recursive = """
        <?xml version="1.0"?><!DOCTYPE rss [<!ENTITY a "many"><!ENTITY b "&a;&a;&a;&a;">]>
        <rss><channel><item><title>&b;</title><link>https://example.com/a</link></item></channel></rss>
        """
        #expect(throws: (any Error).self) { try parse(external) }
        #expect(throws: (any Error).self) { try parse(recursive) }
        #expect(throws: (any Error).self) { try FeedService.parse(data: external.data(using: .utf16)!, source: source, now: now) }
    }

    @Test func testHTMLDoctypeInsideCDATAIsNotAnXMLDeclaration() throws {
        let xml = "<rss><channel><item><title>Embedded document</title><link>/doc</link><description><![CDATA[<!DOCTYPE html><html><body><p>Plain document.</p></body></html>]]></description></item></channel></rss>"
        #expect(try parse(xml).count == 1)
        #expect(try parse(xml).first?.excerpt == "Plain document.")
    }

    @Test func testMalformedXMLAndHTMLResponsesDoNotBecomeArticles() {
        #expect(throws: (any Error).self) { try parse("<rss><channel><item></rss>") }
        #expect(throws: (any Error).self) { try parse("<html><body><item><title>Challenge</title><link>https://example.com/a</link></item></body></html>") }
        let deeplyNested = "<rss>" + String(repeating: "<a>", count: 70) + String(repeating: "</a>", count: 70) + "</rss>"
        #expect(throws: (any Error).self) { try parse(deeplyNested) }
    }

    @Test func testGitHubUsesCreationDateAndKeepsPushAsActivityWithMetrics() throws {
        let json = """
        {"items":[
          {"full_name":"team/tool","html_url":"https://github.com/team/tool","description":"Local workflow automation","stargazers_count":1234,"forks_count":56,"created_at":"2021-01-02T03:04:05Z","pushed_at":"2026-09-15T00:00:00Z","private":false},
          {"full_name":"team/unknown-date","html_url":"https://github.com/team/unknown-date","description":null,"created_at":"invalid","pushed_at":"2026-09-15T00:00:00Z"},
          {"full_name":"team/stale","html_url":"https://github.com/team/stale","created_at":"2020-01-01T00:00:00Z","pushed_at":"2026-08-01T00:00:00Z"},
          {"full_name":"team/unknown-activity","html_url":"https://github.com/team/unknown-activity","created_at":"2026-09-15T00:00:00Z","pushed_at":"invalid"},
          {"full_name":"team/private","html_url":"https://github.com/team/private","private":true},
          {"full_name":"team/bad","html_url":"javascript:alert(1)"}
        ]}
        """
        var githubSource = source
        githubSource.kind = .github
        let articles = try FeedService.parse(data: Data(json.utf8), source: githubSource, now: now)
        #expect(articles.count == 2)
        #expect(articles[0].title == "team/tool")
        #expect(articles[0].metrics == ProjectMetrics(stars: 1234, forks: 56))
        #expect(articles[0].publishedAt == ISO8601DateFormatter().date(from: "2021-01-02T03:04:05Z"))
        #expect(articles[0].excerpt.contains("最近推送：2026-09-15T00:00:00Z"))
        #expect(articles[1].publishedAt == nil)
        #expect(articles[1].metrics == ProjectMetrics(stars: 0, forks: 0))
    }

    @Test func testBodyLimitAndSourceURLValidationApplyBeforeParsing() {
        #expect(throws: (any Error).self) { try FeedService.parse(data: Data(repeating: 32, count: FeedService.maximumBodyBytes + 1), source: source, now: now) }
        var invalid = source
        invalid.url = URL(string: "file:///tmp/feed.xml")!
        #expect(throws: (any Error).self) { try FeedService.parse(data: Data("<rss/>".utf8), source: invalid, now: now) }
        invalid.url = URL(string: "https://user:test-secret@example.com/feed.xml")!
        do {
            _ = try FeedService.parse(data: Data("<rss/>".utf8), source: invalid, now: now)
            Issue.record("Expected embedded credentials to be rejected")
        } catch {
            #expect(!error.localizedDescription.contains("test-secret"))
            #expect(!error.localizedDescription.contains("example.com"))
        }
    }

    @Test func testSelectionPrioritizesRecentThenUnknownAndCapsUniqueCandidates() {
        let old = article("old", date: now.addingTimeInterval(-20 * 86_400))
        let unknown = article("unknown", date: nil)
        let recent = article("recent", date: now.addingTimeInterval(-86_400))
        #expect(FeedService.selectCandidates([old, unknown, recent, recent], now: now).map(\.title) == ["recent", "unknown", "old"])
        let many = (0..<100).map { article("article-\($0)", date: now.addingTimeInterval(Double(-$0))) }
        #expect(FeedService.selectCandidates(many, now: now).count == 12)
        let diverse = (0..<10).flatMap { sourceIndex in
            many.map { value in
                var value = value
                value.sourceID = "source-\(sourceIndex)"
                value.url = URL(string: "https://example.com/\(sourceIndex)/\(value.title)")!
                value.id = CandidateArticle.stableID(url: value.url)
                return value
            }
        }
        let selected = FeedService.selectCandidates(diverse + diverse, now: now)
        #expect(selected.count == 70)
        #expect(Set(selected.map(\.id)).count == 70)
        #expect(Set(selected.map(\.sourceID)).count == 10)
        #expect(Dictionary(grouping: selected, by: \.sourceID).values.allSatisfy { $0.count <= 12 })
        var oldProject = old
        oldProject.sourceID = "github"
        oldProject.metrics = ProjectMetrics(stars: 100, forks: 20)
        #expect(FeedService.selectCandidates(diverse + [oldProject], now: now).contains { $0.id == oldProject.id })
    }

    @Test func testFetchHandlesNoSourcesAndTooManySourcesWithoutNetwork() async {
        do {
            _ = try await FeedService().fetch(sources: [])
            Issue.record("Expected noSources")
        } catch { #expect(error as? BriefError == .noSources) }
        do {
            _ = try await FeedService().fetch(sources: Array(repeating: source, count: 31))
            Issue.record("Expected source limit")
        } catch { #expect(error as? BriefError == .invalidSettings("最多同时启用 30 个资讯来源。")) }
    }

    @Test func testCancellationIsNotReportedAsEmptyFeed() async {
        let invalidSource = FeedSource(name: "Invalid", url: URL(string: "file:///invalid")!)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FeedService().fetch(sources: [invalidSource])
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
    }

    @Test func testTotalFailureKeepsSourceReportsAndDoesNotExposeURLSecrets() async {
        let invalid = FeedSource(id: "invalid", name: "Custom source", url: URL(string: "https://user:test-secret@example.com/feed")!)
        do {
            _ = try await FeedService().fetch(sources: [invalid])
            Issue.record("Expected source failure")
        } catch {
            #expect((error as? FeedCollectionError)?.reports.count == 1)
            #expect(error.localizedDescription.contains("Custom source"))
            #expect(!error.localizedDescription.contains("test-secret"))
            #expect(!error.localizedDescription.contains("example.com"))
        }
    }

    /// Optional live fixtures saved by a separate, explicit read-only network check.
    /// This never accesses the network and is not required by the portable test suite.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SIDEBRIEF_VERIFY_DOWNLOADED_FEEDS"] == "1"))
    func testDownloadedDefaultSourceFixturesWhenExplicitlyEnabled() throws {
        var validated = 0
        for source in AppSettings.defaultSources {
            let suffix = source.kind == .github ? "-feed.json" : "-feed.xml"
            let path = "/tmp/sidebrief-" + source.id + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let articles = try FeedService.parse(data: data, source: source, now: Date())
            #expect(!(articles.isEmpty), "No parsed entries for \(source.name)")
            #expect(articles.allSatisfy { URLSafety.isWeb($0.url) }, "Unsafe link in \(source.name)")
            validated += 1
        }
        #expect(validated >= 1, "Explicit fixture validation needs at least one downloaded fixture.")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SIDEBRIEF_VERIFY_LIVE_NETWORK"] == "1"))
    func testLiveDefaultSourcesTolerateIndividualFailureWhenExplicitlyEnabled() async throws {
        let invalid = FeedSource(id: "invalid-fixture", name: "Invalid fixture", url: URL(string: "file:///not-a-feed")!)
        let sources = AppSettings.defaultSources.filter(\.enabled) + [invalid]
        let batch = try await FeedService().fetch(sources: sources)
        #expect(!batch.articles.isEmpty)
        #expect(batch.articles.count <= 70)
        #expect(batch.reports.count == sources.count)
        #expect(batch.reports.first(where: { $0.id == invalid.id })?.error != nil)
        #expect(batch.reports.contains { $0.count > 0 })
        #expect(Dictionary(grouping: batch.articles, by: \.sourceID).values.allSatisfy { $0.count <= 12 })
    }

    private func parse(_ xml: String) throws -> [CandidateArticle] {
        try FeedService.parse(data: Data(xml.utf8), source: source, now: now)
    }
    private func article(_ title: String, date: Date?) -> CandidateArticle {
        CandidateArticle(title: title, url: URL(string: "https://example.com/\(title)")!, sourceID: source.id, sourceName: source.name, publishedAt: date, discoveredAt: now)
    }
}
