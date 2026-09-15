import Foundation
import BriefCore

enum DemoContent {
    static var edition: BriefEdition {
        let articles: [(String, String, String, String, String, String)] = [
            ("让重复工作，变成可以复用的流程", "把文件整理、内容处理和日常工具连接起来。先从一个反复执行的小任务开始。", "关注自动化流程的可维护性和失败后的恢复方式。", "自动化", "n8n", "https://github.com/n8n-io/n8n"),
            ("为个人知识库，找到合适的本地模型", "本地模型工具可以成为知识整理的基础。先确认设备条件，再用少量文档验证检索效果。", "适合关心本地知识库和个人资料管理的人。", "本地 AI", "Ollama", "https://github.com/ollama/ollama"),
            ("把软件能力，延伸到真实的设备", "从家庭自动化了解设备、传感器与软件如何协作，发现值得自己动手的小场景。", "适合探索软硬件结合与个人自动化项目。", "软硬结合", "Home Assistant", "https://github.com/home-assistant/core")
        ]
        var items = articles.enumerated().map { index, article in
            BriefItem(id: "demo-\(index)", title: article.0, summary: article.1, reason: article.2, section: .highlights, tag: article.3, sourceName: article.4, url: URL(string: article.5)!)
        }
        items.append(.init(id: "demo-news", title: "从原始来源，了解模型与工具的变化", summary: "每条动态都保留来源链接，方便继续核实。", reason: "演示简讯布局", section: .updates, tag: "动态", sourceName: "Hugging Face", url: URL(string: "https://huggingface.co/blog")!))
        items.append(.init(id: "demo-watch", title: "值得持续关注的项目，会有自己的位置", summary: "有新增能力或可信采用案例时，再说明它的变化。", reason: "演示持续关注布局；此条不代表真实项目趋势。", section: .watch, tag: "观察", sourceName: "GitHub", url: URL(string: "https://github.com")!))
        return BriefEdition(dayKey: DailySchedule.dayKey(for: Date(), timeZone: AppSettings().timeZone), headline: "留一点注意力，给真正值得尝试的事。", items: items, sources: [], isDemo: true)
    }
}
