import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Fetches public sources for one refresh. It owns no persistent session or credentials.
public struct FeedService: Sendable {
    public static let maximumBodyBytes = 3 * 1_024 * 1_024
    public init() {}

    public func fetch(sources: [FeedSource], now: Date = Date()) async throws -> FeedBatch {
        try Task.checkCancellation()
        let enabled = sources.filter(\.enabled)
        guard !enabled.isEmpty else { throw BriefError.noSources }
        guard enabled.count <= 30 else { throw BriefError.invalidSettings("最多同时启用 30 个资讯来源。") }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 18
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: FeedSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        return try await withTaskCancellationHandler {
            let results = try await withThrowingTaskGroup(of: SourceResult.self) { group in
                var nextIndex = 0
                for _ in 0..<min(4, enabled.count) {
                    let index = nextIndex
                    nextIndex += 1
                    group.addTask { try await Self.fetchSource(enabled[index], index: index, session: session, now: now) }
                }
                var completed: [SourceResult] = []
                while let result = try await group.next() {
                    try Task.checkCancellation()
                    completed.append(result)
                    if nextIndex < enabled.count {
                        let index = nextIndex
                        nextIndex += 1
                        group.addTask { try await Self.fetchSource(enabled[index], index: index, session: session, now: now) }
                    }
                }
                return completed.sorted { $0.index < $1.index }
            }
            try Task.checkCancellation()
            let articles = Self.selectCandidates(results.flatMap(\.articles), now: now)
            guard !articles.isEmpty else { throw FeedCollectionError(reports: results.map(\.report)) }
            return FeedBatch(articles: articles, reports: results.map(\.report))
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    /// A network-free parser, also useful for validating imported feed fixtures.
    public static func parse(data: Data, source: FeedSource, now: Date = Date()) throws -> [CandidateArticle] {
        try Task.checkCancellation()
        guard URLSafety.isWeb(source.url) else { throw FeedServiceError.invalidURL }
        guard data.count <= maximumBodyBytes else { throw FeedServiceError.bodyTooLarge }
        let articles: [CandidateArticle]
        switch source.kind {
        case .feed:
            guard !FeedText.containsXMLDeclarations(data) else { throw FeedServiceError.invalidFeed }
            let delegate = FeedXMLDelegate(source: source, now: now)
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.externalEntityResolvingPolicy = .never
            parser.delegate = delegate
            let parsed = parser.parse()
            try Task.checkCancellation()
            guard parsed, !delegate.rejected, delegate.recognizedRoot else {
                throw FeedServiceError.invalidFeed
            }
            articles = delegate.articles
        case .github:
            let payload = try JSONDecoder().decode(GitHubSearchPayload.self, from: data)
            let dates = FeedDateParser()
            articles = payload.items.prefix(200).compactMap { repository in
                guard !repository.isPrivate, let url = FeedText.webURL(repository.htmlURL, base: source.url),
                      let activity = repository.pushedAt.flatMap(dates.parse), activity >= now.addingTimeInterval(-14 * 86_400),
                      activity <= now.addingTimeInterval(86_400) else { return nil }
                let title = FeedText.clean(repository.fullName, limit: 250)
                guard !title.isEmpty else { return nil }
                var excerpt = FeedText.clean(repository.description ?? "", limit: 700)
                // A push is activity, not publication. Keep creation time as publishedAt.
                if let pushedAt = repository.pushedAt, dates.parse(pushedAt) != nil {
                    excerpt += (excerpt.isEmpty ? "" : " · ") + "最近推送：" + pushedAt
                }
                return CandidateArticle(title: title, url: url, sourceID: source.id, sourceName: source.name,
                                        publishedAt: repository.createdAt.flatMap(dates.parse), excerpt: excerpt,
                                        discoveredAt: now, metrics: ProjectMetrics(stars: max(0, repository.stars), forks: max(0, repository.forks)))
            }
        }
        try Task.checkCancellation()
        var seen = Set<String>()
        return articles.filter { seen.insert($0.id).inserted }
    }

    /// Keeps recent news first without pretending that undated entries were published today.
    static func selectCandidates(_ articles: [CandidateArticle], now: Date) -> [CandidateArticle] {
        let cutoff = now.addingTimeInterval(-14 * 24 * 60 * 60)
        func rank(_ article: CandidateArticle) -> Int {
            guard let date = article.publishedAt else { return 1 }
            return date >= cutoff && date <= now.addingTimeInterval(24 * 60 * 60) ? 0 : 2
        }
        func sorted(_ values: [CandidateArticle]) -> [CandidateArticle] {
            values.enumerated().sorted { lhs, rhs in
            let leftRank = rank(lhs.element), rightRank = rank(rhs.element)
            if leftRank != rightRank { return leftRank < rightRank }
            if let left = lhs.element.publishedAt, let right = rhs.element.publishedAt, left != right { return left > right }
            return lhs.offset < rhs.offset
            }.map(\.element)
        }
        var sourceOrder: [String] = []
        var bySource: [String: [CandidateArticle]] = [:]
        for article in articles {
            if bySource[article.sourceID] == nil { sourceOrder.append(article.sourceID) }
            bySource[article.sourceID, default: []].append(article)
        }
        for sourceID in sourceOrder {
            var sourceSeen = Set<String>()
            bySource[sourceID] = Array(sorted(bySource[sourceID] ?? []).filter { sourceSeen.insert($0.id).inserted }.prefix(12))
        }
        var selected: [CandidateArticle] = []
        var seen = Set<String>()
        // Round robin preserves room for an active repository whose creation date is old.
        for offset in 0..<12 {
            for sourceID in sourceOrder {
                guard let candidates = bySource[sourceID], offset < candidates.count else { continue }
                let article = candidates[offset]
                if seen.insert(article.id).inserted { selected.append(article) }
                if selected.count == 70 { return sorted(selected) }
            }
        }
        return sorted(selected)
    }

    private static func fetchSource(_ source: FeedSource, index: Int, session: URLSession, now: Date) async throws -> SourceResult {
        do {
            try Task.checkCancellation()
            guard URLSafety.isWeb(source.url) else { throw FeedServiceError.invalidURL }
            var request = URLRequest(url: source.url, timeoutInterval: 18)
            request.setValue("SideBrief/0.1 (personal news reader)", forHTTPHeaderField: "User-Agent")
            request.setValue(source.kind == .github ? "application/vnd.github+json" : "application/atom+xml, application/rss+xml, application/xml, text/xml;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, let finalURL = http.url, URLSafety.isWeb(finalURL) else {
                throw FeedServiceError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else { throw FeedServiceError.httpStatus(http.statusCode) }
            guard response.expectedContentLength <= Int64(maximumBodyBytes) else { throw FeedServiceError.bodyTooLarge }
            var data = Data()
            data.reserveCapacity(min(maximumBodyBytes, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes {
                if data.count.isMultiple(of: 16_384) { try Task.checkCancellation() }
                guard data.count < maximumBodyBytes else { throw FeedServiceError.bodyTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            var resolvedSource = source
            resolvedSource.url = finalURL
            let articles = try parse(data: data, source: resolvedSource, now: now)
            return SourceResult(index: index, articles: articles,
                                report: SourceReport(id: source.id, name: source.name, count: articles.count,
                                                     error: articles.isEmpty ? "来源返回了内容，但没有可用条目。" : nil))
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            return SourceResult(index: index, articles: [], report: SourceReport(id: source.id, name: source.name, count: 0, error: sourceErrorMessage(error)))
        }
    }

    private static func sourceErrorMessage(_ error: Error) -> String {
        // Raw transport errors can include a request URL; do not echo query tokens into UI or logs.
        if let error = error as? FeedServiceError { return error.localizedDescription }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return "连接超时，稍后再试。"
            case .notConnectedToInternet, .networkConnectionLost: return "网络暂时不可用，联网后重试。"
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost: return "无法连接到来源服务器。"
            default: return "网络请求失败（\(error.code.rawValue)）。"
            }
        }
        return "无法解析来源内容。"
    }
}

/// Retains individual diagnostics when every enabled source fails or returns no usable entries.
public struct FeedCollectionError: LocalizedError, Sendable {
    public let reports: [SourceReport]
    public var errorDescription: String? {
        let details = reports.map { "\($0.name)：\($0.error ?? "没有可用条目。")" }.joined(separator: "\n")
        return "暂时没有获取到可用资讯。\n" + details
    }
}

private struct SourceResult: Sendable {
    let index: Int
    let articles: [CandidateArticle]
    let report: SourceReport
}

private enum FeedServiceError: LocalizedError {
    case invalidURL, bodyTooLarge, invalidFeed, invalidResponse, httpStatus(Int)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "来源或文章地址必须是有效的 HTTP/HTTPS 链接，且不能包含账户信息。"
        case .bodyTooLarge: return "来源内容超过 3MB 限制。"
        case .invalidFeed: return "来源不是有效的 RSS/Atom，或包含不允许的 XML 实体声明。"
        case .invalidResponse: return "来源返回了无效的网络响应。"
        case .httpStatus(let status): return "来源返回 HTTP \(status)。"
        }
    }
}

private final class FeedSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(URLSafety.isWeb) == true ? request : nil)
    }
}

private struct GitHubSearchPayload: Decodable {
    let items: [Repository]
    struct Repository: Decodable {
        let fullName: String
        let htmlURL: String
        let description: String?
        let stars: Int
        let forks: Int
        let createdAt: String?
        let pushedAt: String?
        let isPrivate: Bool
        enum CodingKeys: String, CodingKey {
            case fullName = "full_name", htmlURL = "html_url", description, stars = "stargazers_count"
            case forks = "forks_count", createdAt = "created_at", pushedAt = "pushed_at", isPrivate = "private"
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            fullName = try values.decode(String.self, forKey: .fullName)
            htmlURL = try values.decode(String.self, forKey: .htmlURL)
            description = try values.decodeIfPresent(String.self, forKey: .description)
            stars = try values.decodeIfPresent(Int.self, forKey: .stars) ?? 0
            forks = try values.decodeIfPresent(Int.self, forKey: .forks) ?? 0
            createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
            pushedAt = try values.decodeIfPresent(String.self, forKey: .pushedAt)
            isPrivate = try values.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        }
    }
}

private final class FeedXMLDelegate: NSObject, XMLParserDelegate {
    private struct Frame {
        let name: String
        let base: URL
        let attributes: [String: String]
        var text = ""
        var textCount = 0
    }
    private struct Entry {
        let depth: Int
        var title = ""
        var link: URL?
        var fallbackLink: URL?
        var summary = ""
        var content = ""
        var publication: String?
    }
    let source: FeedSource
    let now: Date
    private let dates = FeedDateParser()
    private var stack: [Frame] = []
    private var entry: Entry?
    private var elements = 0
    private(set) var articles: [CandidateArticle] = []
    private(set) var rejected = false
    private(set) var recognizedRoot = false
    init(source: FeedSource, now: Date) { self.source = source; self.now = now }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if Task.isCancelled { reject(parser); return }
        let name = Self.localName(elementName)
        elements += 1
        guard stack.count < 64, elements <= 100_000 else { reject(parser); return }
        if stack.isEmpty {
            recognizedRoot = ["rss", "feed", "rdf"].contains(name)
            guard recognizedRoot else { reject(parser); return }
        }
        let inheritedBase = stack.last?.base ?? source.url
        let base = attributes["xml:base"].flatMap { FeedText.webURL($0, base: inheritedBase) } ?? inheritedBase
        stack.append(Frame(name: name, base: base, attributes: attributes))
        if entry == nil, name == "item" || name == "entry" { entry = Entry(depth: stack.count) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { appendText(string) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let value = String(data: CDATABlock, encoding: .utf8) { appendText(value) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let frame = stack.popLast() else { return }
        if var current = entry {
            if stack.count == current.depth {
                let value = frame.text.trimmingCharacters(in: .whitespacesAndNewlines)
                switch frame.name {
                case "title": if current.title.isEmpty { current.title = value }
                case "link":
                    if let href = frame.attributes["href"] {
                        let relation = frame.attributes["rel"]?.lowercased() ?? "alternate"
                        let type = frame.attributes["type"]?.lowercased()
                        if relation == "alternate", type == nil || type == "text/html" || type == "application/xhtml+xml" {
                            current.link = current.link ?? FeedText.webURL(href, base: frame.base)
                        }
                    } else if !value.isEmpty { current.link = current.link ?? FeedText.webURL(value, base: frame.base) }
                case "guid":
                    if frame.attributes["isPermaLink"]?.lowercased() != "false" { current.fallbackLink = FeedText.webURL(value, base: frame.base, allowRelative: false) }
                case "id": current.fallbackLink = FeedText.webURL(value, base: frame.base, allowRelative: false)
                case "description", "summary": if current.summary.isEmpty { current.summary = value }
                case "encoded", "content": if current.content.isEmpty { current.content = value }
                case "pubdate", "published", "date": if current.publication == nil, !value.isEmpty { current.publication = value }
                default: break
                }
                entry = current
            } else if stack.count + 1 == current.depth {
                let title = FeedText.clean(current.title, limit: 250)
                if let url = current.link ?? current.fallbackLink, !title.isEmpty, articles.count < 200 {
                    articles.append(CandidateArticle(title: title, url: url, sourceID: source.id, sourceName: source.name,
                                                     publishedAt: current.publication.flatMap(dates.parse),
                                                     excerpt: FeedText.clean(current.summary.isEmpty ? current.content : current.summary, limit: 800),
                                                     discoveredAt: now))
                }
                entry = nil
            }
        }
        if !["script", "style"].contains(frame.name) {
            appendText(frame.text + (Self.blockElements.contains(frame.name) ? " " : ""))
        }
    }

    // Explicitly reject declarations, even though external resolution is also disabled.
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { reject(parser) }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { reject(parser) }
    func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?, systemID: String?, notationName: String?) { reject(parser) }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { reject(parser); return nil }

    private func reject(_ parser: XMLParser) { rejected = true; parser.abortParsing() }
    private func appendText(_ value: String) {
        guard let entry, stack.count > entry.depth else { return }
        let remaining = 16_000 - stack[stack.count - 1].textCount
        if remaining > 0 {
            let addition = value.prefix(remaining)
            stack[stack.count - 1].text.append(contentsOf: addition)
            stack[stack.count - 1].textCount += addition.count
        }
    }
    private static func localName(_ name: String) -> String { String(name.split(separator: ":").last ?? Substring(name)).lowercased() }
    private static let blockElements: Set<String> = ["p", "div", "br", "li", "h1", "h2", "h3", "h4", "blockquote", "section", "article"]
}

private final class FeedDateParser {
    private let iso = ISO8601DateFormatter()
    private let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let legacy: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd"
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.dateFormat = format
        return formatter
    }
    func parse(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128 else { return nil }
        if let date = iso.date(from: trimmed) ?? fractionalISO.date(from: trimmed) { return date }
        return legacy.lazy.compactMap { $0.date(from: trimmed) }.first
    }
}

private enum FeedText {
    static func containsXMLDeclarations(_ data: Data) -> Bool {
        // Ignoring NUL bytes also detects declaration markers in UTF-16/32 documents.
        // CDATA may legitimately contain an HTML doctype; it cannot declare XML entities.
        let raw = String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
        let markup = raw.replacingOccurrences(of: "(?s)<!\\[CDATA\\[.*?\\]\\]>|<!--.*?-->", with: "", options: .regularExpression)
        return markup.range(of: "<!DOCTYPE", options: .caseInsensitive) != nil || markup.range(of: "<!ENTITY", options: .caseInsensitive) != nil
    }

    static func webURL(_ value: String, base: URL, allowRelative: Bool = true) -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 4_096, !value.contains(where: { $0.isNewline }),
              let url = URL(string: value, relativeTo: allowRelative ? base : nil)?.absoluteURL, URLSafety.isWeb(url),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443) || (components.scheme == "http" && components.port == 80) { components.port = nil }
        components.queryItems = components.queryItems?.filter {
            let name = $0.name.lowercased()
            return !name.hasPrefix("utm_") && !["fbclid", "gclid"].contains(name)
        }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url
    }

    static func clean(_ text: String, limit: Int) -> String {
        var value = String(text.prefix(16_000))
        for _ in 0..<2 { value = decodeEntities(value) }
        value = value.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1\\s*>", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?is)<!DOCTYPE\\b[^>]*>", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?s)<!--.*?-->", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "<\\s*/?\\s*[a-zA-Z][^>]*>", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(value.prefix(limit))
    }

    private static func decodeEntities(_ value: String) -> String {
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•", "copy": "©", "reg": "®"]
        guard let expression = try? NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);") else { return value }
        let matches = expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
        var result = value
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result), let tokenRange = Range(match.range(at: 1), in: result) else { continue }
            let token = String(result[tokenRange])
            var replacement = named[token]
            if token.hasPrefix("#") {
                let hexadecimal = token.hasPrefix("#x")
                let digits = token.dropFirst(hexadecimal ? 2 : 1)
                if let number = UInt32(digits, radix: hexadecimal ? 16 : 10), let scalar = UnicodeScalar(number), number >= 32 || [9, 10, 13].contains(number) {
                    replacement = String(scalar)
                }
            }
            if let replacement { result.replaceSubrange(range, with: replacement) }
        }
        return result
    }
}
