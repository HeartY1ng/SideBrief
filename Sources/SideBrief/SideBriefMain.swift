import AppKit
import Foundation
import BriefCore

@main
enum SideBriefMain {
    @MainActor
    static func main() async {
        let args = CommandLine.arguments
        func argument(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
        let directory = argument("--data-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SideBrief", isDirectory: true)
        if args.contains("--help") {
            print("SideBrief — Mac 每日资讯悬浮窗\n\n--demo                 使用明确标记的演示内容，不调用 Codex\n--data-dir PATH        指定数据目录（适合测试）\n--check-codex          检查本机 CLI 和登录，无模型调用\n--check-feeds          检查配置中的公开来源，无模型调用\n--generate-once        生成一份真实精选并保存后退出（使用 Codex 额度）\n--codex-path PATH      为命令行检查指定 Codex 路径")
            return
        }
        if args.contains("--check-codex") {
            do {
                let result = try await CodexService().checkConnection(configuredPath: argument("--codex-path") ?? "")
                print(result.message); print("CLI: \(result.executableURL.path)")
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if args.contains("--check-feeds") || args.contains("--generate-once") {
            do {
                let store = try BriefStore(directory: directory)
                var settings = try store.loadSettings()
                if let path = argument("--codex-path") { settings.codexPath = path }
                let batch = try await FeedService().fetch(sources: settings.sources)
                for report in batch.reports { print("\(report.name): \(report.error ?? "\(report.count) 条")") }
                print("可用候选：\(batch.articles.count)")
                if args.contains("--generate-once") {
                    let lock = try GenerationLock(directory: store.directory); defer { lock.release() }
                    let generated = try await CodexService().generate(articles: batch.articles, settings: settings, previous: try store.loadHistory())
                    let now = Date()
                    let edition = BriefEdition(dayKey: DailySchedule.dayKey(for: now, timeZone: settings.timeZone), createdAt: now, timeZoneID: settings.timeZoneID, headline: generated.headline, items: generated.items, sources: batch.reports)
                    try store.saveEdition(edition)
                    print("已生成：\(edition.items.count) 条 · \(edition.dayKey)")
                }
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        let model = AppModel(directory: directory, demo: args.contains("--demo"))
        let delegate = AppDelegate(model: model)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
