import Foundation
import Security
import SwiftUI

// MARK: - 应用内日志（诊断用）
//
// 原生版之前没有日志功能，出了问题只能靠猜。关键步骤都记下来，
// 在「我的」页点「导出日志」可以分享出去。只记在内存里，不写磁盘，
// 可变状态全由 NSLock 保护，所以标 @unchecked Sendable（编译器无法自行证明）。
// 不含密码（密码只传给教务服务器，绝不记日志）。
final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()
    private let lock = NSLock()
    private var lines: [String] = []
    private let maxLines = 2000
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append("[\(formatter.string(from: Date()))] \(message)")
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    func exportText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
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
            kSecValueData as String: data,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
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
// 现在每次拉课表成功就写一份 JSON 到沙盒（按学校分文件），启动和切学校时读出来。
// 退出登录时清掉缓存，换账号不会看到上一个人的课。
enum ScheduleStore {
    private struct SavedSchedule: Codable {
        var courses: [Course]
        var studentName: String
    }

    private static func fileURL(schoolId: SchoolID) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("schedule_\(schoolId.rawValue).json")
    }

    /// 拉课表成功后调：把课表 + 名字写进磁盘。
    static func save(schoolId: SchoolID, courses: [Course], studentName: String) {
        let payload = SavedSchedule(courses: courses, studentName: studentName)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL(schoolId: schoolId), options: .atomic)
    }

    /// 启动 / 切学校时调：读出缓存（没有返回 nil）。
    static func load(schoolId: SchoolID) -> (courses: [Course], studentName: String)? {
        guard let data = try? Data(contentsOf: fileURL(schoolId: schoolId)),
              let payload = try? JSONDecoder().decode(SavedSchedule.self, from: data) else { return nil }
        return (payload.courses, payload.studentName)
    }

    /// 退出登录时调：清掉该校缓存。
    static func clear(schoolId: SchoolID) {
        try? FileManager.default.removeItem(at: fileURL(schoolId: schoolId))
    }
}

// MARK: - 登录 / 课表结果

enum LoginOutcome {
    case success
    /// 登录失败（文案可直接展示）。
    case failure(String)
    /// 服务器要求验证码（职师院）：取图后让用户输入再试。
    case captchaRequired
}

enum ScheduleError: Error, LocalizedError {
    case sessionExpired
    case network(String)
    case parseError
    case empty

    var errorDescription: String? {
        switch self {
        case .sessionExpired: return "登录已过期，正在重新登录"
        case .network(let msg): return msg
        case .parseError: return "课表解析失败"
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

    /// 登录状态。
    var loginLoading = false
    var loginError: String?

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
            dismissToast()
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
    var showCaptchaDialog = false
    var captchaDialogText = ""
    var captchaChecking = false

    /// 正在登录（全量登录 / 静默重登共用）：同一时间只登一次。
    /// 两个登录并发会互相顶掉会话（Cookie/CSRFT 串掉），表现就是
    /// “账号密码不正确”——明明密码没错，只是两次登录把会话搞脏了。
    /// 所有登录入口（login / 静默重登）都走这把锁。
    private var isLoginInProgress = false

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
        if let cached = ScheduleStore.load(schoolId: school.id) {
            courses = cached.courses
            if !cached.studentName.isEmpty { studentName = cached.studentName }
        }
    }

    /// 按当前日期算学年学期（8 月及以后为秋季学期）。
    func updateTermFromDate(_ date: Date = Date()) {
        let month = Calendar(identifier: .gregorian).component(.month, from: date)
        let y = Calendar(identifier: .gregorian).component(.year, from: date)
        if month >= 8 {
            semester = "秋"
            year = y
        } else {
            semester = "春"
            year = y - 1
        }
        currentWeek = GlutnnGxunuAssistant.currentWeek(for: school, on: date)
    }

    /// 切学校：换配置、清登录态和验证码。已输的学号密码按学校保存，回来接着用（Flutter _switchSchool 同款）。
    /// Cookie 按 host 分桶，不用清。
    func switchSchool(_ newSchool: SchoolConfig) {
        guard newSchool.id != school.id else { return }
        // 先把当前学校的输入存下来（哪怕还没登录成功，下次回来也能接着输）。
        if !studentId.isEmpty {
            CredentialsStore.save(schoolId: school.id, studentId: studentId, password: password)
        }
        school = newSchool
        isLoggedIn = false
        // 恢复目标学校已存的账号；没有就清空输入框。
        if let saved = CredentialsStore.load(schoolId: newSchool.id) {
            studentId = saved.studentId
            password = saved.password
        } else {
            studentId = ""
            password = ""
        }
        studentName = ""
        // 读目标学校的缓存课表（没有就空着，等登录后拉）。不直接清空：旧版切学校后首页照样显示该校缓存。
        if let cached = ScheduleStore.load(schoolId: newSchool.id) {
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
        showCaptcha = false
        updateTermFromDate()
    }

    // MARK: - 验证码

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
                showCaptchaDialog = true
            } else {
                showToast(.error, "验证码获取失败，请稍后重试", duration: 4)
                showLoginSheet = true
            }
            return
        }
        // 职师院：静默重登（串行，防并发顶掉会话）。
        guard let outcome = await performLogin(captcha: "") else {
            showToast(.error, "正在登录，请稍候", duration: 2)
            return
        }
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
                showCaptchaDialog = true
            } else {
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
        guard !captchaChecking else { return }
        guard !captchaDialogText.isEmpty else {
            showToast(.error, "请输入验证码", duration: 2)
            return
        }
        captchaChecking = true
        defer { captchaChecking = false }
        guard let outcome = await performLogin(captcha: captchaDialogText) else {
            // 已有登录在跑，等那次的结果，留在弹窗里。
            showToast(.error, "正在登录，请稍候", duration: 2)
            return
        }
        switch outcome {
        case .success:
            AppLogger.shared.log("reverify \(school.id) success")
            isLoggedIn = true
            showCaptchaDialog = false
            captchaDialogText = ""
            captchaText = ""
            showCaptcha = false
            await refreshSchedule()
            if scheduleError == nil {
                showToast(.success, "数据已更新!", duration: 1)
            } else {
                showToast(.error, scheduleError ?? "拉取失败", duration: 4)
            }
        case .failure(let message):
            AppLogger.shared.log("reverify \(school.id) failure: \(message)")
            if message.contains("验证码") {
                showToast(.error, message, duration: 4)
                await fetchCaptcha()
            } else {
                showCaptchaDialog = false
                isLoggedIn = false
                loginError = message
                showLoginSheet = true
            }
        case .captchaRequired:
            showToast(.error, "请输入验证码", duration: 2)
            await fetchCaptcha()
        }
    }

    /// 串行登录（底层）：同一时间只调一次教务登录。返回 nil = 已有登录在跑，
    /// 调用方别另起一次、也别当成失败（等那次登完再说）。
    /// 两个登录并发会把会话顶掉（Cookie/CSRFT 串掉），表现就是“账号密码不正确”。
    private func performLogin(captcha: String) async -> LoginOutcome? {
        guard !isLoginInProgress else { return nil }
        isLoginInProgress = true
        defer { isLoginInProgress = false }
        if school.id == .gut {
            return await GUTService.login(studentId: studentId, password: password, captcha: captcha)
        } else {
            return await GXVNUService.login(studentId: studentId, password: password, captcha: captcha)
        }
    }

    /// 静默重登（职师院，拉课表/成绩时会话过期用）：串行，同一时间只登一次。
    /// 返回 true = 重登成功，会话已恢复。
    private func silentReloginGXVNU() async -> Bool {
        guard let outcome = await performLogin(captcha: "") else { return false }
        if case .success = outcome {
            isLoggedIn = true
            return true
        }
        return false
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
        guard let outcome = await performLogin(captcha: captcha) else {
            // 已有登录在跑，等那次的结果（它成功后 isLoggedIn 变 true，登录页自己关）。
            return
        }

        switch outcome {
        case .success:
            AppLogger.shared.log("login \(school.id) success")
            // 登录成功即保存账号，下次启动免输。
            CredentialsStore.save(schoolId: school.id, studentId: studentId, password: password)
            isLoggedIn = true
            loginError = nil
            showCaptcha = false
            captchaText = ""
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

    /// 切换账号（我的页“更换账号”）：只清本校已存账号 + 本校课表缓存，
    /// 回到未登录态，并直接打开登录页让用户输新账号。
    /// （旧 logout 只清状态不开登录页，点完像没反应——就是 Russell 说的“坏了”。
    /// 另外旧 logout 用 clearAll 会连另一所学校的账号一起清掉。）
    func switchAccount() {
        CredentialsStore.clear(schoolId: school.id)
        ScheduleStore.clear(schoolId: school.id)
        isLoggedIn = false
        studentId = ""
        password = ""
        studentName = ""
        courses = []
        scores = []
        scoresError = nil
        scheduleError = nil
        loginError = nil
        captchaImageData = nil
        captchaText = ""
        captchaDialogText = ""
        showCaptcha = false
        showCaptchaDialog = false
        NetworkClient.shared.cookies.clearAll()
        // 登录页晚一拍再弹：清状态和弹整页放同一拍里会闪退（build 31 实测），
        // 先让这一轮状态落定，下个 runloop 再弹。
        Task { @MainActor in
            showLoginSheet = true
        }
    }

    func logout() {
        isLoggedIn = false
        studentId = ""
        password = ""
        studentName = ""
        courses = []
        // 退出登录清掉该校课表缓存，换账号不会看到上一个人的课。
        ScheduleStore.clear(schoolId: school.id)
        scores = []
        scoresError = nil
        scheduleError = nil
        loginError = nil
        captchaImageData = nil
        captchaText = ""
        showCaptcha = false
        NetworkClient.shared.cookies.clearAll()
        // 退出登录清掉全部已存账号（下次启动不再自动登录）。
        CredentialsStore.clearAll()
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
        scheduleLoading = true
        scheduleError = nil
        defer { scheduleLoading = false }

        do {
            let list: [Course]
            if school.id == .gut {
                list = try await GUTService.fetchSchedule(year: year, semester: semester)
            } else {
                list = try await GXVNUService.fetchSchedule(year: year, semester: semester)
                // 课表响应里顺带取到的姓名（xsxx.XM）。
                if let name = GXVNUService.lastStudentName, !name.isEmpty {
                    studentName = name
                }
            }
            courses = list
            AppLogger.shared.log("schedule \(school.id) ok, \(list.count) courses")
            // 拉成功就写缓存，下次启动不登录也能看首页。
            ScheduleStore.save(schoolId: school.id, courses: list, studentName: studentName)
            if list.isEmpty { scheduleError = "本周没有课程" }
        } catch let error as ScheduleError {
            AppLogger.shared.log("schedule \(school.id) error: \(error.errorDescription ?? "未知")")
            if case .sessionExpired = error {
                // 会话过期：职师院可静默重登一次再拉；桂工每次都要验证码，
                // 空验证码重登必失败还记一次失败，不在这里重登——
                // 只记错误，等首页弹“需要验证”，点按走验证码弹窗重登。
                // 注意：不要在这里把 isLoggedIn 置 false——isLoggedIn 是“有已存账号”
                // （旧版语义），会话过期不等于账号没了；置 false 会让首页的
                // 刷新/成绩/考试直接弹整页登录，验证码弹窗那条路就走不通了。
                if school.id == .gut {
                    scheduleError = "登录已过期，请重新登录"
                } else {
                    // 静默重登（串行，防并发顶掉会话报“账号密码不正确”）。
                    if await silentReloginGXVNU() {
                        do {
                            let list = try await GXVNUService.fetchSchedule(year: year, semester: semester)
                            if let name = GXVNUService.lastStudentName, !name.isEmpty {
                                studentName = name
                            }
                            courses = list
                            ScheduleStore.save(schoolId: school.id, courses: list, studentName: studentName)
                        } catch {
                            scheduleError = (error as? LocalizedError)?.errorDescription ?? "拉取课表失败"
                        }
                    } else {
                        scheduleError = "登录已过期，请重新登录"
                    }
                }
            } else {
                scheduleError = error.errorDescription
            }
        } catch {
            scheduleError = (error as? LocalizedError)?.errorDescription ?? "拉取课表失败"
        }
    }

    // MARK: - 成绩

    /// 拉成绩（全部学年学期）。会话过期时自动重登一次再试。
    func refreshScores() async {
        guard isLoggedIn else { return }
        scoresLoading = true
        scoresError = nil
        defer { scoresLoading = false }

        do {
            let list: [CourseScore]
            if school.id == .gut {
                list = try await GUTService.fetchScores()
            } else {
                list = try await GXVNUService.fetchScores(year: year)
            }
            scores = list
            AppLogger.shared.log("scores \(school.id) ok, \(list.count) items")
            if list.isEmpty { scoresError = "暂无成绩" }
        } catch let error as ScheduleError {
            if case .sessionExpired = error {
                AppLogger.shared.log("scores \(school.id) session expired, relogin once")
                // 桂工重登要验证码，不在这里重登，等“需要验证”走验证码弹窗；
                // 职师院静默重登一次。会话过期不置 isLoggedIn=false（同 refreshSchedule）。
                if school.id == .gut {
                    scoresError = "登录已过期，请重新登录"
                } else {
                    // 静默重登（串行，防并发顶掉会话报“账号密码不正确”）。
                    if await silentReloginGXVNU() {
                        do {
                            let list = try await GXVNUService.fetchScores(year: year)
                            scores = list
                            if list.isEmpty { scoresError = "暂无成绩" }
                        } catch {
                            scoresError = (error as? LocalizedError)?.errorDescription ?? "拉取成绩失败"
                        }
                    } else {
                        scoresError = "登录已过期，请重新登录"
                    }
                }
            } else {
                scoresError = error.errorDescription
            }
        } catch {
            scoresError = (error as? LocalizedError)?.errorDescription ?? "拉取成绩失败"
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
