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

        "Capture": "捕获",
        "Search": "搜索",
        "Ask": "提问",
        "Browse": "浏览",
        "Trash": "垃圾箱",
        "Settings": "设置",
        "Capture a thought…": "捕获一个想法…",
        "Search captures…": "搜索捕获…",
        "Ask a question…": "问一个问题…",
        "⌘↩ Save": "⌘↩ 保存",
        "↩ Search": "↩ 搜索",
        "↩ Ask": "↩ 提问",
        "Keep visible": "保持可见",
        "Notify only — the capture stays in browse instead of hiding until due": "仅通知——到期前仍在浏览列表中显示",
        "Set a reminder": "设置提醒",
        "Thinking…": "思考中…",
        "Searching…": "搜索中…",
        "Searching your captures…": "正在搜索你的捕获…",
        "⚠︎ Semantic search unavailable — keyword results.": "⚠︎ 语义搜索不可用——当前为关键词结果。",
        "No matches.": "没有匹配项。",
        "No recent captures.": "没有最近的捕获。",
        "Recent": "最近",
        "Copy": "复制",
        "Sources": "来源",
        "Sign in": "登录",
        "Sign In": "登录",
        "Sign in to ask across your captures.": "登录后可基于所有捕获提问。",
        "Sign in to search your captures.": "登录后可搜索你的捕获。",
        "Sign in to edit this search result.": "登录后才能编辑这条搜索结果。",
        "No answer — not enough captures yet.": "暂时无法回答——相关捕获还不够。",

        "Search captures to link…": "搜索要关联的捕获…",
        "Search to find captures to link.": "搜索要关联的捕获。",
        "Press return to search.": "按回车键搜索。",
        "(media capture)": "（媒体捕获）",
        "Capture deleted": "捕获已删除",
        "Undo": "撤销",
        "More": "更多",
        "Open": "打开",
        "Pin to desktop": "钉到桌面",
        "Unpin from desktop": "从桌面取消固定",
        "Remove link": "取消关联",
        "Delete": "删除",
        "Todo": "待办",
        "Done": "完成",
        "Mark this capture as a todo": "将这条捕获标记为待办",
        "Tab": "Tab",
        "Cancel": "取消",
        "Save": "保存",
        "Unsaved changes": "有未保存的更改",
        "Keep editing": "继续编辑",
        "Discard": "放弃",

        "Filter trash": "筛选垃圾箱",
        "Empty": "清空",
        "Empty Trash": "清空垃圾箱",
        "This can't be undone.": "此操作无法撤销。",
        "Delete Permanently": "永久删除",
        "Delete this capture permanently? This can't be undone.": "永久删除这条捕获？此操作无法撤销。",
        "Permanently delete all %d captures in the trash?": "永久删除垃圾箱中的全部 %d 条捕获？",
        "Trash is empty.": "垃圾箱是空的。",
        "No trashed captures match.": "没有匹配的已删除捕获。",
        "Restore": "恢复",
        "Deleted %@": "删除于 %@",

        "Back": "返回",
        "Pinned": "已固定",
        "Pin": "固定",
        "Related": "相关",
        "Linked": "已关联",
        "Link": "关联",
        "Sign in to manage links.": "登录后可管理关联。",
        "No linked captures yet.": "还没有关联的捕获。",
        "No related captures yet.": "还没有相关捕获。",
        "Unpin from desktop (or press Esc)": "从桌面取消固定（或按 Esc）",

        "Account": "账户",
        "Signed in": "已登录",
        "Sign Out": "退出登录",
        "Not signed in": "未登录",
        "Sign In…": "登录…",
        "Sign in to sync captures and use server-backed recall.": "登录后可同步捕获并使用服务端召回。",
        "Server": "服务器",
        "The Chronicle API the desktop app talks to.": "桌面应用连接的 Chronicle API。",
        "Quick Capture Shortcut": "快速捕获快捷键",
        "Click the field, then press a shortcut (or double-tap Control).": "点击输入框后按下快捷键（或双击 Control）。",
        "Reminders": "提醒",
        "Show a system notification when a reminder is due": "提醒到期时显示系统通知",
        "Reminders are scheduled locally and fire even when the app is closed.": "提醒在本地调度，即使应用关闭也会触发。",
        "Retry Queue": "重试队列",
        "Refresh": "刷新",
        "All captures are synced.": "所有捕获均已同步。",
        "%d capture waiting to sync.": "有 %d 条捕获等待同步。",
        "%d captures waiting to sync.": "有 %d 条捕获等待同步。",
        "Retry Now": "立即重试",
        "Offline captures and edits sync here once you're online.": "离线捕获和编辑会在联网后从这里同步。",
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
        "MFA accounts can't sign in from the desktop yet.": "桌面端暂不支持 MFA 账户登录。",
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
        "POST a templated payload to an external service when a capture matches.": "捕获匹配时向外部服务 POST 模板化数据。",
        "Add Rule": "添加规则",
        "Sign in to manage webhooks.": "登录后可管理 Webhook。",
        "No rules yet": "还没有规则",
        "e.g. captures mentioning an amount go to a ledger service.": "例如：提到金额的捕获发送到记账服务。",
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
        "every capture": "所有捕获",
        "Sign in to save webhooks.": "登录后可保存 Webhook。",
        "Sign in to test.": "登录后可测试。",
        "No captures yet to test against.": "还没有可用于测试的捕获。",
        "matched": "匹配",
        "no match": "未匹配",
        "Against your latest capture: %@ (score %@).": "针对最新捕获：%@（分数 %@）。",
        "Test failed: %@": "测试失败：%@",
        "Chronicle Settings": "Chronicle 设置",

        "Quick Capture": "快速捕获",
        "Open Chronicle": "打开 Chronicle",
        "Settings…": "设置…",
        "Quit Chronicle": "退出 Chronicle",
        "Redo": "重做",
        "Cut": "剪切",
        "Paste": "粘贴",
        "Select All": "全选",
        "Collapse tabs": "收起标签栏",
        "Expand tabs": "展开标签栏",

        "No captures yet.": "还没有捕获。",
        "No local captures yet — capture something or sign in to sync.": "还没有本地捕获——先捕获一些内容，或登录后同步。",
        "Ask about anything you've captured.": "询问任何你捕获过的内容。",
        "Question": "问题",
        "Ask works across your synced captures.": "提问会检索所有已同步的捕获。",
        "Sign in below to use server-backed recall.": "请先登录以使用服务端召回。",
        "Ask a question, e.g. what did I work on this week": "问一个问题，例如：我这周做了什么",
        "Sign in to ask across your captures": "登录后可基于所有捕获提问",
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
        "Capture saved": "捕获已保存",
        "Capture failed": "捕获失败",
        "Capture synced": "捕获已同步",
        "Capture saved locally": "捕获已保存到本地",
        "Sync will retry later.": "稍后会重试同步。",
        "Chronicle — signed out · %d capture waiting to sync": "Chronicle — 已退出登录 · %d 条捕获等待同步",
        "Chronicle — signed out · %d captures waiting to sync": "Chronicle — 已退出登录 · %d 条捕获等待同步",
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
