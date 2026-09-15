import Testing
import Foundation
import Darwin
@testable import BriefCore

@Suite(.serialized)
struct CodexServiceTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    private func article(_ id: String = "candidate-1") -> CandidateArticle {
        .init(id: id, title: "Local knowledge release", url: URL(string: "https://example.com/\(id)")!,
              sourceID: "source", sourceName: "Original source", publishedAt: date,
              excerpt: "Incremental indexing is now available.", discoveredAt: date,
              metrics: .init(stars: 123, forks: 10))
    }

    private func item(_ id: String = "candidate-1", section: String = "highlights") -> [String: Any] {
        ["id": id, "title": "本地知识库新增增量索引", "summary": "文件更新后可只处理变化的内容。",
         "reason": "适合经常整理本地文档的人尝试。", "section": section, "tag": "知识管理"]
    }

    private func response(items: [[String: Any]]? = nil, headline: String = "今天值得看") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["headline": headline, "items": items ?? [item()]])
    }

    @Test func testParserRestoresSourceFactsWithoutModelURLs() throws {
        let source = article()
        let result = try CodexService.parse(response(), articles: [source])
        #expect(result.items.count == 1)
        #expect(result.items[0].url == source.url)
        #expect(result.items[0].sourceName == source.sourceName)
        #expect(result.items[0].publishedAt == source.publishedAt)
        #expect(result.items[0].metrics == source.metrics)
    }

    @Test func testParserRejectsUnknownIDsDuplicatesAndInjectedURLs() throws {
        #expect(throws: (any Error).self) { try CodexService.parse(response(items: [item("invented")]), articles: [article()]) }
        #expect(throws: (any Error).self) { try CodexService.parse(response(items: [item(), item()]), articles: [article()]) }
        var malicious = item(); malicious["url"] = "https://malicious.example"
        #expect(throws: (any Error).self) { try CodexService.parse(response(items: [malicious]), articles: [article()]) }
        var sameURL = article("different-id"); sameURL.url = article().url
        #expect(throws: (any Error).self) { try CodexService.parse(response(items: [item(), item("different-id")]), articles: [article(), sameURL]) }
    }

    @Test func testParserAcceptsNoNewItemsAsSuccessfulUpdate() throws {
        let result = try CodexService.parse(response(items: []), articles: [article()])
        #expect(result.items.isEmpty)
        #expect(result.headline == "本期没有值得新增的精选")
        #expect(throws: (any Error).self) { try CodexService.parse(response(items: [], headline: "  "), articles: [article()]) }
        #expect(throws: (any Error).self) { try CodexService.parse(response(items: [], headline: String(repeating: "文", count: 101)), articles: [article()]) }
    }

    @Test func testParserRejectsEmptyTextOversizedAndInvalidFields() throws {
        #expect(throws: (any Error).self) { try CodexService.parse(response(headline: "   "), articles: [article()]) }
        #expect(throws: (any Error).self) { try CodexService.parse(response(headline: String(repeating: "文", count: 101)), articles: [article()]) }
        var bad = item(); bad["summary"] = String(repeating: "a", count: 221)
        #expect(throws: (any Error).self) { try CodexService.parse(response(items: [bad]), articles: [article()]) }
        bad = item(); bad["tag"] = "\u{0}"
        #expect(throws: (any Error).self) { try CodexService.parse(response(items: [bad]), articles: [article()]) }
        bad = item(); bad["section"] = "other"
        #expect(throws: (any Error).self) { try CodexService.parse(response(items: [bad]), articles: [article()]) }
        do { _ = try CodexService.parse(Data(repeating: 32, count: 512 * 1024 + 1), articles: [article()]); Issue.record("Expected failure") } catch {
            #expect(error as? CodexError == .outputTooLarge)
        }
        #expect(throws: (any Error).self) { try CodexService.parse(Data("```json\n{}\n```".utf8), articles: [article()]) }
    }

    @Test func testParserEnforcesEverySectionLimit() throws {
        for (section, count) in [("highlights", 6), ("updates", 11), ("watch", 3)] {
            let articles = (0..<count).map { article("a\($0)") }
            let rows = articles.map { item($0.id, section: section) }
            #expect(throws: (any Error).self) { try CodexService.parse(response(items: rows), articles: articles) }
        }
    }

    @Test func testSchemaAllowsOnlyCandidateIDsAndNoURLField() throws {
        let schema = try #require(JSONSerialization.jsonObject(with: CodexService.schema(articles: [article()])) as? [String: Any])
        let props = try #require(schema["properties"] as? [String: Any])
        let items = try #require(props["items"] as? [String: Any])
        let itemSchema = try #require(items["items"] as? [String: Any])
        let fields = try #require(itemSchema["properties"] as? [String: Any])
        #expect((fields["id"] as? [String: Any])?["enum"] as? [String] == [article().id])
        #expect(fields["url"] == nil)
        #expect(itemSchema["additionalProperties"] as? Bool == false)
    }

    @Test func testPromptLimitsHistoryAndCarriesInterestAndEvidenceRules() throws {
        let history: [BriefEdition] = (0..<35).map { index in
            var value = article("old-\(index)")
            value.title = "prior-edition-\(index)"
            return .init(dayKey: "day-\(index)", createdAt: date.addingTimeInterval(Double(index)),
                headline: "Past", items: [.init(id: value.id, title: value.title, summary: "Previous summary",
                    reason: "Reason", section: .watch, tag: "Tag", sourceName: value.sourceName,
                    url: value.url, metrics: value.metrics)], sources: [])
        }
        var settings = AppSettings(); settings.interests = "天文与开源传感器"
        let prompt = try CodexService.prompt(articles: [article()], settings: settings, previous: history, now: date)
        #expect(prompt.contains("天文与开源传感器"))
        #expect(prompt.contains("prior-edition-34"))
        #expect(prompt.contains("prior-edition-5"))
        #expect(!(prompt.contains("prior-edition-4\"")))
        #expect(prompt.contains("不使用任何工具"))
        #expect(prompt.contains("不能证明影响持续扩大"))
        #expect(prompt.contains("discovered_at 是采集日期"))
    }

    @Test func testCandidatesDeduplicateRejectUnsafeURLsAndRemainBounded() {
        var unsafe = article("unsafe"); unsafe.url = URL(string: "file:///tmp/a")!
        var duplicate = article("other"); duplicate.url = article().url
        #expect(CodexService.prepareCandidates([unsafe, article(), article(), duplicate]).map(\.id) == [article().id])
        #expect(CodexService.prepareCandidates((0..<150).map { article("item-\($0)") }).count == 120)
    }

    @Test func testConnectionAndGenerationWithFakeCLIAndSpaceInPath() async throws {
        let fixture = try Fixture(script: cliScript(json: response()))
        defer { fixture.remove() }
        var settings = AppSettings(); settings.codexPath = fixture.executable.path
        let service = CodexService(generationTimeout: 3)
        let connection = try await service.checkConnection(configuredPath: settings.codexPath)
        #expect(connection.executableURL == fixture.executable)
        #expect(!(connection.message.contains("secret-marker")))
        let result = try await service.generate(articles: [article()], settings: settings, previous: [], now: date)
        #expect(result.items[0].url == article().url)
        #expect(result.headline == "今天值得看")
    }

    @Test func testConnectionReportsLoggedOutWithoutLeakingDiagnostics() async throws {
        let fixture = try Fixture(script: cliScript(json: response(), login: "printf 'Not logged in secret-marker' >&2; exit 1"))
        defer { fixture.remove() }
        do {
            _ = try await CodexService().checkConnection(configuredPath: fixture.executable.path)
            Issue.record("Expected login failure")
        } catch {
            #expect(error as? CodexError == .notLoggedIn)
            #expect(!(error.localizedDescription.contains("secret-marker")))
        }
    }

    @Test func testIncompatibleCLIIsRejectedBeforeGeneration() async throws {
        let fixture = try Fixture(script: cliScript(json: response()).replacingOccurrences(of: "--ignore-user-config", with: "--old-option"))
        defer { fixture.remove() }
        do {
            _ = try await CodexService().checkConnection(configuredPath: fixture.executable.path)
            Issue.record("Expected unsupported CLI")
        } catch { #expect(error as? CodexError == .incompatible) }
    }

    @Test func testGenerationMapsQuotaAndRetainsNoRawFailureText() async throws {
        let fixture = try Fixture(script: cliScript(json: response(), execution: "printf 'usage limit reached secret-marker' >&2; exit 1"))
        defer { fixture.remove() }
        var settings = AppSettings(); settings.codexPath = fixture.executable.path
        do {
            _ = try await CodexService().generate(articles: [article()], settings: settings, previous: [])
            Issue.record("Expected quota failure")
        } catch {
            #expect(error as? CodexError == .quotaExceeded)
            #expect(!(error.localizedDescription.contains("secret-marker")))
        }
    }

    @Test func testGenerationRejectsMissingAndOversizedOutput() async throws {
        for (body, expected) in [("exit 0", CodexError.missingOutput),
                                 ("/usr/bin/awk 'BEGIN { for(i=0;i<600000;i++) printf \"a\" }' > \"$output\"", .outputTooLarge)] {
            let fixture = try Fixture(script: cliScript(json: response(), execution: body))
            defer { fixture.remove() }
            var settings = AppSettings(); settings.codexPath = fixture.executable.path
            do {
                _ = try await CodexService().generate(articles: [article()], settings: settings, previous: [])
                Issue.record("Expected output failure")
            } catch { #expect(error as? CodexError == expected) }
        }
    }

    @Test func testRunnerDrainsLargeStderrAndBoundsMemory() async throws {
        let fixture = try Fixture(script: """
        #!/bin/sh
        /usr/bin/awk 'BEGIN { for(i=0;i<1000000;i++) printf "e" }' >&2
        printf 'complete'
        """)
        defer { fixture.remove() }
        let result = try await CodexProcessRunner.run(executable: fixture.executable, arguments: [],
            directory: fixture.root, timeout: 5, outputLimit: 4096)
        #expect(result.status == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "complete")
        #expect(result.stderr.count == 4096)
        #expect(result.outputWasTruncated)
    }

    @Test func testRunnerTimeoutKillsChildEvenWhenTermIsIgnored() async throws {
        let fixture = try Fixture(script: "#!/bin/sh\nprintf '%s' \"$$\" > child.pid\ntrap '' TERM\nexec /bin/sleep 20\n")
        defer { fixture.remove() }
        let start = Date()
        do {
            _ = try await CodexProcessRunner.run(executable: fixture.executable, arguments: [], directory: fixture.root, timeout: 1.5)
            Issue.record("Expected deadline")
        } catch { #expect(error as? CodexError == .timedOut) }
        #expect(Date().timeIntervalSince(start) < 5)
        let pid = try #require(Int32(String(contentsOf: fixture.root.appendingPathComponent("child.pid"))))
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func testRunnerCancellationTerminatesProcess() async throws {
        let fixture = try Fixture(script: "#!/bin/sh\nprintf '%s' \"$$\" > child.pid\nexec /bin/sleep 20\n")
        defer { fixture.remove() }
        let task = Task {
            try await CodexProcessRunner.run(executable: fixture.executable, arguments: [], directory: fixture.root, timeout: 10)
        }
        defer { task.cancel() }
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("child.pid").path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("child.pid").path))
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        let pid = try #require(Int32(String(contentsOf: fixture.root.appendingPathComponent("child.pid"))))
        #expect(kill(pid, 0) == -1)
    }

    @Test func testTimeoutStopsGrandchildAfterWrapperExitsOnTerm() async throws {
        let fixture = try Fixture(script: """
        #!/bin/sh
        /bin/sh -c 'trap "" TERM; while :; do printf x >> grandchild-work; /bin/sleep 0.02; done' &
        printf '%s' "$!" > grandchild.pid
        wait
        """)
        defer { fixture.remove() }
        do {
            _ = try await CodexProcessRunner.run(executable: fixture.executable, arguments: [], directory: fixture.root, timeout: 1.5)
            Issue.record("Expected deadline")
        } catch { #expect(error as? CodexError == .timedOut) }
        let work = fixture.root.appendingPathComponent("grandchild-work")
        let sizeAtExit = try Data(contentsOf: work).count
        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(try Data(contentsOf: work).count == sizeAtExit)
    }

    @Test func testRunnerHandlesEarlyClosedPipesAndUnreadLargeInput() async throws {
        let fixture = try Fixture(script: "#!/bin/sh\nexec 1>&- 2>&-\nexec /bin/sleep 0.1\n")
        defer { fixture.remove() }
        let result = try await CodexProcessRunner.run(executable: fixture.executable, arguments: [],
            directory: fixture.root, input: Data(repeating: 65, count: 1024 * 1024), timeout: 2)
        #expect(result.status == 0)
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        #expect(!(files.contains(where: { $0.hasPrefix("stdin-") })))
    }

    @Test func testExplicitMissingPathDoesNotSilentlyFallBack() {
        do { _ = try CodexService.resolveExecutable(configuredPath: "/this/does/not/exist"); Issue.record("Expected failure") } catch {
            #expect(error as? CodexError == .notFound)
        }
        #expect(throws: (any Error).self) { try CodexService.resolveExecutable(configuredPath: "codex; touch /tmp/nope") }
    }

    private func cliScript(json: Data, login: String = "printf 'Logged in using ChatGPT secret-marker' >&2; exit 0", execution: String? = nil) -> String {
        let encoded = String(decoding: json, as: UTF8.self).replacingOccurrences(of: "'", with: "'\\''")
        return """
        #!/bin/sh
        case "$1" in
          --version) printf 'codex-cli test'; exit 0 ;;
          login) \(login) ;;
          features) printf 'shell_tool stable true\\nplugins stable true\\napps stable true\\nhooks stable true\\n'; exit 0 ;;
          exec)
            if [ "$2" = '--help' ]; then
              printf '%s' '--output-schema --output-last-message --ephemeral --ignore-user-config --sandbox --disable'
              exit 0
            fi ;;
          *) exit 81 ;;
        esac
        output=''
        isolated=''
        safe=''
        approval=''
        web=''
        documents=''
        shell_disabled=''
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --output-last-message) shift; output="$1" ;;
            --ignore-user-config) isolated='yes' ;;
            --sandbox) shift; safe="$1" ;;
            -c)
              shift
              case "$1" in
                'approval_policy="never"') approval='yes' ;;
                'web_search="disabled"') web='yes' ;;
                project_doc_max_bytes=0) documents='yes' ;;
              esac ;;
            --disable) shift; [ "$1" = 'shell_tool' ] && shell_disabled='yes' ;;
            --model|-m) exit 84 ;;
            --dangerously-bypass-approvals-and-sandbox|--ignore-rules) exit 82 ;;
          esac
          shift
        done
        [ "$isolated" = 'yes' ] && [ "$safe" = 'read-only' ] || exit 83
        [ "$approval" = 'yes' ] && [ "$web" = 'yes' ] && [ "$documents" = 'yes' ] && [ "$shell_disabled" = 'yes' ] || exit 85
        /bin/cat >/dev/null
        \(execution ?? "printf '%s' '\(encoded)' > \"$output\"")
        """
    }
}

private struct Fixture {
    let root: URL
    let executable: URL
    init(script: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SideBrief-Test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executable = root.appendingPathComponent("codex fake")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
