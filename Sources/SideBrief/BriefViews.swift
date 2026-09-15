import AppKit
import BriefCore
import SwiftUI

private enum BriefPalette {
    static let accent = Color(red: 0.10, green: 0.49, blue: 0.42)
    static let background = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.10, green: 0.12, blue: 0.12, alpha: 1)
            : NSColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1)
    })
    static let card = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.15, green: 0.17, blue: 0.17, alpha: 1)
            : NSColor(red: 1, green: 1, blue: 0.99, alpha: 1)
    })
    static let rule = Color.primary.opacity(0.08)
}

@MainActor
struct BriefRootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(BriefPalette.rule).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusMessages
                    if let edition = model.edition {
                        editionContent(edition)
                    } else {
                        onboarding
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            footer
        }
        .frame(minWidth: 340, idealWidth: 392, maxWidth: .infinity, minHeight: 480, idealHeight: 650)
        .background(BriefPalette.background)
        .tint(BriefPalette.accent)
        .overlay(alignment: .bottom) { toastView }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(BriefPalette.rule, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(BriefPalette.accent)
                    .accessibilityHidden(true)
                Text("SIDE BRIEF")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(2)
                Text("侧读")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button {
                    if model.isRefreshing { model.cancelRefresh() } else { model.refresh() }
                } label: {
                    Image(systemName: model.isRefreshing ? "xmark" : "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(BriefIconButtonStyle())
                .disabled(!model.isRefreshing && !model.canRefresh)
                .help(model.isRefreshing ? "取消本次更新" : "立即更新资讯")
                .accessibilityLabel(model.isRefreshing ? "取消本次更新" : "立即更新资讯")
            }
            HStack(alignment: .firstTextBaseline) {
                Text(dateLabel)
                    .font(.system(size: 19, weight: .semibold))
                Spacer(minLength: 6)
                Text("每天，值得看的一点")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    @ViewBuilder private var statusMessages: some View {
        if model.isDemo || model.edition?.isDemo == true {
            BriefNotice(symbol: "paintpalette", color: .orange) {
                Text("演示数据 · 用于预览界面，并非今日资讯")
                    .font(.system(size: 11, weight: .medium))
            }
        }
        if !model.isOnline {
            BriefNotice(symbol: "wifi.slash", color: .orange) {
                Text(model.settings.automaticUpdates && model.settings.hasCompletedSetup
                     ? "当前离线。已保留现有内容，联网后自动补更。"
                     : "当前离线。已保留现有内容，联网后可手动更新。")
                    .font(.system(size: 11))
            }
        }
        if model.isRefreshing {
            HStack(alignment: .top, spacing: 10) {
                ProgressView().controlSize(.small).padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在准备新一期")
                        .font(.system(size: 12, weight: .semibold))
                    Text(model.phaseText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(BriefPalette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
        if let message = model.errorMessage, !message.isEmpty {
            BriefNotice(symbol: "exclamationmark.circle", color: .orange) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    HStack(spacing: 14) {
                        if model.canRetryGeneration {
                            Button("重新生成") { model.refresh() }
                                .disabled(!model.canRefresh || model.isRefreshing)
                        }
                        Button("打开设置") { model.openSettings() }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11, weight: .medium))
                }
            }
        }
    }

    private func editionContent(_ edition: BriefEdition) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            if !edition.headline.isEmpty {
                Text(edition.headline)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(BriefSection.allCases, id: \.self) { section in
                let items = edition.items(in: section)
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        BriefSectionHeading(section: section, count: items.count)
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            BriefArticleView(
                                item: item,
                                index: index + 1,
                                timeZone: TimeZone(identifier: edition.timeZoneID) ?? model.settings.timeZone,
                                onOpen: { model.openArticle(item) },
                                onCopy: { model.copyResearch(item) }
                            )
                        }
                    }
                }
            }
            sourceSummary(edition)
        }
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "sun.horizon")
                    .font(.system(size: 33, weight: .light))
                    .foregroundStyle(BriefPalette.accent)
                    .padding(.top, 15)
                    .accessibilityHidden(true)
                Text("给每天，留一点新发现。")
                    .font(.system(size: 23, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("AI 新动态、开源项目和效率工具。\n每天筛出几条值得看的，扫一眼就好。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(6)
                Text("通过本机 Codex 生成，仍需联网，并使用现有 Codex 额度。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 16) {
                onboardingStep("1", title: "连接本机 Codex", detail: "使用你已登录的 Codex 生成精选，会占用已有可用额度。")
                onboardingStep("2", title: "生成第一期", detail: "从公开来源获取资讯，按你的兴趣挑选；点标题即可在浏览器阅读。")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BriefPalette.card, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button("检查 Codex 连接") { model.checkCodex() }
                        .buttonStyle(.bordered)
                        .disabled(model.isRefreshing)
                    Button("生成第一期") { model.startSetup() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canRefresh)
                }
                Text(model.connectionStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("设置兴趣、更新时间与来源") { model.openSettings() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            Text("内容保存在本机。暂时断网时，上一期依然可读。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 12)
    }

    private func onboardingStep(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(BriefPalette.accent)
                .frame(width: 23, height: 23)
                .background(BriefPalette.accent.opacity(0.09), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func sourceSummary(_ edition: BriefEdition) -> some View {
        let failures = edition.sources.filter { $0.error != nil }
        if !edition.sources.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(edition.sources) { source in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: source.error == nil ? "checkmark.circle" : "exclamationmark.circle")
                                .foregroundStyle(source.error == nil ? BriefPalette.accent : .orange)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(source.name) · \(source.count) 条候选")
                                if let error = source.error {
                                    Text(error).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                Text(failures.isEmpty ? "来自 \(edition.sources.count) 个资讯源" : "资讯源状态 · \(failures.count) 个暂不可用")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(BriefPalette.rule).frame(height: 1)
            HStack(spacing: 10) {
                Circle()
                    .fill(model.isOnline ? BriefPalette.accent : Color.orange)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.lastUpdatedText).font(.system(size: 10))
                    Text(model.scheduleText).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { model.openSettings() } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(BriefIconButtonStyle())
                    .help("设置")
                    .accessibilityLabel("打开设置")
                Button { model.collapse() } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(BriefIconButtonStyle())
                    .help("收起到屏幕右侧")
                    .accessibilityLabel("收起到屏幕右侧")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(BriefPalette.background)
    }

    @ViewBuilder private var toastView: some View {
        if let toast = model.toast, !toast.isEmpty {
            Text(toast)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(BriefPalette.rule))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
                .padding(.bottom, 68)
                .allowsHitTesting(false)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var dateLabel: String {
        if let edition = model.edition {
            let input = DateFormatter()
            input.locale = Locale(identifier: "en_US_POSIX")
            input.timeZone = TimeZone(identifier: edition.timeZoneID)
            input.dateFormat = "yyyy-MM-dd"
            if let date = input.date(from: edition.dayKey) {
                return formattedDate(date, timeZone: input.timeZone)
            }
            return edition.dayKey
        }
        return formattedDate(Date(), timeZone: model.settings.timeZone)
    }

    private func formattedDate(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: date)
    }
}

private struct BriefSectionHeading: View {
    let section: BriefSection
    let count: Int

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(BriefPalette.accent)
                .frame(width: 3, height: 11)
            Text(section.label)
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(String(format: "%02d", count))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct BriefArticleView: View {
    let item: BriefItem
    let index: Int
    let timeZone: TimeZone
    let onOpen: () -> Void
    let onCopy: () -> Void
    @State private var isHovered = false

    private var isCompact: Bool { item.section == .updates }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 6 : 8) {
            if !isCompact { topLine }
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(item.title)
                            .font(.system(size: isCompact ? 13 : 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(item.title)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(isHovered ? BriefPalette.accent : Color.secondary)
                            .padding(.top, 4)
                    }
                    Text(primaryDescription)
                        .font(.system(size: isCompact ? 11 : 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(2)
                        .lineLimit(item.section == .watch ? 3 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(fullDescription)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(item.title)\n\n\(fullDescription)\n\n在默认浏览器打开：\(item.url.absoluteString)")
            .accessibilityLabel("\(item.title)，在浏览器打开原始来源")
            .accessibilityHint(fullDescription)

            if item.section == .watch && !item.reason.isEmpty && item.reason != item.summary {
                Text(item.reason)
                    .font(.system(size: 11))
                    .foregroundStyle(BriefPalette.accent)
                    .lineSpacing(2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(fullDescription)
                    .padding(.leading, 9)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(BriefPalette.accent.opacity(0.25)).frame(width: 2)
                    }
            }
            sourceLine
        }
        .padding(12)
        .background(BriefPalette.card, in: RoundedRectangle(cornerRadius: isCompact ? 10 : 13))
        .overlay {
            RoundedRectangle(cornerRadius: isCompact ? 10 : 13)
                .stroke(isHovered ? BriefPalette.accent.opacity(0.3) : BriefPalette.rule, lineWidth: 1)
        }
        .onHover { isHovered = $0 }
    }

    private var primaryDescription: String {
        if item.section == .highlights && !item.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return item.reason
        }
        return item.summary
    }

    private var fullDescription: String {
        [item.summary, item.reason == item.summary ? "" : item.reason]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    private var topLine: some View {
        HStack(spacing: 7) {
            Text(item.tag.isEmpty ? (item.section == .watch ? "项目追踪" : "值得一看") : item.tag)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(BriefPalette.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(BriefPalette.accent.opacity(0.08), in: Capsule())
            if let metrics = item.metrics {
                Label(metrics.stars.formatted(), systemImage: "star")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help("采集时的 GitHub 星标数，不代表增长量")
            }
            Spacer(minLength: 0)
            if item.section == .highlights {
                Text(String(format: "%02d", index))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var sourceLine: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("\(item.sourceName) · \(publicationLabel)")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onCopy) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 10))
            }
            .buttonStyle(BriefIconButtonStyle(size: 24))
            .help("复制研究指令，粘贴到 AI 对话中继续了解")
            .accessibilityLabel("复制关于\(item.title)的研究指令")
        }
    }

    private var publicationLabel: String {
        let isRepository = item.metrics != nil
        guard let date = item.publishedAt else { return isRepository ? "创建时间未提供" : "发布时间未提供" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return "\(isRepository ? "仓库创建于" : "发布于") \(formatter.string(from: date))"
    }
}

private struct BriefNotice<Content: View>: View {
    let symbol: String
    let color: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .padding(.top, 1)
                .accessibilityHidden(true)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(11)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct BriefIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size)
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? (hovered ? BriefPalette.accent : Color.secondary) : Color.secondary.opacity(0.35))
                .frame(width: size, height: size)
                .background(Color.primary.opacity(configuration.isPressed ? 0.10 : (hovered ? 0.05 : 0)), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

struct CollapsedTabView: View {
    let onExpand: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onExpand) {
            VStack(spacing: 11) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                VStack(spacing: 3) {
                    Text("侧")
                    Text("读")
                }
                .font(.system(size: 11, weight: .semibold))
                Circle().fill(BriefPalette.accent).frame(width: 4, height: 4)
            }
            .frame(width: 30, height: 112)
            .background(hovered ? BriefPalette.card : BriefPalette.background)
            .overlay(alignment: .leading) {
                Rectangle().fill(BriefPalette.accent.opacity(hovered ? 0.8 : 0.35)).frame(width: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("展开侧读")
        .accessibilityLabel("展开侧读资讯悬浮窗")
        .frame(width: 30, height: 112)
    }
}

@MainActor
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var draft: AppSettings
    @State private var sourceName = ""
    @State private var sourceURL = ""
    @State private var localError: String?
    @State private var saveFailed = false

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    scheduleSection
                    interestsSection
                    codexSection
                    sourcesSection
                }
                .padding(24)
            }
            Divider()
            if let message = localError ?? (saveFailed ? model.errorMessage : nil) {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }
            settingsFooter
        }
        .frame(minWidth: 520, idealWidth: 560, maxWidth: .infinity, minHeight: 520, idealHeight: 680)
        .background(BriefPalette.background)
        .tint(BriefPalette.accent)
    }

    private var settingsHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 19))
                .foregroundStyle(BriefPalette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("让侧读更懂你").font(.system(size: 19, weight: .semibold))
                Text("调整每日节奏、兴趣和资讯来源。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
    }

    private var scheduleSection: some View {
        SettingsSection(title: "每日更新", symbol: "clock") {
            Toggle("每天自动生成一期精选", isOn: $draft.automaticUpdates)
                .toggleStyle(.switch)
                .controlSize(.small)
            HStack(spacing: 8) {
                Text("更新时间").font(.system(size: 12))
                Spacer()
                TextField("时", value: $draft.hour, format: .number)
                    .frame(width: 46)
                    .accessibilityLabel("更新小时，0 至 23")
                Text(":").foregroundStyle(.secondary)
                TextField("分", value: $draft.minute, format: .number)
                    .frame(width: 46)
                    .accessibilityLabel("更新分钟，0 至 59")
            }
            .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                Text("时区").font(.system(size: 12))
                TextField("Asia/Shanghai", text: $draft.timeZoneID)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("更新时区")
                Menu("常用") {
                    Button("北京时间") { draft.timeZoneID = "Asia/Shanghai" }
                    Button("Mac 当前时区") { draft.timeZoneID = TimeZone.current.identifier }
                    Button("UTC") { draft.timeZoneID = "Etc/UTC" }
                }
                .fixedSize()
            }
            settingsHint("默认北京时间 08:00。断网或休眠时保留上一期，联网或唤醒后补更；应用需要保持运行。")
        }
    }

    private var interestsSection: some View {
        SettingsSection(title: "你的兴趣", symbol: "sparkle") {
            TextEditor(text: $draft.interests)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(height: 80)
                .background(BriefPalette.card, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(BriefPalette.rule))
                .accessibilityLabel("关注的领域与使用场景")
            settingsHint("写下关注领域和实际用途，例如自动化工作、软硬件结合、本地知识库。精选会优先参考这些偏好。")
        }
    }

    private var codexSection: some View {
        SettingsSection(title: "本机 Codex", symbol: "terminal") {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "desktopcomputer").foregroundStyle(BriefPalette.accent)
                Text(model.connectionStatus)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Codex 可执行文件路径")
                .font(.system(size: 11, weight: .medium))
            TextField("留空，自动检测", text: $draft.codexPath)
                .font(.system(size: 11, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Codex 可执行文件的绝对路径，留空自动检测")
            settingsHint("使用已安装并登录的 Codex，生成内容会占用你的可用额度。路径修改后保存生效。首版无需填写 API Key。")
        }
    }

    private var sourcesSection: some View {
        SettingsSection(title: "资讯来源", symbol: "dot.radiowaves.left.and.right") {
            VStack(spacing: 0) {
                ForEach($draft.sources) { $source in
                    sourceRow($source)
                    if source.id != draft.sources.last?.id {
                        Divider().padding(.horizontal, 12)
                    }
                }
            }
            .background(BriefPalette.card, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(BriefPalette.rule))
            VStack(alignment: .leading, spacing: 8) {
                Text("添加 RSS / Atom 来源")
                    .font(.system(size: 11, weight: .medium))
                TextField("来源名称", text: $sourceName)
                    .accessibilityLabel("自定义资讯来源名称")
                HStack(spacing: 8) {
                    TextField("https://example.com/feed.xml", text: $sourceURL)
                        .accessibilityLabel("自定义 RSS 或 Atom 的 HTTPS 地址")
                    Button(action: addSource) {
                        Label("添加", systemImage: "plus")
                    }
                    .disabled(sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .textFieldStyle(.roundedBorder)
            settingsHint("支持公开的 HTTPS RSS / Atom 地址。关闭来源后，下次生成不再采集该来源。")
        }
    }

    private func sourceRow(_ source: Binding<FeedSource>) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: source.enabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.wrappedValue.name).font(.system(size: 12, weight: .medium))
                    Text(source.wrappedValue.url.host ?? source.wrappedValue.url.absoluteString)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(source.wrappedValue.url.absoluteString)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            if !AppSettings.defaultSources.contains(where: { $0.id == source.wrappedValue.id }) {
                Button {
                    let id = source.wrappedValue.id
                    draft.sources.removeAll { $0.id == id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(BriefIconButtonStyle(size: 24))
                .help("删除自定义来源")
                .accessibilityLabel("删除来源\(source.wrappedValue.name)")
            }
        }
        .padding(12)
    }

    private var settingsFooter: some View {
        HStack(spacing: 12) {
            Text("偏好与资讯保存在本机")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button("取消") { model.closeSettings() }
                .keyboardShortcut(.cancelAction)
            Button("保存设置") {
                localError = nil
                if model.saveSettings(draft) {
                    saveFailed = false
                    model.closeSettings()
                } else {
                    saveFailed = true
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func settingsHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func addSource() {
        let name = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawURL = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let url = URL(string: rawURL), URLSafety.isFeed(url) else {
            localError = "请填写来源名称和有效的 HTTPS RSS / Atom 地址。"
            return
        }
        guard !draft.sources.contains(where: { $0.url.absoluteString == url.absoluteString }) else {
            localError = "这个来源地址已经在列表中。"
            return
        }
        draft.sources.append(FeedSource(name: name, url: url))
        sourceName = ""
        sourceURL = ""
        localError = nil
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
