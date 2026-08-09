import Combine
import Foundation

enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case chinese

    static let storageKey = "Chronicle.interfaceLanguage"

    var id: String { rawValue }
}

@MainActor
final class DesktopLocalization: ObservableObject {
    static let shared = DesktopLocalization()

    @Published private(set) var language: InterfaceLanguage

    private let defaults: UserDefaults
    private let preferredLanguages: () -> [String]

    init(
        defaults: UserDefaults = .standard,
        preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages }
    ) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        language = InterfaceLanguage(
            rawValue: defaults.string(forKey: InterfaceLanguage.storageKey) ?? ""
        ) ?? .system
    }

    var usesChinese: Bool {
        switch language {
        case .system:
            preferredLanguages().first?.lowercased().hasPrefix("zh") == true
        case .english:
            false
        case .chinese:
            true
        }
    }

    func set(_ language: InterfaceLanguage) {
        guard self.language != language else { return }
        defaults.set(language.rawValue, forKey: InterfaceLanguage.storageKey)
        self.language = language
        NotificationCenter.default.post(name: .chronicleLanguageChanged, object: nil)
    }

    subscript(key: String) -> String {
        guard usesChinese else { return key }
        return Self.chinese[key] ?? key
    }

    func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: self[key],
            locale: usesChinese ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US"),
            arguments: arguments
        )
    }

    private static let chinese: [String: String] = [
        "System": "跟随系统",
        "English": "English",
        "简体中文": "简体中文",
        "Language": "语言",
        "General": "通用",
        "Launch at Login": "登录时启动",
        "Open Chronicle automatically when you sign in to your Mac.": "登录 Mac 时自动打开 Chronicle。",
        "Launch at Login is available only from the packaged app.": "“登录时启动”仅可在打包后的应用中使用。",

        "Capture": "Capture",
        "Search": "搜索",
        "Ask": "提问",
        "Browse": "浏览",
        "Review": "回顾",
        "Trash": "垃圾箱",
        "Settings": "设置",
        "File": "文件",
        "Capture a thought…": "记下一个想法…",
        "New Capture": "新建 Capture",
        "Close": "关闭",
        "Add file": "添加文件",
        "Record": "录音",
        "Stop": "停止",
        "Reminder": "提醒",
        "Saving…": "正在保存…",
        "Quick Look": "快速查看",
        "Remove attachment": "移除附件",
        "Attachments": "附件",
        "Open attachment": "打开附件",
        "%d attachments": "%d 个附件",
        "This image is too large to paste.": "粘贴的图片太大了。",
        "Sign in to add files.": "登录后可添加文件。",
        "Chronicle media": "Chronicle 媒体",
        "We couldn't read that file.": "无法读取这个文件。",
        "Google Drive is not configured for this app.": "此应用尚未配置 Google Drive。",
        "Google Drive is connected. You can return to Chronicle.": "Google Drive 已连接，可以返回 Chronicle。",
        "Chronicle could not connect to Google Drive. You can close this tab.": "Chronicle 无法连接 Google Drive，可以关闭此页面。",
        "This file is too large.": "这个文件太大了。",
        "Microphone access is required to record audio.": "录音需要麦克风权限。",
        "We couldn't save this Capture. Try again.": "无法保存这条 Capture，请重试。",
        "Search captures…": "搜索 Capture…",
        "Ask a question…": "问一个问题…",
        "⌘↩ Save": "⌘↩ 保存",
        "↩ Search": "↩ 搜索",
        "↩ Ask": "↩ 提问",
        "Keep visible": "保持可见",
        "Notify only — the capture stays in browse instead of hiding until due": "仅通知——到期前仍在浏览列表中显示",
        "Set a reminder": "设置提醒",
        "Thinking…": "思考中…",
        "Searching…": "搜索中…",
        "Searching your captures…": "正在搜索你的 Capture…",
        "⚠︎ Semantic search unavailable — keyword results.": "⚠︎ 语义搜索不可用——当前为关键词结果。",
        "No matches.": "没有匹配项。",
        "No recent captures.": "没有最近的 Capture。",
        "Recent": "最近",
        "Copy": "复制",
        "Share": "分享",
        "Share a read-only copy": "分享只读副本",
        "Anyone with the link can view this copy without signing in.": "任何获得链接的人无需登录即可查看此副本。",
        "Others will see": "对方将看到",
        "Only the Capture text is included. Media, transcripts, files, reminders, and Connections stay private.": "仅包含 Capture 文本。媒体、转录、文件、提醒和关联会保持私密。",
        "Loading share…": "正在加载分享…",
        "Share link": "分享链接",
        "Link expires": "链接有效期",
        "In 1 day": "1 天后",
        "In 7 days": "7 天后",
        "In 30 days": "30 天后",
        "Never": "永不过期",
        "Anyone with the link can keep viewing this copy until you revoke it.": "任何获得链接的人都可持续查看此副本，直到你撤销链接。",
        "Creating a link revokes the previous link for this Capture.": "创建链接会撤销这条 Capture 之前的分享链接。",
        "Revoke": "撤销",
        "Revoke this link?": "撤销此链接？",
        "This link will stop working immediately.": "此链接将立即失效。",
        "Copied": "已复制",
        "Creating…": "正在创建…",
        "Create link": "创建链接",
        "Sign in to share this Capture.": "登录后才能分享这条 Capture。",
        "Session expired. Sign in again to manage sharing.": "登录状态已过期，请重新登录后管理分享。",
        "This Capture can no longer be shared.": "这条 Capture 已无法分享。",
        "Sharing is not configured on this server.": "此服务器尚未配置分享功能。",
        "We couldn't update this share. Try again.": "无法更新此分享，请重试。",
        "Sync this Capture before sharing.": "请先同步这条 Capture，再进行分享。",
        "Only text Captures can be shared.": "只能分享包含文本的 Capture。",
        "Save before sharing": "请先保存再分享",
        "Shared copies": "分享副本",
        "Review and revoke Capture links that work without signing in.": "检查和撤销无需登录即可访问的 Capture 链接。",
        "Sign in to manage shared copies.": "登录后可管理分享副本。",
        "Loading shared copies…": "正在加载分享副本…",
        "Loading…": "正在加载…",
        "Load more": "加载更多",
        "No shared copies.": "暂无分享副本。",
        "Copy link": "复制链接",
        "Expired": "已过期",
        "No expiry": "永不过期",
        "Expires %@": "有效期至 %@",
        "Sources": "来源",
        "Sign in": "登录",
        "Sign In": "登录",
        "Sign in to ask across your captures.": "登录后可基于所有 Capture 提问。",
        "Sign in to search your captures.": "登录后可搜索你的 Capture。",
        "Sign in to edit this search result.": "登录后才能编辑这条搜索结果。",
        "No answer — not enough captures yet.": "暂时无法回答，相关 Capture 还不够。",

        "Search captures to link…": "搜索要关联的 Capture…",
        "Search to find captures to link.": "搜索要关联的 Capture。",
        "Press return to search.": "按回车键搜索。",
        "(media capture)": "（媒体 Capture）",
        "Capture deleted": "Capture 已删除",
        "Undo": "撤销",
        "More": "更多",
        "Open": "打开",
        "Pin to desktop": "钉到桌面",
        "Unpin from desktop": "从桌面取消固定",
        "Remove link": "取消关联",
        "Delete": "删除",
        "Todo": "待办",
        "Done": "完成",
        "Mark this capture as a todo": "将这条 Capture 标记为待办",
        "Tab": "Tab",
        "Cancel": "取消",
        "Save": "保存",
        "Unsaved changes": "有未保存的更改",
        "Keep editing": "继续编辑",
        "Discard": "放弃",
        "This Capture has no editable text.": "这条 Capture 没有可编辑的文本。",

        "Filter trash": "筛选垃圾箱",
        "Empty": "清空",
        "Empty Trash": "清空垃圾箱",
        "This can't be undone.": "此操作无法撤销。",
        "Delete Permanently": "永久删除",
        "Delete this capture permanently? This can't be undone.": "永久删除这条 Capture？此操作无法撤销。",
        "Permanently delete all %d captures in the trash?": "永久删除垃圾箱中的全部 %d 条 Capture？",
        "Trash is empty.": "垃圾箱是空的。",
        "No trashed captures match.": "没有匹配的已删除 Capture。",
        "Restore": "恢复",
        "Deleted %@": "删除于 %@",

        "Back": "返回",
        "Pinned": "已固定",
        "Pin": "固定",
        "Related": "相关",
        "Linked": "已关联",
        "Link": "关联",
        "Sign in to manage links.": "登录后可管理关联。",
        "No linked captures yet.": "还没有关联的 Capture。",
        "No related captures yet.": "还没有相关 Capture。",
        "Unpin from desktop (or press Esc)": "从桌面取消固定（或按 Esc）",

        "Account": "账户",
        "Signed in": "已登录",
        "Sign Out": "退出登录",
        "Not signed in": "未登录",
        "Sign In…": "登录…",
        "Sign in to sync captures and use server-backed recall.": "登录后可同步 Capture 并使用服务端召回。",
        "Server": "服务器",
        "The Chronicle API the desktop app talks to.": "桌面应用连接的 Chronicle API。",
        "Quick Capture Shortcut": "Quick Capture 快捷键",
        "Click the field, then press a shortcut (or double-tap Control).": "点击输入框后按下快捷键（或双击 Control）。",
        "Reminders": "提醒",
        "Show a system notification when a reminder is due": "提醒到期时显示系统通知",
        "Reminders are scheduled locally and fire even when the app is closed.": "提醒在本地调度，即使应用关闭也会触发。",
        "Retry Queue": "重试队列",
        "Refresh": "刷新",
        "All captures are synced.": "所有 Capture 均已同步。",
        "%d capture waiting to sync.": "有 %d 条 Capture 等待同步。",
        "%d captures waiting to sync.": "有 %d 条 Capture 等待同步。",
        "Retry Now": "立即重试",
        "Offline captures and edits sync here once you're online.": "离线 Capture 和编辑会在联网后从这里同步。",
        "Sign in to Chronicle": "登录 Chronicle",
        "Use the same account you use on the web.": "使用与网页端相同的账户。",
        "or use email": "或使用邮箱",
        "Email": "邮箱",
        "Password": "密码",
        "Continue with %@": "使用 %@ 继续",
        "Use HTTPS for remote servers (HTTP is allowed only on localhost).": "远程服务器必须使用 HTTPS（仅 localhost 可使用 HTTP）。",
        "Server URL saved.": "服务器地址已保存。",
        "Server URL saved. Sign in to this server.": "服务器地址已保存，请登录该服务器。",
        "Email and password are required.": "请输入邮箱和密码。",
        "Enter a valid email address.": "请输入有效的邮箱地址。",
        "MFA sign-in requires a newer Chronicle server.": "MFA 登录需要更新版本的 Chronicle 服务器。",
        "Sign in failed: no MFA token returned.": "登录失败：服务器未返回 MFA 令牌。",
        "Verify your identity": "验证身份",
        "Enter the code from your authenticator app, or use a recovery code.": "输入身份验证器中的代码，或使用恢复码。",
        "Authenticator or recovery code": "身份验证器代码或恢复码",
        "Enter your authenticator code or a recovery code.": "请输入身份验证器代码或恢复码。",
        "Verify": "验证",
        "Invalid or expired code. Try again.": "代码无效或已过期，请重试。",
        "Too many attempts. Try again later.": "尝试次数过多，请稍后再试。",
        "Sign in failed: no token returned.": "登录失败：服务器未返回令牌。",
        "Sign in failed. Check your email and password.": "登录失败，请检查邮箱和密码。",
        "Couldn't start %@ sign in.": "无法开始 %@ 登录。",
        "%@ returned an invalid response.": "%@ 返回了无效响应。",
        "%@ returned no sign-in code.": "%@ 未返回登录代码。",
        "Couldn't open %@ sign in.": "无法打开 %@ 登录。",
        "Couldn't finish %@ sign in. Try again.": "无法完成 %@ 登录，请重试。",
        "Signed in.": "已登录。",
        "Signed out.": "已退出登录。",
        "Synced %d; %d still waiting.": "已同步 %d 条；仍有 %d 条等待。",
        "Sync is already in progress.": "同步已在进行中。",
        "Sync couldn't finish. Try again.": "同步未能完成，请重试。",
        "Couldn't read the sync queue.": "无法读取同步队列。",

        "Webhooks": "Webhook",
        "POST a templated payload to an external service when a capture matches.": "Capture 匹配时向外部服务 POST 模板化数据。",
        "Add Rule": "添加规则",
        "Sign in to manage webhooks.": "登录后可管理 Webhook。",
        "No rules yet": "还没有规则",
        "e.g. captures mentioning an amount go to a ledger service.": "例如：将提到金额的 Capture 发送到记账服务。",
        "Edit": "编辑",
        "New Webhook": "新建 Webhook",
        "Edit Webhook": "编辑 Webhook",
        "Name": "名称",
        "Keywords": "关键词",
        "Semantic": "语义",
        "Payload": "负载",
        "Save & Test": "保存并测试",
        "Ledger": "记账",
        "comma-separated, any match fires; optional": "用逗号分隔，任一匹配即触发；可选",
        "describe what to match; empty = no semantic match": "描述要匹配的内容；留空则不做语义匹配",
        "Placeholders: [capture.text] [capture.id] [capture.created_at]": "占位符：[capture.text] [capture.id] [capture.created_at]",
        "keywords": "关键词",
        "semantic": "语义",
        "every capture": "所有 Capture",
        "Sign in to save webhooks.": "登录后可保存 Webhook。",
        "Sign in to test.": "登录后可测试。",
        "No captures yet to test against.": "还没有可用于测试的 Capture。",
        "matched": "匹配",
        "no match": "未匹配",
        "Against your latest capture: %@ (score %@).": "针对最新 Capture：%@（分数 %@）。",
        "Test failed: %@": "测试失败：%@",
        "Chronicle Settings": "Chronicle 设置",

        "Quick Capture": "Quick Capture",
        "Open Chronicle": "打开 Chronicle",
        "Settings…": "设置…",
        "Quit Chronicle": "退出 Chronicle",
        "Redo": "重做",
        "Cut": "剪切",
        "Paste": "粘贴",
        "Select All": "全选",
        "Collapse tabs": "收起标签栏",
        "Expand tabs": "展开标签栏",

        "No captures yet.": "还没有 Capture。",
        "Revisit what you captured before.": "重温你之前记下的内容。",
        "On this day": "历史上的今天",
        "Rediscover": "重新发现",
        "Nothing to revisit yet. Older captures will surface here over time.": "还没有可回顾的内容，较早的 Capture 会随着时间出现在这里。",
        "Sign in to review your synced captures.": "登录后可回顾已同步的 Capture。",
        "No local captures yet — capture something or sign in to sync.": "还没有本地 Capture，先记下一些内容，或登录后同步。",
        "Ask about anything you've captured.": "询问任何你记下过的内容。",
        "Question": "问题",
        "Ask works across your synced captures.": "提问会检索所有已同步的 Capture。",
        "Sign in below to use server-backed recall.": "请先登录以使用服务端召回。",
        "Ask a question, e.g. what did I work on this week": "问一个问题，例如：我这周做了什么",
        "Sign in to ask across your captures": "登录后可基于所有 Capture 提问",
        "↩ Ask  ·  ⇧↩ New line": "↩ 提问  ·  ⇧↩ 换行",
        "Not signed in — sign in from Settings to edit.": "尚未登录——请从设置中登录后编辑。",

        "Session expired — sign in again from Settings.": "会话已过期——请从设置中重新登录。",
        "Ask is unavailable — the recall service is offline.": "提问不可用——召回服务当前离线。",
        "Error: %@": "错误：%@",
        "just now": "刚刚",
        "%dm": "%d 分钟前",
        "%dh": "%d 小时前",
        "%dd": "%d 天前",
        "Saved locally — sign in to sync": "已保存到本地——登录后同步",
        "Capture saved": "Capture 已保存",
        "Capture failed": "Capture 失败",
        "Capture synced": "Capture 已同步",
        "Capture saved locally": "Capture 已保存到本地",
        "Sync will retry later.": "稍后会重试同步。",
        "Chronicle — signed out · %d capture waiting to sync": "Chronicle · 已退出登录 · %d 条 Capture 等待同步",
        "Chronicle — signed out · %d captures waiting to sync": "Chronicle · 已退出登录 · %d 条 Capture 等待同步",
        "Chronicle — signed out · sign in to sync": "Chronicle — 已退出登录 · 登录后同步",
    ]
}

@MainActor
func L(_ key: String) -> String {
    DesktopLocalization.shared[key]
}

extension Notification.Name {
    static let chronicleLanguageChanged = Notification.Name("chronicleLanguageChanged")
}
