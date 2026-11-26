import Foundation
import Security
import SwiftUI
import UserNotifications

// MARK: - 应用内日志（诊断用）
//
// 原生版之前没有日志功能，出了问题只能靠猜。关键步骤都记下来，
// 在「我的」页点「导出日志」可以分享出去。
// build 64 修：原来只记内存，app 一关日志就全没了，导出是空的。
// 现在每行写磁盘（app.log），启动时读回来接着记，重启还在。
// 可变状态全由 NSLock 保护，所以标 @unchecked Sendable（编译器无法自行证明）。
// 不含密码（密码只传给教务服务器，绝不记日志）。
final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.h2sy60.AppLogger.io", qos: .utility)
    private var lines: [String] = []
    /// 是否已有一次落盘在队列里（合并突发写入，别每条日志都全量重写文件）。
    private var writeScheduled = false
    /// 清空代次：clear() 后代次 +1，之前排队的旧快照写入直接跳过，
    /// 不会把刚清掉的日志又写回来。
    private var generation = 0
    private let maxLines = 2000
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    /// 日志文件（Documents/app.log）。
    private static var logFileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("app.log")
    }

    private init() {
        // 启动时把磁盘上的旧日志读回来，接着记。
        if let data = try? Data(contentsOf: Self.logFileURL),
           let text = String(data: data, encoding: .utf8) {
            lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        }
    }

    func log(_ message: String) {
        lock.lock()
        lines.append("[\(formatter.string(from: Date()))] \(message)")
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        // 已有落盘在排队就不重复排：突发的一串日志合并成一次全量写，
        // 写的时候现取最新快照，不会丢行。
        let shouldSchedule = !writeScheduled
        if shouldSchedule { writeScheduled = true }
        let gen = generation
        lock.unlock()
        guard shouldSchedule else { return }
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.writeScheduled = false
            let snapshot = self.lines
            let currentGen = self.generation
            self.lock.unlock()
            // 排队期间被 clear() 过：这份旧快照别写了（clear 已负责删文件）。
            guard currentGen == gen else { return }
            let text = snapshot.joined(separator: "\n") + "\n"
            try? text.write(to: Self.logFileURL, atomically: true, encoding: .utf8)
        }
    }

    /// 导出文本：带表头，永远不为空（没日志时写明原因）。
    func exportText() -> String {
        lock.lock()
        defer { lock.unlock() }
        var header = "周周有善 日志\n"
        header += "导出时间：\(formatter.string(from: Date()))\n"
        header += "共 \(lines.count) 条\n"
        header += "---\n"
        if lines.isEmpty {
            return header + "（暂无日志：app 刚启动，还没产生任何记录。做一次刷新或登录后再导出。）"
        }
        return header + lines.joined(separator: "\n")
    }

    /// 清空日志（内存 + 磁盘文件一起清）。
    /// 删文件也走 ioQueue（串行队列，和落盘写入排队执行）：之前同步删、
    /// 异步写，排队中的旧快照可能在删除之后又把文件写回来。
    func clear() {
        lock.lock()
        lines.removeAll()
        generation += 1
        lock.unlock()
        ioQueue.async {
            try? FileManager.default.removeItem(at: Self.logFileURL)
        }
    }
}

// MARK: - 账号持久化（修“每次退出都要重新登录”）
//
// 学校 + 学号放 UserDefaults，密码放系统钥匙串（Keychain）。
// 按学校分开存：切学校时保存当前输入，回来接着用（和 Flutter accountsBySchool 一个意思）。
// 桂工登录每次都要验证码，启动时只能预填账号 + 自动取验证码图，不能全自动登录；
// 职师院默认不要验证码，启动时可直接自动登录（服务器要求验证码时再落回登录页）。
enum CredentialsStore {
    private static let service = "com.h2sy60.GlutnnGxunuAssistant"
    private static let schoolKey = "savedSchoolId"

    private static func studentIdKey(_ schoolId: SchoolID) -> String {
        "savedStudentId.\(schoolId.rawValue)"
    }
    private static func accountKey(_ schoolId: SchoolID) -> String {
        "savedAccount.\(schoolId.rawValue)"
    }

    /// 保存一所学校的账号（登录成功时调）。
    static func save(schoolId: SchoolID, studentId: String, password: String) {
        UserDefaults.standard.set(schoolId.rawValue, forKey: schoolKey)
        UserDefaults.standard.set(studentId, forKey: studentIdKey(schoolId))
        savePassword(password, account: accountKey(schoolId))
    }

    /// 读某所学校已存的账号（切学校恢复输入用）。
    static func load(schoolId: SchoolID) -> (studentId: String, password: String)? {
        guard let studentId = UserDefaults.standard.string(forKey: studentIdKey(schoolId)),
              !studentId.isEmpty,
              let password = loadPassword(account: accountKey(schoolId)),
              !password.isEmpty else { return nil }
        return (studentId, password)
    }

    /// 某所学校已存的学号（只读学号，不要求密码存在；备份导出/导入按学号找课表缓存用）。
    static func savedStudentId(schoolId: SchoolID) -> String? {
        guard let studentId = UserDefaults.standard.string(forKey: studentIdKey(schoolId)),
              !studentId.isEmpty else { return nil }
        return studentId
    }

    /// 只记“上次用的学校”（切学校时调）：不动任何一所学校的已存账号。
    /// 不能用 save() 代替——save 会顺带把该校账号密码一起写，参数不对就写脏。
    static func setLastSchoolId(_ schoolId: SchoolID) {
        UserDefaults.standard.set(schoolId.rawValue, forKey: schoolKey)
    }

    /// 上次登录的学校（启动恢复用）。
    static func lastSchoolId() -> SchoolID? {
        guard let raw = UserDefaults.standard.string(forKey: schoolKey) else { return nil }
        return SchoolID(rawValue: raw)
    }

    /// 清掉全部已存账号（退出登录时调）。
    static func clearAll() {
        for id in SchoolID.allCases {
            UserDefaults.standard.removeObject(forKey: studentIdKey(id))
            deletePassword(account: accountKey(id))
        }
        UserDefaults.standard.removeObject(forKey: schoolKey)
    }

    /// 只清掉一所学校的账号（切换账号时调，别动另一所学校的已存账号）。
    static func clear(schoolId: SchoolID) {
        UserDefaults.standard.removeObject(forKey: studentIdKey(schoolId))
        deletePassword(account: accountKey(schoolId))
    }

    // MARK: - Keychain（密码）

    private static func savePassword(_ password: String, account: String) {
        guard let data = password.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // 先 Update、没有再 Add（和 CookieJar 同款）：绝不先 Delete——删完
        // Add 失败（比如钥匙串暂时不可用）就把已存密码弄丢了。
        // 可访问性跟 CookieJar 对齐：首次解锁后可读、本机专用（不进 iCloud 钥匙串）。
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private static func loadPassword(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    private static func deletePassword(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - 课表缓存（修“不登录看不到首页”）
//
// 旧版 Flutter 启动就读本地课表文件（readSchedule），不用登录也能看首页。
// 原生版之前课表只在内存里，退出就没了，首页只能是一片空。
// 现在每次拉课表成功就写一份 JSON 到沙盒（按学校 + 学号分文件，与成绩/
// 考试的 ModuleDiskCache 同款），启动和切学校时按当前学号读出来。
// 只按学校存会串账号：换账号后拉取失败时，首页会显示上一个人的课。
// 退出登录时清掉当前账号的缓存。
enum ScheduleStore {
    private struct SavedSchedule: Codable {
        var courses: [Course]
        var studentName: String
    }

    private static func fileURL(schoolId: SchoolID, account: String) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safeAccount = account.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("schedule_\(schoolId.rawValue)_\(safeAccount).json")
    }

    /// 旧版只按学校存的文件（无学号归属，无法确认是谁的课表，不再读取）。
    private static func legacyFileURL(schoolId: SchoolID) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("schedule_\(schoolId.rawValue).json")
    }

    /// 拉课表成功后调：把课表 + 名字写进磁盘（学号为空不写，避免存成无主缓存）。
    static func save(schoolId: SchoolID, account: String, courses: [Course], studentName: String) {
        guard !account.isEmpty else { return }
        let payload = SavedSchedule(courses: courses, studentName: studentName)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL(schoolId: schoolId, account: account), options: .atomic)
        // 顺手清掉旧版无学号文件，防止它被误读或长期残留。
        try? FileManager.default.removeItem(at: legacyFileURL(schoolId: schoolId))
    }

    /// 启动 / 切学校时调：按学号读出缓存（没有或学号为空返回 nil）。
    /// 不回退读旧版无学号文件——无法确认归属，读了就会串账号；
    /// 升级后第一次启动没有缓存，拉一次课表就恢复。
    static func load(schoolId: SchoolID, account: String) -> (courses: [Course], studentName: String)? {
        guard !account.isEmpty,
              let data = try? Data(contentsOf: fileURL(schoolId: schoolId, account: account)),
              let payload = try? JSONDecoder().decode(SavedSchedule.self, from: data) else { return nil }
        return (payload.courses, payload.studentName)
    }

    /// 退出登录时调：清掉该校该账号的缓存（含旧版无学号文件）。
    static func clear(schoolId: SchoolID, account: String) {
        if !account.isEmpty {
            try? FileManager.default.removeItem(at: fileURL(schoolId: schoolId, account: account))
        }
        try? FileManager.default.removeItem(at: legacyFileURL(schoolId: schoolId))
    }

    /// 清除全部缓存（数据管理）时调：清掉该校所有账号的课表缓存文件。
    static func clearAll(schoolId: SchoolID) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let prefix = "schedule_\(schoolId.rawValue)_"
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in files where url.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try? FileManager.default.removeItem(at: legacyFileURL(schoolId: schoolId))
    }
}

/// 通用模块磁盘缓存（按 schoolId + account + key 存 JSON）。
enum ModuleDiskCache {
    private static func fileURL(schoolId: SchoolID, account: String, key: String) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safeAccount = account.replacingOccurrences(of: "/", with: "_")
        let safeKey = key.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("cache_\(schoolId.rawValue)_\(safeAccount)_\(safeKey).json")
    }

    static func save<T: Encodable>(_ value: T, schoolId: SchoolID, account: String, key: String) {
        guard !account.isEmpty,
              let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: fileURL(schoolId: schoolId, account: account, key: key), options: .atomic)
    }

    static func load<T: Decodable>(_ type: T.Type, schoolId: SchoolID, account: String, key: String) -> T? {
        guard !account.isEmpty,
              let data = try? Data(contentsOf: fileURL(schoolId: schoolId, account: account, key: key)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func clear(schoolId: SchoolID, account: String, key: String) {
        guard !account.isEmpty else { return }
        try? FileManager.default.removeItem(at: fileURL(schoolId: schoolId, account: account, key: key))
    }
}

// MARK: - 登录 / 课表结果

enum LoginOutcome: Equatable {
    case success
    /// 登录失败（文案可直接展示）。
    case failure(String)
    /// 服务器要求验证码（职师院）：取图后让用户输入再试。
    case captchaRequired
}

enum ScheduleError: Error, LocalizedError, Equatable {
    case sessionExpired
    case network(String)
    case parseError
    case customParseError(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .sessionExpired: return "登录已过期，正在重新登录"
        case .network(let msg): return msg
        case .parseError: return "数据解析失败"
        case .customParseError(let msg): return msg
        case .empty: return "本周没有课程"
        }
    }
}

// MARK: - 提示条（Toast）

/// 提示条类型（原版 CustomSnackBar 的 type）：error 红 !、success 绿 ✓、loading 蓝 🔗、info 星星。
enum ToastKind {
    case error, success, loading, info
}

/// 提示条的点击动作：
/// - showLogin：没登录时点提示条，弹整页登录（输账号密码）。
/// - reverify：已登录但会话过期时点“需要验证”，走验证码弹窗重登（不是整页登录）。
enum ToastAction {
    case showLogin
    case reverify
}

/// 一颗提示条：类型 + 文字 + 显示秒数 + 可选点击动作。
struct Toast: Identifiable, Equatable {
    let id = UUID()
    var kind: ToastKind
    var text: String
    var duration: TimeInterval
    var action: ToastAction?

    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

/// 课表一键主题预设（只动颜色类字段，见 ScheduleAppearance.applyPreset）。
enum ScheduleThemePreset: CaseIterable {
    case standard, eyeCare, dark, highContrast

    var title: String {
        switch self {
        case .standard: return "默认"
        case .eyeCare: return "护眼绿"
        case .dark: return "深色"
        case .highContrast: return "高对比"
        }
    }
}

// MARK: - 课表外观设置（build 48，参考 WakeUp「课表外观」）
//
// 按“学校 + 学号”永久保存（UserDefaults，JSON）：当前用户 + 当前学校
// 登录就是这一套；再调就覆盖保存，下次就是新的。
// 默认：黑字（不透明度 0.75，比原来 0.85 再浅一点），其余与原来一致。
struct ScheduleAppearance: Codable, Equatable {
    /// 文字颜色（hex，如 "#000000"）。
    var textColorHex: String
    /// 文字不透明度（0.3...1.0）：调“深浅”。默认 0.75。
    var textOpacity: Double
    /// 课名字号（11...16）。默认 13。
    var fontSize: Double
    /// 格子内显示开始时间。默认 true。
    var showStartTime: Bool
    /// 格子内显示上课地点。默认 true。
    var showLocation: Bool
    /// 教室前显示 @。默认 true。
    var showAtSign: Bool
    /// 格子内显示授课老师（仅占 2 节以上的块）。默认 true。
    var showTeacher: Bool
    /// 格子内显示备注（course.extra，仅占 2 节以上的块）。默认 false。
    var showExtra: Bool
    /// 格子圆角半径（0...20）。默认 10。
    var cornerRadius: Double
    /// 格子底色不透明度（0.3...1.0）。默认 1.0。
    var blockOpacity: Double

    // MARK: 课程格子（build 57，参考 WakeUp「课表外观」）
    /// 格子边框颜色（hex）。默认浅灰 #D9D9D9，格子始终画 1pt 边框。
    var borderColorHex: String
    /// 格子使用虚线边框。默认 false。
    var useDashedBorder: Bool
    /// 边框使用格子颜色（忽略边框颜色）。默认 false。
    var borderUsesBlockColor: Bool
    /// 课程文字颜色叠加格子颜色（文字色与格子色 50% 混合）。默认 false。
    var textOverlaysBlockColor: Bool
    /// 格子文字水平居中。默认 true（当前就是居中）。
    var textHorizontalCenter: Bool
    /// 格子文字垂直居中。默认 true（居中，和 build 85 的默认观感一致；
    /// build 86 起 frame 显式按此开关对齐，关掉则顶部排布）。
    var textVerticalCenter: Bool
    /// 自定义格子高度（行高，40...120），nil = 自动按屏幕算。默认 nil。
    var customRowHeight: Double?
    /// 非本周课程不透明比（0.1...1.0）。默认 0.5。
    var nonCurrentWeekOpacity: Double
    /// 显示非本周课程（只显示不与本周课冲突的时段，淡色）。默认 false。
    var showNonCurrentWeekCourses: Bool

    // MARK: 整体界面（build 57）
    /// 使用纯色背景（否则白底）。默认 false。
    var useSolidBackground: Bool
    /// 背景颜色（hex）。默认白色 #FFFFFF。
    var backgroundColorHex: String
    /// 表头颜色（hex，顶栏标题 + 星期条文字）。默认黑色 #000000。
    var headerColorHex: String
    /// 显示网格辅助线（虚线网格）。默认 true。
    var showGridGuides: Bool
    /// 节数栏显示时间。默认 true。
    var showSectionTime: Bool
    /// 显示周六。默认 true。
    var showSaturday: Bool
    /// 显示周日。默认 true。
    var showSunday: Bool

    // MARK: 扩展外观（本次新增，默认值 = 之前的写死行为）
    /// 副文字字号（开始时间/老师/地点，备注再小 1 号）。默认 11。
    var secondaryFontSize: Double
    /// 课名粗体。默认 true。
    var courseNameBold: Bool
    /// 格子边框粗细（0.5...3）。默认 1。
    var borderWidth: Double
    /// 格子内边距（水平，0...10）。默认 4。
    var blockPadding: Double
    /// 色盘主题：0 马卡龙 / 1 莫兰迪 / 2 高饱和 / 3 深色。默认 0。
    var paletteTheme: Int
    /// 每门课自定义颜色（课名 → hex），有就优先于色盘分色。默认空。
    var courseColors: [String: String]
    /// 节次栏时间字号（8...12，节次数字大 4 号）。默认 9。
    var railFontSize: Double
    /// 节次栏文字跟随表头颜色（否则黑色）。默认 false。
    var railUsesHeaderColor: Bool
    /// 隐藏节次数字（节次栏只显示时间）。默认 false。
    var hideSectionNumbers: Bool
    /// 今日列高亮（仅当前周页）。默认 false。
    var highlightToday: Bool
    /// 标记当前节次（正在上的课边框加粗变红）。默认 false。
    var markCurrentSection: Bool
    /// 已上完的课变淡（仅当前周页）。默认 false。
    var dimPastCourses: Bool
    /// 已上完课程不透明比。默认 0.5。
    var pastCourseOpacity: Double
    /// 课表页背景图（用自定义壁纸图，没存过用默认照片）。默认 false。
    var useBackgroundImage: Bool
    /// 背景图不透明度（0.1...1.0，越小越淡）。默认 0.35。
    var backgroundImageOpacity: Double
    /// 跟随系统深色模式（系统深色时课表页切深色配色）。默认 false。
    var followSystemDarkMode: Bool

    static let `default` = ScheduleAppearance(
        textColorHex: "#000000",
        textOpacity: 0.75,
        fontSize: 13,
        showStartTime: true,
        showLocation: true,
        showAtSign: true,
        showTeacher: true,
        showExtra: false,
        cornerRadius: 10,
        blockOpacity: 1.0,
        borderColorHex: "#D9D9D9",
        useDashedBorder: false,
        borderUsesBlockColor: false,
        textOverlaysBlockColor: false,
        textHorizontalCenter: true,
        textVerticalCenter: true,
        customRowHeight: nil,
        nonCurrentWeekOpacity: 0.5,
        showNonCurrentWeekCourses: false,
        useSolidBackground: false,
        backgroundColorHex: "#FFFFFF",
        headerColorHex: "#000000",
        showGridGuides: true,
        showSectionTime: true,
        showSaturday: true,
        showSunday: true,
        secondaryFontSize: 11,
        courseNameBold: true,
        borderWidth: 1,
        blockPadding: 4,
        paletteTheme: 0,
        courseColors: [:],
        railFontSize: 9,
        railUsesHeaderColor: false,
        hideSectionNumbers: false,
        highlightToday: false,
        markCurrentSection: false,
        dimPastCourses: false,
        pastCourseOpacity: 0.5,
        useBackgroundImage: false,
        backgroundImageOpacity: 0.35,
        followSystemDarkMode: false
    )

    /// 块内文字颜色（文字色 × 不透明度）。
    var textColor: Color {
        Color(hex: textColorHex).opacity(textOpacity)
    }

    /// 格子边框颜色。
    var borderColor: Color { Color(hex: borderColorHex) }
    /// 课表背景颜色（用纯色背景时才用）。
    var backgroundColor: Color { Color(hex: backgroundColorHex) }
    /// 表头颜色。
    var headerColor: Color { Color(hex: headerColorHex) }
    /// 实际背景色（不用纯色背景时就是白底）。
    var effectiveBackgroundColor: Color { useSolidBackground ? backgroundColor : .white }

    /// 系统深色且开了“跟随系统深色”时，返回深色配色版（其余设置不变）：
    /// 背景/表头/边框切深色，节次栏跟随表头色；深色色盘下文字切白色
    /// （马卡龙等浅色盘配黑字在深色背景上仍可读，不动文字色）。
    func resolved(darkMode: Bool) -> ScheduleAppearance {
        guard followSystemDarkMode, darkMode else { return self }
        var a = self
        a.useSolidBackground = true
        a.backgroundColorHex = "#1C1C1E"
        a.headerColorHex = "#FFFFFF"
        a.borderColorHex = "#48484A"
        a.railUsesHeaderColor = true
        if a.paletteTheme == 3 {
            a.textColorHex = "#FFFFFF"
            a.textOpacity = 0.92
        }
        return a
    }

    /// 套用一键主题预设：只动颜色类字段，显示开关/对齐/行高/自定义课色不动。
    mutating func applyPreset(_ preset: ScheduleThemePreset) {
        switch preset {
        case .standard:
            textColorHex = "#000000"; textOpacity = 0.75
            useSolidBackground = false; backgroundColorHex = "#FFFFFF"
            headerColorHex = "#000000"; borderColorHex = "#D9D9D9"
            borderWidth = 1; paletteTheme = 0; blockOpacity = 1.0
        case .eyeCare:
            textColorHex = "#1B3A24"; textOpacity = 0.85
            useSolidBackground = true; backgroundColorHex = "#EAF4EA"
            headerColorHex = "#1B3A24"; borderColorHex = "#B9D8BC"
            borderWidth = 1; paletteTheme = 1; blockOpacity = 1.0
        case .dark:
            textColorHex = "#FFFFFF"; textOpacity = 0.92
            useSolidBackground = true; backgroundColorHex = "#1C1C1E"
            headerColorHex = "#FFFFFF"; borderColorHex = "#48484A"
            borderWidth = 1; paletteTheme = 3; blockOpacity = 1.0
            railUsesHeaderColor = true
        case .highContrast:
            textColorHex = "#000000"; textOpacity = 1.0
            useSolidBackground = false; backgroundColorHex = "#FFFFFF"
            headerColorHex = "#000000"; borderColorHex = "#000000"
            borderWidth = 1.5; paletteTheme = 2; blockOpacity = 1.0
        }
    }

    /// 从 ColorPicker 的 Color 回写 hex（只取 RGB，不含透明度）。
    mutating func setTextColor(_ color: Color) {
        if let hex = color.toHex() { textColorHex = hex }
    }
    mutating func setBorderColor(_ color: Color) {
        if let hex = color.toHex() { borderColorHex = hex }
    }
    mutating func setBackgroundColor(_ color: Color) {
        if let hex = color.toHex() { backgroundColorHex = hex }
    }
    mutating func setHeaderColor(_ color: Color) {
        if let hex = color.toHex() { headerColorHex = hex }
    }
}

// MARK: - ScheduleAppearance 向后兼容解码（build 57）
//
// build 48 只存 10 个字段；build 57 加了 16 个。新字段用 decodeIfPresent，
// 旧数据缺了就取默认值，已存的设置不会丢，也不会解码失败。
// 注意：init(from:) 写在 extension 里，memberwise init 才不会被吃掉
// （static let default 靠它构造；已用 swiftc 实测验证）。
extension ScheduleAppearance {
    private enum CodingKeys: String, CodingKey {
        case textColorHex, textOpacity, fontSize, showStartTime, showLocation
        case showAtSign, showTeacher, showExtra, cornerRadius, blockOpacity
        case borderColorHex, useDashedBorder, borderUsesBlockColor, textOverlaysBlockColor
        case textHorizontalCenter, textVerticalCenter, customRowHeight
        case nonCurrentWeekOpacity, showNonCurrentWeekCourses
        case useSolidBackground, backgroundColorHex, headerColorHex
        case showGridGuides, showSectionTime, showSaturday, showSunday
        case secondaryFontSize, courseNameBold, borderWidth, blockPadding
        case paletteTheme, courseColors, railFontSize, railUsesHeaderColor
        case hideSectionNumbers, highlightToday, markCurrentSection
        case dimPastCourses, pastCourseOpacity
        case useBackgroundImage, backgroundImageOpacity, followSystemDarkMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        textColorHex = try c.decodeIfPresent(String.self, forKey: .textColorHex) ?? d.textColorHex
        textOpacity = try c.decodeIfPresent(Double.self, forKey: .textOpacity) ?? d.textOpacity
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        showStartTime = try c.decodeIfPresent(Bool.self, forKey: .showStartTime) ?? d.showStartTime
        showLocation = try c.decodeIfPresent(Bool.self, forKey: .showLocation) ?? d.showLocation
        showAtSign = try c.decodeIfPresent(Bool.self, forKey: .showAtSign) ?? d.showAtSign
        showTeacher = try c.decodeIfPresent(Bool.self, forKey: .showTeacher) ?? d.showTeacher
        showExtra = try c.decodeIfPresent(Bool.self, forKey: .showExtra) ?? d.showExtra
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.cornerRadius
        blockOpacity = try c.decodeIfPresent(Double.self, forKey: .blockOpacity) ?? d.blockOpacity
        borderColorHex = try c.decodeIfPresent(String.self, forKey: .borderColorHex) ?? d.borderColorHex
        useDashedBorder = try c.decodeIfPresent(Bool.self, forKey: .useDashedBorder) ?? d.useDashedBorder
        borderUsesBlockColor = try c.decodeIfPresent(Bool.self, forKey: .borderUsesBlockColor) ?? d.borderUsesBlockColor
        textOverlaysBlockColor = try c.decodeIfPresent(Bool.self, forKey: .textOverlaysBlockColor) ?? d.textOverlaysBlockColor
        textHorizontalCenter = try c.decodeIfPresent(Bool.self, forKey: .textHorizontalCenter) ?? d.textHorizontalCenter
        textVerticalCenter = try c.decodeIfPresent(Bool.self, forKey: .textVerticalCenter) ?? d.textVerticalCenter
        customRowHeight = try c.decodeIfPresent(Double.self, forKey: .customRowHeight)
        nonCurrentWeekOpacity = try c.decodeIfPresent(Double.self, forKey: .nonCurrentWeekOpacity) ?? d.nonCurrentWeekOpacity
        showNonCurrentWeekCourses = try c.decodeIfPresent(Bool.self, forKey: .showNonCurrentWeekCourses) ?? d.showNonCurrentWeekCourses
        useSolidBackground = try c.decodeIfPresent(Bool.self, forKey: .useSolidBackground) ?? d.useSolidBackground
        backgroundColorHex = try c.decodeIfPresent(String.self, forKey: .backgroundColorHex) ?? d.backgroundColorHex
        headerColorHex = try c.decodeIfPresent(String.self, forKey: .headerColorHex) ?? d.headerColorHex
        showGridGuides = try c.decodeIfPresent(Bool.self, forKey: .showGridGuides) ?? d.showGridGuides
        showSectionTime = try c.decodeIfPresent(Bool.self, forKey: .showSectionTime) ?? d.showSectionTime
        showSaturday = try c.decodeIfPresent(Bool.self, forKey: .showSaturday) ?? d.showSaturday
        showSunday = try c.decodeIfPresent(Bool.self, forKey: .showSunday) ?? d.showSunday
        secondaryFontSize = try c.decodeIfPresent(Double.self, forKey: .secondaryFontSize) ?? d.secondaryFontSize
        courseNameBold = try c.decodeIfPresent(Bool.self, forKey: .courseNameBold) ?? d.courseNameBold
        borderWidth = try c.decodeIfPresent(Double.self, forKey: .borderWidth) ?? d.borderWidth
        blockPadding = try c.decodeIfPresent(Double.self, forKey: .blockPadding) ?? d.blockPadding
        paletteTheme = try c.decodeIfPresent(Int.self, forKey: .paletteTheme) ?? d.paletteTheme
        courseColors = try c.decodeIfPresent([String: String].self, forKey: .courseColors) ?? d.courseColors
        railFontSize = try c.decodeIfPresent(Double.self, forKey: .railFontSize) ?? d.railFontSize
        railUsesHeaderColor = try c.decodeIfPresent(Bool.self, forKey: .railUsesHeaderColor) ?? d.railUsesHeaderColor
        hideSectionNumbers = try c.decodeIfPresent(Bool.self, forKey: .hideSectionNumbers) ?? d.hideSectionNumbers
        highlightToday = try c.decodeIfPresent(Bool.self, forKey: .highlightToday) ?? d.highlightToday
        markCurrentSection = try c.decodeIfPresent(Bool.self, forKey: .markCurrentSection) ?? d.markCurrentSection
        dimPastCourses = try c.decodeIfPresent(Bool.self, forKey: .dimPastCourses) ?? d.dimPastCourses
        pastCourseOpacity = try c.decodeIfPresent(Double.self, forKey: .pastCourseOpacity) ?? d.pastCourseOpacity
        useBackgroundImage = try c.decodeIfPresent(Bool.self, forKey: .useBackgroundImage) ?? d.useBackgroundImage
        backgroundImageOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundImageOpacity) ?? d.backgroundImageOpacity
        followSystemDarkMode = try c.decodeIfPresent(Bool.self, forKey: .followSystemDarkMode) ?? d.followSystemDarkMode
    }
}

extension Color {
    /// hex（"#RRGGBB"）→ Color。非法返回黑色。
    init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    /// Color → hex（"#RRGGBB"）。取不出来返回 nil。
    func toHex() -> String? {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

// MARK: - App 状态（唯一数据源）
//
// 账号按学校存在 UserDefaults（学号）+ Keychain（密码），登录成功即保存；
// 启动时恢复上次学校并预填账号，职师院可直接自动登录（桂工每次都要验证码，只能预填 + 自动取图）。
// 密码只发给教务服务器，绝不记日志。

@MainActor
@Observable
final class AppState {
    /// 当前学校，默认桂工。
    var school: SchoolConfig = gutSchool
    var isLoggedIn = false
    var studentId = ""
    var studentName = ""
    /// 密码只存 Keychain，供自动重登用。
    var password = ""

    /// 课表外观（build 48）：按学校 + 学号永久保存，登录即用这一套。
    var scheduleAppearance: ScheduleAppearance = .default

    /// 作息版本号（build 72）：时间管理每存一次就 +1。CustomSectionTimes
    /// 只是写文件的普通结构体，不是 Observable，课表页和首页不会自己重绘；
    /// 这个版本号一变，读生效时间的页面就重读文件、立刻显示新时间。
    var sectionTimesVersion = 0

    /// 壁纸（build 78，专家方案）：状态收口到 AppState（@Observable），与
    /// UserDefaults 同步（键名沿用 "Wallpaper" / "CustomWallpaperVersion"，
    /// AppSettings.wallpaper 读的是同一个键，不会脱节）。
    /// 之前壁纸只存在各页零散的 @AppStorage 里，挂在 .background() 的
    /// WallpaperBackground 换壁纸时不重绘、卡在旧图上（build 77 回归）。
    /// 收口后设置页一改，所有页的壁纸同一帧刷新。
    var wallpaper: Int = UserDefaults.standard.integer(forKey: "Wallpaper") {
        didSet { UserDefaults.standard.set(wallpaper, forKey: "Wallpaper") }
    }
    var customWallpaperVersion: Int = UserDefaults.standard.integer(forKey: "CustomWallpaperVersion") {
        didSet { UserDefaults.standard.set(customWallpaperVersion, forKey: "CustomWallpaperVersion") }
    }

    /// 外观设置的 UserDefaults 键（学校 + 学号；没学号用 guest）。
    /// v2 起：v1 存量在 loadScheduleAppearance 里迁移（见下）。
    private static func appearanceKey(schoolId: SchoolID, studentId: String) -> String {
        "ScheduleAppearance_v2.\(schoolId.rawValue).\(studentId.isEmpty ? "guest" : studentId)"
    }

    private static func legacyAppearanceKey(schoolId: SchoolID, studentId: String) -> String {
        "ScheduleAppearance_v1.\(schoolId.rawValue).\(studentId.isEmpty ? "guest" : studentId)"
    }

    /// 读当前学校 + 学号的外观设置（没有就用默认）。
    func loadScheduleAppearance() {
        let key = Self.appearanceKey(schoolId: school.id, studentId: studentId)
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(ScheduleAppearance.self, from: data) {
            scheduleAppearance = saved
            return
        }
        // v1 存量迁移：build 85 时 textVerticalCenter=false 没有视觉效果
        // （frame 没写 alignment、默认居中），build 86 起才变成顶部排布。
        // 存量里的 false 基本是当时默认值被整表存下、不是用户选的顶部，
        // 迁移时翻回 true 恢复居中观感，其余设置原样保留并存到 v2。
        let legacyKey = Self.legacyAppearanceKey(schoolId: school.id, studentId: studentId)
        if let data = UserDefaults.standard.data(forKey: legacyKey),
           var saved = try? JSONDecoder().decode(ScheduleAppearance.self, from: data) {
            saved.textVerticalCenter = true
            scheduleAppearance = saved
            saveScheduleAppearance()
            return
        }
        scheduleAppearance = .default
    }

    /// 保存当前外观设置（调完即记，下次登录就是这套）。
    func saveScheduleAppearance() {
        let key = Self.appearanceKey(schoolId: school.id, studentId: studentId)
        if let data = try? JSONEncoder().encode(scheduleAppearance) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 恢复默认外观（并保存）。
    func resetScheduleAppearance() {
        scheduleAppearance = .default
        saveScheduleAppearance()
    }

    /// 当前学期：年（如 2026）+ 学期（"秋"/"春"）。
    var year: Int = 2026
    var semester: String = "秋"
    var currentWeek: Int = 1

    /// 课表（已按课程展开成单条上课记录）。
    var courses: [Course] = []
    var scheduleLoading = false
    var scheduleError: String?

    /// 成绩。
    var scores: [CourseScore] = []
    var scoresLoading = false
    var scoresError: String?

    /// 考试安排（build 43 新增）。
    var exams: [ExamItem] = []
    var examsLoading = false
    var examsError: String?

    /// 登录状态。
    var loginLoading = false
    var loginError: String?

    /// 当前 Tab（0=一览，1=课表，2=我的）。放 AppState 而不是 ContentView 的 @State，
    /// 因为窗口级的亮/暗模式要跟着它走：系统底栏是 UITabBar（UIKit），只认窗口的
    /// trait，不认 TabView 上的 .preferredColorScheme（build 32 实测无效）。
    /// 窗口在课表页切亮色，底栏就是浅色玻璃；回首页/我的切回深色。
    /// 依据：WWDC25 219「小号铬（导航/标签栏）随背景在浅色↔深色之间翻转」、
    /// 323「玻璃随下方内容自动适配、由浅入深」；TabView 是 UITabBarController 的
    /// 包装，底栏外观由 UITabBar 管理（见 Apple 文档与社区验证）。
    var selectedTab = 0

    /// 是否弹出登录页（全屏，可关闭；旧版登录页就是 push 进来、右上角有关闭钮的页面，不是门禁）。
    /// 首页三个胶囊和“请先登录”在未登录时把它置 true；登录成功后 LoginView 自己关掉。
    var showLoginSheet = false

    // MARK: - 提示条（Toast，原版 bars.dart CustomSnackBar）

    /// 原版提示条：液态玻璃药丸（圆角 25），左图标 + 右文字，浮在页面底部、
    /// 低栏上方 10pt，左右留白 100，几秒后自动消失。类型：error 红 !（错误）、
    /// success 绿 ✓（成功）、loading 蓝 🔗（进行中）、info 星星（提示）。
    /// “需要验证”是带点击动作的版本：文字变蓝色，点按后走验证码弹窗重登
    /// （不是整页登录；整页登录只在首次登录 / 切换账号时用）。
    var toast: Toast?

    func showToast(_ kind: ToastKind, _ text: String, duration: TimeInterval = 2, action: ToastAction? = nil) {
        toastTask?.cancel()
        let t = Toast(kind: kind, text: text, duration: duration, action: action)
        toast = t
        let id = t.id
        toastTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            if toast?.id == id { toast = nil }
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    /// 点提示条：有动作就执行动作，否则只是关掉。
    /// “需要验证”走验证码弹窗重登（requestReverification），不是整页登录。
    func handleToastTap() {
        guard let t = toast else { return }
        if t.action == .showLogin {
            dismissToast()
            showLoginSheet = true
        } else if t.action == .reverify {
            // 立刻给反馈：重登要走好几步网络（GXVNU 拿登录页、拿公钥、POST、
            // 探针），得好几秒；只关提示条不给新提示，用户会以为点了没反应
            // （Russell 2026-11-18 12:30：职师院“需要验证”点了没反应）。
            // 先换成“正在验证...”，结果出来再被成功/失败/弹窗替换。
            showToast(.loading, "正在验证...", duration: 30)
            Task { await requestReverification() }
        } else {
            dismissToast()
        }
    }

    private var toastTask: Task<Void, Never>?

    /// 验证码（桂工每次都要；职师院按需）。图片数据 + 用户输入。
    var captchaImageData: Data?
    var captchaText = ""
    var showCaptcha = false

    /// 验证码弹窗（原版 dialog.dart showCaptchaDialog 同款）：
    /// 会话过期点“需要验证”时弹，不占整页；登录页那个整页表单只在
    /// 首次登录 / 切换账号时用。弹窗自己的输入框与校验中状态。
    var showCaptchaDialog = false {
        didSet {
            if !showCaptchaDialog {
                resolveReloginWaiters(false)
            }
        }
    }
    private var reloginContinuations: [CheckedContinuation<Bool, Never>] = []
    var captchaDialogText = ""
    var captchaChecking = false

    /// 单飞登录（Single-Flight，build 43，专家意见）：正在跑的登录任务。
    /// 已有登录在跑时，后续 performLogin 不返回 nil（那会被当成失败、
    /// 误报“需要验证”），而是直接等待并复用同一个登录结果。
    /// 两个登录并发会互相顶掉会话（Cookie/CSRFT 串掉），表现就是
    /// “账号密码不正确”——明明密码没错，只是两次登录把会话搞脏了。
    /// 所有登录入口（login / 静默重登）都走这个单飞合并。
    @ObservationIgnored private var activeLoginTask: Task<LoginOutcome, Never>?
    /// 正在跑的登录任务的标识（学校+学号+验证码+密码）：只有标识相同的
    /// 调用才能复用它的结果；验证码不同的调用要排队等它跑完再用自己的
    /// 验证码登一次，不能直接拿空验证码登录的失败结果（那会让用户刚在
    /// 验证码弹窗里输的验证码被吞掉，反复弹“请输验证码”）。
    @ObservationIgnored private var activeLoginKey: String?
    /// 当前登录任务的序号：清理 activeLoginTask 时先核对，避免把后来
    /// 排队新建的任务误清掉。
    @ObservationIgnored private var activeLoginToken: UUID?
    /// 刷新课表防重入（build 43）：正在刷新时再点刷新直接忽略。
    @ObservationIgnored private var isRefreshingSchedule = false
    /// 刷新成绩防重入（build 43）。
    @ObservationIgnored private var isRefreshingScores = false
    /// 成绩刷新代次：切学年/学期时新请求顶掉旧请求，旧结果回来直接丢弃，
    /// 不覆盖新筛选的结果（防重入直接吞掉新请求的话，页面会停在旧学期）。
    @ObservationIgnored private var scoresRefreshGeneration = 0

    init() {
        updateTermFromDate()
        // 恢复上次登录的学校 + 该校已存账号（预填，启动后自动登录见 tryAutoLogin）。
        if let lastId = CredentialsStore.lastSchoolId() {
            school = schoolById(lastId)
            updateTermFromDate()
        }
        if let saved = CredentialsStore.load(schoolId: school.id) {
            studentId = saved.studentId
            password = saved.password
            // 旧版语义：启动时“有保存的学号”就算已登录（main.dart），会话过期了拉数据时再发现、再重登。
            // 不是“这次会话已验证”。这样首页三个胶囊才知道该直接刷新还是弹登录页。
            isLoggedIn = true
        }
        // 读本地课表缓存（旧版 readSchedule）：不登录也能看首页。
        // 按已存学号读（studentId 刚从已存账号恢复），没存账号就不读，避免串账号。
        if let cached = ScheduleStore.load(schoolId: school.id, account: studentId) {
            courses = cached.courses
            if !cached.studentName.isEmpty { studentName = cached.studentName }
        }
        // 读当前学校 + 学号的课表外观（build 48）。
        loadScheduleAppearance()
        if let cachedScores = ModuleDiskCache.load(type(of: scores), schoolId: school.id, account: studentId, key: "scores") {
            scores = cachedScores
        }
        if let cachedExams = ModuleDiskCache.load(type(of: exams), schoolId: school.id, account: studentId, key: "exams") {
            exams = cachedExams
        }
        // build 64：启动记一条，日志里能看到每次启动的学校和登录态。
        AppLogger.shared.log("app start: school=\(school.id.rawValue) loggedIn=\(isLoggedIn) week=\(currentWeek) cachedCourses=\(courses.count)")
    }

    /// 重新算当前周（build 63 学期设置改开学日期/总周数后调，立即生效）。
    func refreshCurrentWeek() {
        currentWeek = GlutnnGxunuAssistant.currentWeek(for: school)
    }

    /// 按当前日期算学年学期（8 月及以后为秋季学期）。
    func updateTermFromDate(_ date: Date = Date()) {
        let month = Calendar(identifier: .gregorian).component(.month, from: date)
        let y = Calendar(identifier: .gregorian).component(.year, from: date)
        if month >= 8 || month == 1 {
            semester = "秋"
            year = month == 1 ? y - 1 : y
        } else {
            semester = "春"
            year = y - 1
        }
        currentWeek = GlutnnGxunuAssistant.currentWeek(for: school, on: date)
    }

    /// 切学校：换配置、清登录态和验证码。已输的学号密码按学校保存，回来接着用（Flutter _switchSchool 同款）。
    /// Cookie 按 host 分桶，不用清。
    ///
    /// 单拍原子切换（build 42，三位专家共识）：school、courses、currentWeek、
    /// isLoggedIn 等所有 UI 状态必须在同一个 @MainActor 同步事务里一次改完
    /// （withTransaction 关隐式动画），绝不产生“新学校 + 旧课表”的撕裂帧。
    /// build 37 的两阶段（同步改 school、Task 里改 courses）和 build 39/41
    /// 的锁/目标校验都没动“改了什么”，所以都没用——病根是拆分本身。
    func switchSchool(_ newSchool: SchoolConfig) {
        guard newSchool.id != school.id else { return }
        // build 64：切学校记一条。
        AppLogger.shared.log("switch school: \(school.id.rawValue) -> \(newSchool.id.rawValue)")
        // 取消正在进行的旧学校验证码请求，防止异步回调串台。
        captchaTask?.cancel()
        captchaTask = nil
        // 先把当前学校的输入存下来（哪怕还没登录成功，下次回来也能接着输）。
        if !studentId.isEmpty {
            CredentialsStore.save(schoolId: school.id, studentId: studentId, password: password)
        }
        // 记下“上次用的学校”是新学校：save() 刚把 lastSchoolId 写成了旧学校，
        // 不覆盖的话，下次启动还会回到旧学校，切学校等于白切。
        CredentialsStore.setLastSchoolId(newSchool.id)
        // 禁用隐式动画，在同一帧内原子化切换整套上下文。
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            school = newSchool
            // 恢复目标学校已存的账号；没有就清空输入框。
            if let saved = CredentialsStore.load(schoolId: newSchool.id) {
                studentId = saved.studentId
                password = saved.password
            } else {
                studentId = ""
                password = ""
            }
            isLoggedIn = false
            studentName = ""
            // 读目标学校的缓存课表（没有就空着，等登录后拉）。不直接清空：旧版切学校后首页照样显示该校缓存。
            // 按刚恢复的目标校学号读，没存账号就不读，避免看到别人存下的课表。
            if let cached = ScheduleStore.load(schoolId: newSchool.id, account: studentId) {
                courses = cached.courses
                if !cached.studentName.isEmpty { studentName = cached.studentName }
            } else {
                courses = []
            }
            scores = []
            scoresError = nil
            scheduleError = nil
            loginError = nil
            captchaImageData = nil
            captchaText = ""
            showCaptchaDialog = false
            // 桂工每次登录都要验证码，行直接亮出来（图到了再填）；职师院默认不要。
            showCaptcha = newSchool.captchaRequired
            updateTermFromDate()
            // 读目标学校 + 学号的课表外观（build 48），和切学校同一帧换掉。
            loadScheduleAppearance()
            scores = ModuleDiskCache.load(type(of: scores), schoolId: newSchool.id, account: studentId, key: "scores") ?? []
            exams = ModuleDiskCache.load(type(of: exams), schoolId: newSchool.id, account: studentId, key: "exams") ?? []
        }
        // 若新学校需要验证码，由 switchSchool 内部统一发起唯一请求，
        // 按钮里不要再另起 Task（双 Task 竞态改 showCaptcha 是崩溃源之一）。
        if newSchool.captchaRequired {
            requestCaptcha(for: newSchool.id)
        }
    }

    // MARK: - 验证码

    /// 验证码请求单句柄（build 42）：切学校时先 cancel 旧请求，再由
    /// switchSchool 内部统一发起唯一请求。@ObservationIgnored——改它
    /// 不触发视图重绘。按钮里不要再另起 fetchCaptcha 的 Task。
    @ObservationIgnored private var captchaTask: Task<Void, Never>?

    /// 统一的验证码请求入口（build 42）：取到图后只有学校还是目标校
    /// 才写回去，防止切校途中旧学校的图串到新学校上。
    func requestCaptcha(for target: SchoolID? = nil) {
        let targetId = target ?? school.id
        captchaTask?.cancel()
        captchaTask = Task { @MainActor in
            captchaText = ""
            let image: Data?
            if targetId == .gut {
                image = await GUTService.fetchCaptchaImage()
            } else {
                image = await GXVNUService.fetchCaptchaImage()
            }
            guard !Task.isCancelled, school.id == targetId else { return }
            captchaImageData = image
            showCaptcha = image != nil
        }
    }

    /// 取验证码图（桂工登录前必取；职师院按需取）。
    func fetchCaptcha() async {
        captchaText = ""
        if school.id == .gut {
            captchaImageData = await GUTService.fetchCaptchaImage()
        } else {
            captchaImageData = await GXVNUService.fetchCaptchaImage()
        }
        showCaptcha = captchaImageData != nil
    }

    // MARK: - 登录
    //
    // 登录流程（build 31 重设计，Russell 2026-11-18 10:30“把登录这个功能捋清思绪，重新设计”）：
    // 整页登录（LoginView，全屏、可关闭）只在两种情况用：
    //   (1) 首次登录——没已存账号，点刷新/成绩/考试/请先登录时弹；
    //   (2) 切换账号——我的页“更换账号”清掉本校账号后直接弹。
    // 其余情况都不开整页：
    //   - 启动：有已存账号就按旧版语义算已登录（isLoggedIn=true），首页直接读缓存；
    //     职师院静默登录一次，桂工只预填 + 取验证码图（不空验证码试登）。
    //   - 会话过期（拉课表/成绩时发现）：首页弹“需要验证”提示条；
    //     点按 → 验证码弹窗（showCaptchaDialog，居中浮层，不占整页）：
    //     桂工取图让用户输码重登，职师院先静默重登、要码时才弹弹窗；
    //     成功后重拉数据并提示“数据已更新!”；验证码错留在弹窗里换图重试；
    //     只有账号/密码本身有问题时，才回整页登录。
    //   - 退出登录：清掉全部已存账号 + 缓存，不自动弹登录页（用户点“请先登录”再进）。
    // isLoggedIn = “有已存账号”，不是“本次会话已验证”；会话过期不把它置 false，
    // 否则验证码弹窗那条路走不通（刷新/成绩会直接弹整页登录）。

    /// 会话过期后的重新验证（点“需要验证”时调，原版 showCaptchaDialog 同款）：
    /// 桂工每次都要验证码——取图，弹验证码弹窗；
    /// 职师院默认不要验证码——先用已存账号静默重登，成功就直接重拉课表，
    /// 服务器要求验证码时才取图弹弹窗，账号/密码有问题时回整页登录。
    /// 成功后重拉课表并提示“数据已更新!”；失败留在弹窗里换图重试，
    /// 只有账号/密码问题才回整页登录。
    func requestReverification() async {
        guard !studentId.isEmpty, !password.isEmpty else {
            showLoginSheet = true
            return
        }
        if school.id == .gut {
            await fetchCaptcha()
            if captchaImageData != nil {
                captchaDialogText = ""
                captchaChecking = false
                // 关掉“正在验证...”，不然它浮在验证码弹窗上面。
                dismissToast()
                showCaptchaDialog = true
            } else {
                showToast(.error, "验证码获取失败，请稍后重试", duration: 4)
                showLoginSheet = true
            }
            return
        }
        // 职师院：静默重登（单飞合并，防并发顶掉会话）。
        let outcome = await performLogin(captcha: "")
        switch outcome {
        case .success:
            isLoggedIn = true
            await refreshSchedule()
            if scheduleError == nil {
                showToast(.success, "数据已更新!", duration: 1)
            } else {
                showToast(.error, scheduleError ?? "拉取失败", duration: 4)
            }
        case .captchaRequired:
            await fetchCaptcha()
            if captchaImageData != nil {
                captchaDialogText = ""
                captchaChecking = false
                // 关掉“正在验证...”，不然它浮在验证码弹窗上面。
                dismissToast()
                showCaptchaDialog = true
            } else {
                dismissToast()
                showLoginSheet = true
            }
        case .failure(let message):
            showToast(.error, message, duration: 4)
            isLoggedIn = false
            showLoginSheet = true
        }
    }

    /// 验证码弹窗点“继续”：用已存账号 + 输入的验证码重登。
    /// 成功：关弹窗，重拉课表并提示；验证码错：留在弹窗里，提示 + 换一张图再试；
    /// 账号/密码问题：弹窗解决不了，关弹窗回整页登录。
    func confirmCaptchaDialog() async {
        // build 67：先记一条（只记长度，不记验证码本身），这样下次再报
        // “点了确认没反应”，日志里能分清是按钮没触发，还是登录没回来。
        AppLogger.shared.log("captcha dialog confirm tapped: textLength=\(captchaDialogText.count) checking=\(captchaChecking)")
        guard !captchaChecking else { return }
        guard !captchaDialogText.isEmpty else {
            showToast(.error, "请输入验证码", duration: 2)
            return
        }
        captchaChecking = true
        defer { captchaChecking = false }
        // 单飞合并：已有登录在跑时直接等它、复用结果，不再返回 nil。
        let outcome = await performLogin(captcha: captchaDialogText)
        switch outcome {
        case .success:
            AppLogger.shared.log("reverify \(school.id) success")
            isLoggedIn = true
            let hadWaiters = !reloginContinuations.isEmpty
            resolveReloginWaiters(true)
            showCaptchaDialog = false
            captchaDialogText = ""
            captchaText = ""
            showCaptcha = false
            if !hadWaiters {
            await refreshSchedule()
            if scheduleError == nil {
                showToast(.success, "数据已更新!", duration: 1)
            } else {
                showToast(.error, scheduleError ?? "拉取失败", duration: 4)
            }
            } 
        case .failure(let message):
            AppLogger.shared.log("reverify \(school.id) failure: \(message)")
            if message.contains("验证码") {
                showToast(.error, message, duration: 4)
                await fetchCaptcha()
                // 换了新图就把旧输入清掉，免得用户对着新图还留着旧码。
                captchaDialogText = ""
            } else {
                showCaptchaDialog = false
                isLoggedIn = false
                loginError = message
                showLoginSheet = true
            }
        case .captchaRequired:
            // 验证码被服务端拒了（输错，或会话换了导致作废）：记一条，
            // 再换一张图让用户重输。日志里能看到是 200 拒还是会话作废
            // （GXVNUService 那边记了具体原因）。
            AppLogger.shared.log("reverify \(school.id) captchaRequired: new image fetched")
            showToast(.error, "请输入验证码", duration: 2)
            await fetchCaptcha()
            captchaDialogText = ""
        }
    }

    /// 单飞合并（Single-Flight）登录：若已有登录在跑，直接等待并复用
    /// 它的结果，绝不返回 nil 误报过期（build 43，专家意见）。
    /// 两个登录并发会把会话顶掉（Cookie/CSRFT 串掉），表现就是“账号密码不正确”。
    /// 账号/学校在创建 Task 前先取好，避免登录中途切学校读到错的上下文。
    ///
    /// 只有学校/学号/验证码/密码都相同的调用才复用结果；验证码不同的
    /// 调用（比如静默空验证码登录在跑时，用户在弹窗里输了验证码）排队
    /// 等前一个跑完，再用自己的验证码登一次——绝不并发，也不把用户刚
    /// 输的验证码吞掉、直接返回前一个登录的失败结果。
    private func performLogin(captcha: String) async -> LoginOutcome {
        let currentSchool = school
        let currentStudentId = studentId
        let currentPassword = password
        let key = "\(currentSchool.id.rawValue)|\(currentStudentId)|\(captcha)|\(currentPassword)"
        if let existingTask = activeLoginTask, activeLoginKey == key {
            return await existingTask.value
        }
        // 排队：新任务先等前一个登录跑完，再发起自己的登录。
        let previousTask = activeLoginTask
        let token = UUID()
        let task = Task<LoginOutcome, Never> {
            if let previousTask { _ = await previousTask.value }
            if currentSchool.id == .gut {
                return await GUTService.login(studentId: currentStudentId, password: currentPassword, captcha: captcha)
            } else {
                return await GXVNUService.login(studentId: currentStudentId, password: currentPassword, captcha: captcha)
            }
        }
        activeLoginTask = task
        activeLoginKey = key
        activeLoginToken = token
        let outcome = await task.value
        // 登录结果总览（只记结果类型，不记学号/密码/验证码内容），
        // 完整登录一遍后看日志能直接定位卡在哪一步。
        switch outcome {
        case .success:
            AppLogger.shared.log("login outcome: school=\(currentSchool.id.rawValue) success")
        case .captchaRequired:
            AppLogger.shared.log("login outcome: school=\(currentSchool.id.rawValue) captchaRequired")
        case .failure(let message):
            AppLogger.shared.log("login outcome: school=\(currentSchool.id.rawValue) failure: \(message)")
        }
        // 只清自己这一个任务，别把排队新建的任务误清掉。
        if activeLoginToken == token {
            activeLoginTask = nil
            activeLoginKey = nil
            activeLoginToken = nil
        }
        return outcome
    }

    /// 职师院会话过期后的重登（刷新/成绩共用），返回 LoginOutcome：
    /// 空验证码登，最多试两次——正方服务器是会话级风控（Shiro+Kaptcha）：
    /// 同一 JSESSIONID 失败 1~3 次后被打 needCaptcha 标记；clearSession()
    /// 删掉旧 JSESSIONID 后拿全新会话，第二次常常直接通过（build 43，
    /// 专家意见：不是“随机”，是风控状态机 + clearSession 的共同作用）。
    /// 两次都要求验证码，才直接弹验证码弹窗让他输码，不经过“需要验证”
    /// 提示条；账号/密码错才返回 .failure（调用方记错误/回整页登录）。
    private func reloginGXVNU() async -> LoginOutcome {
        var lastOutcome: LoginOutcome = .failure("重登失败")
        for _ in 0..<2 {
            let outcome = await performLogin(captcha: "")
            lastOutcome = outcome
            switch outcome {
            case .success:
                isLoggedIn = true
                return .success
            case .captchaRequired:
                // 清掉旧会话再试一次干净会话（全新 JSESSIONID，失败计数为 0）。
                GXVNUService.clearSession()
                continue
            case .failure:
                // 明确是密码错或网络错，不再盲目重试第二次。
                return outcome
            }
        }
        // 两次都要求验证码：立刻弹验证码框（即使图片暂未加载完也先弹窗
        // 显示加载菊花），绝不退回“需要验证”提示条（build 43，专家意见：
        // 旧代码 fetchCaptcha() 失败时 captchaImageData==nil，弹窗不执行，
        // 是三号漏网路径）。
        captchaDialogText = ""
        captchaChecking = false
        showCaptchaDialog = true
        await fetchCaptcha()
        return .captchaRequired
    }

    /// 登录。成功后自动拉课表。
    func login() async {
        // 校验（Flutter login.dart 同款分情况提示）。
        guard !studentId.isEmpty else {
            loginError = "请输入学号"
            return
        }
        guard !password.isEmpty else {
            loginError = "请输入密码"
            return
        }
        if school.id == .gut {
            let isTenDigits = studentId.count == 10 && studentId.allSatisfy { $0.isNumber }
            guard isTenDigits else {
                loginError = "桂工学号为 10 位数字"
                return
            }
        }
        loginLoading = true
        loginError = nil
        defer { loginLoading = false }

        let captcha = showCaptcha ? captchaText : ""
        // 单飞合并：已有登录在跑时直接等它、复用结果。
        let outcome = await performLogin(captcha: captcha)

        switch outcome {
        case .success:
            AppLogger.shared.log("login \(school.id) success")
            // 登录成功即保存账号，下次启动免输。
            CredentialsStore.save(schoolId: school.id, studentId: studentId, password: password)
            // 读该用户 + 该校的课表外观（build 48）：换账号登录即换一套。
            loadScheduleAppearance()
            isLoggedIn = true
            loginError = nil
            showCaptcha = false
            captchaText = ""
            // 直接关登录页：切换账号时 isLoggedIn 本来就是 true，LoginView 的
            // onChange 不会触发（true→true 无变化），不靠它关页。
            // 启动静默登录时登录页本来就没开，置 false 是空操作。
            showLoginSheet = false
            await refreshSchedule()
        case .failure(let message):
            AppLogger.shared.log("login \(school.id) failure: \(message)")
            isLoggedIn = false
            loginError = message
            // 失败后验证码作废，重新取一张（桂工每次登录都要新图）。
            if school.id == .gut || showCaptcha {
                await fetchCaptcha()
            }
        case .captchaRequired:
            AppLogger.shared.log("login \(school.id) captchaRequired")
            loginError = "请输入验证码"
            await fetchCaptcha()
        }
    }

    /// 切换账号（我的页“更换账号”）：只打开登录页，什么都不清。
    /// Russell 2026-11-18 12:26 定：不要清账号密码，留着，他自己会在登录页删。
    /// 登录页的学号/密码框直接绑 appState，旧账号已预填，他删了重输即可。
    /// 登录成功后 login() 会覆盖保存新账号、自动刷新课表替换旧数据；
    /// 取消切换则一切不变。
    /// build 33 的闪退就是清数据惹的：同步清学号/密码/isLoggedIn + Task 清
    /// 凭据/缓存/课表/成绩/Cookie，跟弹页和登录页的预填抢状态。什么都不清，
    /// 就没东西可抢。不要再加回任何清理——这是 Russell 的决定。
    func switchAccount() {
        AppLogger.shared.log("switch account: school=\(school.id.rawValue)")
        showLoginSheet = true
    }

    func logout() {
        let oldStudentId = studentId
        ModuleDiskCache.clear(schoolId: school.id, account: oldStudentId, key: "scores")
        ModuleDiskCache.clear(schoolId: school.id, account: oldStudentId, key: "exams")
        AppLogger.shared.log("logout: school=\(school.id.rawValue)")
        isLoggedIn = false
        studentId = ""
        password = ""
        studentName = ""
        courses = []
        // 退出登录清掉该校该账号的课表缓存，换账号不会看到上一个人的课。
        ScheduleStore.clear(schoolId: school.id, account: oldStudentId)
        scores = []
        scoresError = nil
        exams = []
        examsError = nil
        scheduleError = nil
        loginError = nil
        captchaImageData = nil
        captchaText = ""
        showCaptcha = false
        showCaptchaDialog = false
        NetworkClient.shared.cookies.clearAll()
        // 退出登录清掉全部已存账号（下次启动不再自动登录）。
        CredentialsStore.clearAll()
        // 外观回到默认（未登录的 guest 键）。
        loadScheduleAppearance()
    }

    /// 启动恢复：有已存账号才做事。
    /// 职师院默认不要验证码：启动时静默登录一次，顺带拉新课表（旧版“只登一遍”）。
    /// 桂工每次都要验证码：启动时不尝试登录——空验证码登录必失败，还会给账号记一次失败；
    /// 只取一张验证码图，登录页打开时直接能用。课表先显示缓存，等用户点刷新再登录。
    func tryAutoLogin() async {
        guard !studentId.isEmpty, !password.isEmpty else { return }
        if school.id == .gxvnu {
            await login()
        } else {
            if captchaImageData == nil { await fetchCaptcha() }
        }
    }

    // MARK: - 课表

    /// 拉课表。会话过期时自动重登一次再试。
    func refreshSchedule() async {
        guard isLoggedIn else { return }
        // 防重入（build 43）：正在刷新时再点刷新直接忽略。
        guard !isRefreshingSchedule else { return }
        isRefreshingSchedule = true
        scheduleLoading = true
        scheduleError = nil
        // build 64：刷新开始记一条，不然只记成功/失败，日志里看不到“点了刷新”。
        AppLogger.shared.log("schedule refresh start: school=\(school.id.rawValue) year=\(year) semester=\(semester)")
        defer {
            scheduleLoading = false
            isRefreshingSchedule = false
        }

        let currentSchoolId = school.id
        let targetYear = year
        let targetSemester = semester
        do {
            let list = try await performWithAutoRelogin {
                if currentSchoolId == .gut {
                    return try await GUTService.fetchSchedule(year: targetYear, semester: targetSemester)
                } else {
                    return try await GXVNUService.fetchSchedule(year: targetYear, semester: targetSemester)
                }
            }
            guard school.id == currentSchoolId else { return }
            if currentSchoolId == .gut {
                if studentName.isEmpty, let name = await GUTService.fetchStudentName(), !name.isEmpty {
                    studentName = name
                }
            } else {
                if let name = GXVNUService.lastStudentName, !name.isEmpty {
                    studentName = name
                }
            }
            courses = list
            AppLogger.shared.log("schedule \(school.id) ok, \(list.count) courses")
            // 拉成功就写缓存，下次启动不登录也能看首页。
            // build 43：缓存防冲刷（专家意见）——只有拉到的课表非空才写缓存；
            // 解析失败/拦截页返回空数组时，绝不能把本地原本存好的课表覆盖成空。
            if !list.isEmpty {
                ScheduleStore.save(schoolId: school.id, account: studentId, courses: list, studentName: studentName)
            }
            if list.isEmpty { scheduleError = "本周没有课程" }
            // build 63：拉课表成功后的联动——日历自动同步 + 上课提醒重排。
            handleScheduleRefreshed()
        } catch let error as ScheduleError {
            AppLogger.shared.log("schedule \(school.id) error: \(error.errorDescription ?? "未知")")
            if case .sessionExpired = error {
                scheduleError = "登录已过期，请重新登录"
            } else {
                scheduleError = error.errorDescription
            }
        } catch {
            scheduleError = (error as? LocalizedError)?.errorDescription ?? "拉取课表失败"
        }
    }

    /// 拉课表成功后的联动（build 63）：日历自动同步 + 上课提醒重排。
    /// 用 Task 后台跑，不阻塞刷新返回；失败静默（下次刷新再试）。
    private func handleScheduleRefreshed() {
        guard !courses.isEmpty else { return }
        let school = self.school
        let courses = self.courses
        let week = currentWeek
        if AppSettings.autoCalendarSync {
            Task {
                let syncCourses: [Course]
                if AppSettings.calendarSyncRange == 1 {
                    // 本周起：只同步当前周及以后的课（Course.weeks 是 let，重新构造）。
                    syncCourses = courses.compactMap { c in
                        let weeks = c.weeks.filter { $0 >= week }
                        guard !weeks.isEmpty else { return nil }
                        return Course(
                            name: c.name, teacher: c.teacher, location: c.location,
                            weekday: c.weekday, startSection: c.startSection,
                            endSection: c.endSection, weeks: weeks, extra: c.extra)
                    }
                } else {
                    syncCourses = courses
                }
                _ = await CalendarExporter.export(
                    courses: syncCourses,
                    school: school,
                    calendarName: "\(school.displayName) 课表",
                    remindOn: false, remindMinutes: 0,
                    secondRemind: false, endRemind: false,
                    onProgress: { _, _ in }
                )
                AppLogger.shared.log("auto calendar sync done")
            }
        }
        if AppSettings.classReminderEnabled {
            Task {
                await ReminderManager.rescheduleClassReminders(
                    courses: courses, school: school,
                    leadMinutes: AppSettings.classReminderMinutes)
            }
        }
    }

    // MARK: - 成绩

    /// 拉成绩（全部学年学期）。会话过期时自动重登一次再试。
    func refreshScores(year filterYear: Int? = nil, term filterTerm: String? = nil) async {
        guard isLoggedIn else { return }
        // 代次顶替：新请求（比如快速切学年/学期）直接顶掉在跑的旧请求，
        // 旧结果回来按代次丢弃。原来防重入把新请求吞掉，页面会停在旧筛选。
        scoresRefreshGeneration += 1
        let generation = scoresRefreshGeneration
        isRefreshingScores = true
        scoresLoading = true
        scoresError = nil
        defer {
            if generation == scoresRefreshGeneration {
                scoresLoading = false
                isRefreshingScores = false
            }
        }

        do {
        let currentSchoolId = school.id
        let list: [CourseScore] = try await performWithAutoRelogin {
            if currentSchoolId == .gut {
                return try await GUTService.fetchScores(year: filterYear, term: filterTerm)
            } else {
                return try await GXVNUService.fetchScores(year: filterYear, term: filterTerm)
            }
        }
            guard school.id == currentSchoolId, generation == scoresRefreshGeneration else { return }
        scores = list
            // 空结果不写缓存（和课表防冲刷同款）：服务端异常返回空时，
            // 别把本地存好的成绩覆盖成空。
            if filterYear == nil && filterTerm == nil && !list.isEmpty {
        ModuleDiskCache.save(scores, schoolId: school.id, account: studentId, key: "scores")
            }
        AppLogger.shared.log("scores \(school.id) ok, \(list.count) items")
        if list.isEmpty { scoresError = "暂无成绩" }
    } catch let error as ScheduleError {
        // 被新请求顶掉的旧请求报错不写页面（新请求还在跑/已回来）。
        guard generation == scoresRefreshGeneration else { return }
        if case .sessionExpired = error {
            AppLogger.shared.log("scores \(school.id) session expired")
            scoresError = "登录已过期，请重新登录"
        } else {
            scoresError = error.errorDescription
        }
    } catch {
        guard generation == scoresRefreshGeneration else { return }
        scoresError = (error as? LocalizedError)?.errorDescription ?? "拉取成绩失败"
        }
    }

    // MARK: - 考试

    /// 拉考试安排（build 43 新增）。会话过期时自动重登一次再试（同课表/成绩）。
    func refreshExams() async {
        guard isLoggedIn else { return }
        guard !examsLoading else { return }
        examsLoading = true
        examsError = nil
        defer { examsLoading = false }

        do {
            let currentSchoolId = school.id
        let currentYear = year
        let currentSemester = semester
        let list: [ExamItem] = try await performWithAutoRelogin {
            if currentSchoolId == .gut {
                return try await GUTService.fetchExams()
            } else {
                return try await GXVNUService.fetchExams(year: currentYear, semester: currentSemester)
            }
        }
            // 学校/学年/学期在请求期间变了就丢弃，别把旧学期考试写进新页面。
            guard school.id == currentSchoolId, year == currentYear, semester == currentSemester else { return }
            exams = list
            // 空结果不写缓存、不重排提醒（和课表防冲刷同款）：服务端异常
            // 返回空时，别把存好的考试和已排的考试提醒一起清掉。
            if !list.isEmpty {
                ModuleDiskCache.save(exams, schoolId: school.id, account: studentId, key: "exams")
            }
            AppLogger.shared.log("exams \(school.id) ok, \(list.count) items")
            if list.isEmpty { examsError = "暂无考试安排" }
            // build 63：考试拉成功后，考试提醒开了就重排。
            if AppSettings.examReminderEnabled && !list.isEmpty {
                let exams = list
                Task {
                    await ReminderManager.rescheduleExamReminders(
                        exams: exams, leadDays: AppSettings.examReminderDays)
                }
            }
        } catch let error as ScheduleError {
            if case .sessionExpired = error {
                AppLogger.shared.log("exams \(school.id) session expired")
            examsError = "登录已过期，请重新登录" 
            } else {
                examsError = error.errorDescription
            }
        } catch {
            examsError = (error as? LocalizedError)?.errorDescription ?? "拉取考试失败"
        }
    }
    private func resolveReloginWaiters(_ success: Bool) {
        let waiters = reloginContinuations
        reloginContinuations.removeAll()
        for continuation in waiters {
            continuation.resume(returning: success)
        }
    }
    private func waitForCaptchaRelogin() async -> Bool {
        await withCheckedContinuation { continuation in
              reloginContinuations.append(continuation)
                                      }
    }
    func performWithAutoRelogin<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch ScheduleError.sessionExpired {
            if showCaptchaDialog {
                let ok = await waitForCaptchaRelogin()
                if ok {
                    return try await operation()
                }
                throw ScheduleError.sessionExpired
            }
            if school.id == .gxvnu {
                let reloginOutcome = await reloginGXVNU()
                if reloginOutcome == .success {
                    return try await operation()
                } else if reloginOutcome == .captchaRequired {
                let ok = await waitForCaptchaRelogin()
                if ok {
                    return try await operation()
                }
                }
            } else if school.id == .gut {
                if !studentId.isEmpty && !password.isEmpty {
                    captchaDialogText = ""
                    captchaChecking = false
                    showCaptchaDialog = true
                    Task { await fetchCaptcha() }
                let ok = await waitForCaptchaRelogin()
                if ok {
                    return try await operation()
                }
                }
            }
            throw ScheduleError.sessionExpired
        }
    }

    /// 本周的课（按星期分组后展平，星期 1-7，节次升序）。
    var thisWeekCourses: [Course] {
        courses
            .filter { $0.weeks.contains(currentWeek) }
            .sorted {
                if $0.weekday != $1.weekday { return $0.weekday < $1.weekday }
                return $0.startSection < $1.startSection
            }
    }
}

// MARK: - 本地提醒（build 63：上课提醒 + 考试提醒，系统本地通知，不走服务器）

/// 提醒调度。通知 ID 带前缀，方便按类取消；每次重排先清掉同类旧通知再重排，
/// 课表/考试变了也不会留过期提醒。
enum ReminderManager {
    static let classPrefix = "class-reminder-"
    static let examPrefix = "exam-reminder-"

    /// 请求通知权限（只在用户打开提醒开关时调）。
    static func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    /// 按当前课表重排上课提醒：排本周 + 下周的课，提醒时间 = 上课开始 − 提前分钟。
    /// 已过的课跳过。
    static func rescheduleClassReminders(courses: [Course], school: SchoolConfig, leadMinutes: Int) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let oldIds = pending.map(\.identifier).filter { $0.hasPrefix(classPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: oldIds)

        let cal = Calendar(identifier: .gregorian)
        let week = currentWeek(for: school)
        // 按开学周的周一对齐（和课表网格/日历导出同一算法）：开学日不是
        // 周一时，不对齐的话提醒日期会和课表上显示的日期差好几天。
        let termStart = termStartMonday(for: school)
        // iOS 待发通知上限 64 条（超了系统静默丢弃）：上课提醒最多占 54 条，
        // 给考试提醒留 10 条，两边加起来不超限。
        var count = 0
        for course in courses {
            guard count < 54 else { break }
            guard (1...7).contains(course.weekday),
                  course.startSection >= 1,
                  course.startSection <= school.effectiveStartTimeList.count else { continue }
            for w in course.weeks where w >= week && w <= week + 1 {
                guard count < 54 else { break }
                guard let day = cal.date(byAdding: .day, value: (w - 1) * 7 + (course.weekday - 1), to: termStart),
                      let start = cal.date(
                          bySettingHour: school.effectiveStartTimeList[course.startSection - 1].0,
                          minute: school.effectiveStartTimeList[course.startSection - 1].1,
                          second: 0, of: day)
                else { continue }
                let fire = start.addingTimeInterval(TimeInterval(-leadMinutes * 60))
                guard fire > Date() else { continue }
                let content = UNMutableNotificationContent()
                content.title = course.name
                content.body = "第\(course.startSection)-\(course.endSection)节 · \(course.location.isEmpty ? "上课" : course.location)"
                content.sound = .default
                let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let id = "\(classPrefix)\(course.name)-\(w)-\(course.weekday)-\(course.startSection)"
                try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                count += 1
            }
        }
        AppLogger.shared.log("class reminders scheduled: \(count)")
    }

    /// 取消全部上课提醒。
    static func cancelClassReminders() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(classPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// 从考试时间串里提取开始时刻：日期（yyyy-MM-dd 或 yyyy/MM/dd）+ 第一个
    /// HH:mm。两校格式不统一（"2026-01-05 08:00--10:00"、单横线、斜杠日期
    /// 都见过），按正则提取比固定取前 16 位稳；提取不到返回 nil。
    private static func examStartDate(_ timeRange: String) -> Date? {
        guard let dateRegex = try? NSRegularExpression(pattern: #"(\d{4})[-/](\d{1,2})[-/](\d{1,2})"#),
              let timeRegex = try? NSRegularExpression(pattern: #"(\d{1,2}):(\d{2})"#) else { return nil }
        let range = NSRange(timeRange.startIndex..., in: timeRange)
        guard let dm = dateRegex.firstMatch(in: timeRange, options: [], range: range),
              dm.numberOfRanges >= 4,
              let yR = Range(dm.range(at: 1), in: timeRange),
              let moR = Range(dm.range(at: 2), in: timeRange),
              let dR = Range(dm.range(at: 3), in: timeRange),
              let year = Int(timeRange[yR]), let month = Int(timeRange[moR]), let day = Int(timeRange[dR]),
              let tm = timeRegex.firstMatch(in: timeRange, options: [], range: range),
              tm.numberOfRanges >= 3,
              let hR = Range(tm.range(at: 1), in: timeRange),
              let miR = Range(tm.range(at: 2), in: timeRange),
              let hour = Int(timeRange[hR]), let minute = Int(timeRange[miR]) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        return cal.date(from: comps)
    }

    /// 按待考重排考试提醒：每场考试提前 leadDays 天（考试开始 − leadDays×24h）提醒。
    /// 解析失败/已过的跳过。最多排 10 条（按考试时间从近到远）：
    /// iOS 待发通知总上限 64 条，上课提醒占 54，这里留 10，不超限被系统丢。
    static func rescheduleExamReminders(exams: [ExamItem], leadDays: Int) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let oldIds = pending.map(\.identifier).filter { $0.hasPrefix(examPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: oldIds)

        // 先把能解析出开始时间的待考按时间排序，近的优先占名额。
        let upcoming: [(exam: ExamItem, start: Date)] = exams
            .filter { !$0.isPast }
            .compactMap { exam in examStartDate(exam.time).map { (exam, $0) } }
            .sorted { $0.start < $1.start }
        var count = 0
        for (exam, start) in upcoming {
            guard count < 10 else { break }
            let fire = start.addingTimeInterval(TimeInterval(-leadDays * 24 * 3600))
            guard fire > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = "考试提醒"
            content.body = "\(exam.courseName) · \(exam.time) · \(exam.location.isEmpty ? "考场待定" : exam.location)"
            content.sound = .default
            let comps = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let id = "\(examPrefix)\(exam.courseName)-\(exam.time)"
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            count += 1
        }
        AppLogger.shared.log("exam reminders scheduled: \(count)")
    }

    /// 取消全部考试提醒。
    static func cancelExamReminders() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(examPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}

// MARK: - 数据管理 / 备份与恢复（build 63）

/// 备份文件格式：全部设置 + 两校缓存课表。只含设置和课表，不含账号密码。
struct AppBackup: Codable {
    var version: Int = 1
    var autoCalendarSync: Bool
    var calendarSyncRange: Int
    var classReminderEnabled: Bool
    var classReminderMinutes: Int
    var examReminderEnabled: Bool
    var examReminderDays: Int
    var showRecentExams: Bool
    var showTomorrowCourses: Bool
    var showGreeting: Bool
    var wallpaper: Int
    var autoRefreshOnLaunch: Bool
    var scoreDisplayMode: Int
    var gutCourses: [Course]
    var gutStudentName: String
    var gxvnuCourses: [Course]
    var gxvnuStudentName: String
    var gutTermStartOverride: Double?
    var gxvnuTermStartOverride: Double?
    var gutTotalWeeks: Int
    var gxvnuTotalWeeks: Int
    // 以下都是可选字段：旧版备份没有这些键，解码时为 nil、导入时跳过，
    // 不影响旧备份恢复；新版导出时带上，换手机不丢外观/作息/调课开关/壁纸图。
    var gutAppearance: ScheduleAppearance? = nil
    var gxvnuAppearance: ScheduleAppearance? = nil
    var gutSectionTimes: CustomSectionTimes? = nil
    var gxvnuSectionTimes: CustomSectionTimes? = nil
    var showScheduleChange: Bool? = nil
    /// 自定义壁纸图（Documents/custom-wallpaper.jpg 的内容，JSON 里是 base64）。
    var customWallpaperImage: Data? = nil
}

extension AppState {
    /// 清除全部缓存（数据管理）：两校课表缓存文件 + 内存里的课表/成绩/考试。
    /// 不清账号密码（Russell 永久纠正：账号密码他自己删）。
    func clearAllCachedData() {
        ScheduleStore.clearAll(schoolId: .gut)
        ScheduleStore.clearAll(schoolId: .gxvnu)
        let moduleKeys = ["scores", "exams", "gxvnu_career"]
        if !studentId.isEmpty {
            for key in moduleKeys {
                ModuleDiskCache.clear(schoolId: school.id, account: studentId, key: key)
            }
        }
        for sid in [SchoolID.gut, .gxvnu] {
            if let saved = CredentialsStore.load(schoolId: sid), !saved.studentId.isEmpty {
                for key in moduleKeys {
                    ModuleDiskCache.clear(schoolId: sid, account: saved.studentId, key: key)
                }
            }
        }
        courses = []
        scores = []
        exams = []
        scoresError = nil
        examsError = nil
        AppLogger.shared.log("cache cleared")
    }

    /// 重新拉取全部（数据管理）：课表 + 成绩 + 考试。
    func refreshAll() async {
        await refreshSchedule()
        await refreshScores()
        await refreshExams()
    }

    /// 读某校某学号存着的课表外观（备份导出用；没存过返回 nil）。
    private func storedAppearance(schoolId: SchoolID, account: String) -> ScheduleAppearance? {
        let key = Self.appearanceKey(schoolId: schoolId, studentId: account)
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ScheduleAppearance.self, from: data)
    }

    /// 把外观存到某校某学号名下（备份导入用）。
    private func storeAppearance(_ appearance: ScheduleAppearance, schoolId: SchoolID, account: String) {
        let key = Self.appearanceKey(schoolId: schoolId, studentId: account)
        if let data = try? JSONEncoder().encode(appearance) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 导出备份到临时文件（备份与恢复）：返回文件 URL，供 ShareLink 分享。
    func exportBackup() -> URL? {
        // 课表缓存按学号存：每所学校用各自已存的学号找（当前校兜底用正在用的学号）。
        let gutAccount = CredentialsStore.savedStudentId(schoolId: .gut) ?? (school.id == .gut ? studentId : "")
        let gxvnuAccount = CredentialsStore.savedStudentId(schoolId: .gxvnu) ?? (school.id == .gxvnu ? studentId : "")
        let gut = ScheduleStore.load(schoolId: .gut, account: gutAccount)
        let gxvnu = ScheduleStore.load(schoolId: .gxvnu, account: gxvnuAccount)
        let backup = AppBackup(
            autoCalendarSync: AppSettings.autoCalendarSync,
            calendarSyncRange: AppSettings.calendarSyncRange,
            classReminderEnabled: AppSettings.classReminderEnabled,
            classReminderMinutes: AppSettings.classReminderMinutes,
            examReminderEnabled: AppSettings.examReminderEnabled,
            examReminderDays: AppSettings.examReminderDays,
            showRecentExams: AppSettings.showRecentExams,
            showTomorrowCourses: AppSettings.showTomorrowCourses,
            showGreeting: AppSettings.showGreeting,
            wallpaper: AppSettings.wallpaper,
            autoRefreshOnLaunch: AppSettings.autoRefreshOnLaunch,
            scoreDisplayMode: AppSettings.scoreDisplayMode,
            gutCourses: gut?.courses ?? [],
            gutStudentName: gut?.studentName ?? "",
            gxvnuCourses: gxvnu?.courses ?? [],
            gxvnuStudentName: gxvnu?.studentName ?? "",
            gutTermStartOverride: AppSettings.termStartDateOverride(for: .gut)?.timeIntervalSince1970,
            gxvnuTermStartOverride: AppSettings.termStartDateOverride(for: .gxvnu)?.timeIntervalSince1970,
            gutTotalWeeks: AppSettings.totalWeeks(for: .gut),
            gxvnuTotalWeeks: AppSettings.totalWeeks(for: .gxvnu),
            gutAppearance: storedAppearance(schoolId: .gut, account: gutAccount),
            gxvnuAppearance: storedAppearance(schoolId: .gxvnu, account: gxvnuAccount),
            gutSectionTimes: CustomSectionTimes.load(for: .gut),
            gxvnuSectionTimes: CustomSectionTimes.load(for: .gxvnu),
            showScheduleChange: GUTService.showScheduleChange,
            customWallpaperImage: hasCustomWallpaper() ? customWallpaperData() : nil
        )
        guard let data = try? JSONEncoder().encode(backup) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zhizhou-backup.json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// 导入备份（备份与恢复）：恢复设置 + 两校缓存课表，返回是否成功。
    /// 导入后重新读缓存进内存；不碰账号密码。
    func importBackup(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let backup = try? JSONDecoder().decode(AppBackup.self, from: data),
              backup.version == 1 else { return false }
        AppSettings.autoCalendarSync = backup.autoCalendarSync
        AppSettings.calendarSyncRange = backup.calendarSyncRange
        AppSettings.classReminderEnabled = backup.classReminderEnabled
        AppSettings.classReminderMinutes = backup.classReminderMinutes
        AppSettings.examReminderEnabled = backup.examReminderEnabled
        AppSettings.examReminderDays = backup.examReminderDays
        AppSettings.showRecentExams = backup.showRecentExams
        AppSettings.showTomorrowCourses = backup.showTomorrowCourses
        AppSettings.showGreeting = backup.showGreeting
        // 壁纸必须走 AppState 的 wallpaper（@Observable，didSet 同步 UserDefaults）：
        // 只写 AppSettings.wallpaper 的话内存里还是旧值，要重启才生效。
        wallpaper = backup.wallpaper
        if let image = backup.customWallpaperImage {
            saveCustomWallpaper(image)
            customWallpaperVersion += 1
        }
        if let showChange = backup.showScheduleChange {
            GUTService.showScheduleChange = showChange
        }
        AppSettings.autoRefreshOnLaunch = backup.autoRefreshOnLaunch
        AppSettings.scoreDisplayMode = backup.scoreDisplayMode
        AppSettings.setTermStartDateOverride(
            backup.gutTermStartOverride.map { Date(timeIntervalSince1970: $0) }, for: .gut)
        AppSettings.setTermStartDateOverride(
            backup.gxvnuTermStartOverride.map { Date(timeIntervalSince1970: $0) }, for: .gxvnu)
        AppSettings.setTotalWeeks(backup.gutTotalWeeks, for: .gut)
        AppSettings.setTotalWeeks(backup.gxvnuTotalWeeks, for: .gxvnu)
        updateTermFromDate()
        // 备份里不带学号：按每所学校已存的学号存（当前校兜底用正在用的学号），
        // 找不到学号的那所学校就不存缓存，登录后拉一次课表自然恢复。
        let gutAccount = CredentialsStore.savedStudentId(schoolId: .gut) ?? (school.id == .gut ? studentId : "")
        let gxvnuAccount = CredentialsStore.savedStudentId(schoolId: .gxvnu) ?? (school.id == .gxvnu ? studentId : "")
        // 外观按学校 + 学号存（和课表缓存同款找学号）；备份里没有（旧备份）
        // 就跳过，不动现在的。存完重读当前校外观，导入立刻生效。
        if let appearance = backup.gutAppearance {
            storeAppearance(appearance, schoolId: .gut, account: gutAccount)
        }
        if let appearance = backup.gxvnuAppearance {
            storeAppearance(appearance, schoolId: .gxvnu, account: gxvnuAccount)
        }
        if backup.gutAppearance != nil || backup.gxvnuAppearance != nil {
            loadScheduleAppearance()
        }
        // 自定义作息按学校存；备份里有才覆盖，并 bump 版本号让页面立刻重读。
        if let times = backup.gutSectionTimes {
            CustomSectionTimes.save(times, for: .gut)
        }
        if let times = backup.gxvnuSectionTimes {
            CustomSectionTimes.save(times, for: .gxvnu)
        }
        if backup.gutSectionTimes != nil || backup.gxvnuSectionTimes != nil {
            sectionTimesVersion += 1
        }
        // 备份里没课表的那所学校（导出时没缓存）别写盘：无条件 save 会把
        // 本机另一所学校已有的缓存抹成空。空数组 = 备份没带这校数据，跳过。
        if !backup.gutCourses.isEmpty {
            ScheduleStore.save(schoolId: .gut, account: gutAccount, courses: backup.gutCourses, studentName: backup.gutStudentName)
        }
        if !backup.gxvnuCourses.isEmpty {
            ScheduleStore.save(schoolId: .gxvnu, account: gxvnuAccount, courses: backup.gxvnuCourses, studentName: backup.gxvnuStudentName)
        }
        if let cached = ScheduleStore.load(schoolId: school.id, account: studentId) {
            courses = cached.courses
            studentName = cached.studentName
        }
        // build 72：导入后立刻重排提醒。之前只恢复了开关，系统里到点响的
        // 提醒是空的，得等下次刷新课表才回来——开关显示开着，提醒实际没排上。
        // 恢复出来的课表就在 courses 里，直接拿它排；考试不在备份里，用当前
        // 的 exams（空就排不上，等考试刷新后自动重排）。reschedule 内部不弹
        // 权限申请，没授权就静默排不上，导入时不打扰用户。
        if AppSettings.classReminderEnabled {
            let restoredCourses = courses
            let currentSchool = school
            let leadMinutes = AppSettings.classReminderMinutes
            Task {
                await ReminderManager.rescheduleClassReminders(
                    courses: restoredCourses, school: currentSchool, leadMinutes: leadMinutes)
            }
        } else {
            Task { await ReminderManager.cancelClassReminders() }
        }
        if AppSettings.examReminderEnabled {
            let currentExams = exams
            let leadDays = AppSettings.examReminderDays
            Task {
                await ReminderManager.rescheduleExamReminders(exams: currentExams, leadDays: leadDays)
            }
        } else {
            Task { await ReminderManager.cancelExamReminders() }
        }
        AppLogger.shared.log("backup imported")
        return true
    }
}
