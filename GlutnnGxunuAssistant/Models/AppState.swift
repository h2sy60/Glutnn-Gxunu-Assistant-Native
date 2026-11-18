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

    /// 验证码（桂工每次都要；职师院按需）。图片数据 + 用户输入。
    var captchaImageData: Data?
    var captchaText = ""
    var showCaptcha = false

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
        let outcome: LoginOutcome
        if school.id == .gut {
            outcome = await GUTService.login(studentId: studentId, password: password, captcha: captcha)
        } else {
            outcome = await GXVNUService.login(studentId: studentId, password: password, captcha: captcha)
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
                // 空验证码重登必失败还记一次失败，直接落回登录页等用户输验证码。
                if school.id == .gut {
                    isLoggedIn = false
                    scheduleError = "登录已过期，请重新登录"
                } else {
                    let outcome = await GXVNUService.login(studentId: studentId, password: password, captcha: "")
                    if case .success = outcome {
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
                        isLoggedIn = false
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
                // 桂工重登要验证码，直接落回登录页；职师院静默重登一次。
                if school.id == .gut {
                    isLoggedIn = false
                    scoresError = "登录已过期，请重新登录"
                } else {
                    let outcome = await GXVNUService.login(studentId: studentId, password: password, captcha: "")
                    if case .success = outcome {
                        do {
                            let list = try await GXVNUService.fetchScores(year: year)
                            scores = list
                            if list.isEmpty { scoresError = "暂无成绩" }
                        } catch {
                            scoresError = (error as? LocalizedError)?.errorDescription ?? "拉取成绩失败"
                        }
                    } else {
                        isLoggedIn = false
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
