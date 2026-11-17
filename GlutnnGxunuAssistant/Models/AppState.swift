import Foundation
import SwiftUI

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
// 学号/密码只存在内存里（供会话过期自动重登），不写磁盘、不发给
// 教务以外的任何地方。设置页/持久化以后再做。

@Observable
final class AppState {
    /// 当前学校，默认桂工。
    var school: SchoolConfig = gutSchool
    var isLoggedIn = false
    var studentId = ""
    var studentName = ""
    /// 密码只存内存，供自动重登用。
    var password = ""

    /// 当前学期：年（如 2026）+ 学期（"秋"/"春"）。
    var year: Int = 2026
    var semester: String = "秋"
    var currentWeek: Int = 1

    /// 课表（已按课程展开成单条上课记录）。
    var courses: [Course] = []
    var scheduleLoading = false
    var scheduleError: String?

    /// 登录状态。
    var loginLoading = false
    var loginError: String?

    /// 验证码（桂工每次都要；职师院按需）。图片数据 + 用户输入。
    var captchaImageData: Data?
    var captchaText = ""
    var showCaptcha = false

    init() {
        updateTermFromDate()
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

    /// 切学校：换配置、清登录态和验证码（Cookie 按 host 分桶，不用清）。
    func switchSchool(_ newSchool: SchoolConfig) {
        guard newSchool.id != school.id else { return }
        school = newSchool
        isLoggedIn = false
        studentId = ""
        password = ""
        studentName = ""
        courses = []
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
        guard !studentId.isEmpty, !password.isEmpty else {
            loginError = "请填写学号和密码"
            return
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
            isLoggedIn = true
            loginError = nil
            showCaptcha = false
            captchaText = ""
            await refreshSchedule()
        case .failure(let message):
            isLoggedIn = false
            loginError = message
            // 失败后验证码作废，重新取一张（桂工每次登录都要新图）。
            if school.id == .gut || showCaptcha {
                await fetchCaptcha()
            }
        case .captchaRequired:
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
        scheduleError = nil
        loginError = nil
        captchaImageData = nil
        captchaText = ""
        showCaptcha = false
        NetworkClient.shared.cookies.clearAll()
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
            if list.isEmpty { scheduleError = "本周没有课程" }
        } catch let error as ScheduleError {
            if case .sessionExpired = error {
                // 会话过期：自动重登一次，再拉一次课表。
                let outcome: LoginOutcome
                if school.id == .gut {
                    outcome = await GUTService.login(studentId: studentId, password: password, captcha: "")
                } else {
                    outcome = await GXVNUService.login(studentId: studentId, password: password, captcha: "")
                }
                if case .success = outcome {
                    do {
                        let list: [Course]
                        if school.id == .gut {
                            list = try await GUTService.fetchSchedule(year: year, semester: semester)
                        } else {
                            list = try await GXVNUService.fetchSchedule(year: year, semester: semester)
                            if let name = GXVNUService.lastStudentName, !name.isEmpty {
                                studentName = name
                            }
                        }
                        courses = list
                    } catch {
                        scheduleError = (error as? LocalizedError)?.errorDescription ?? "拉取课表失败"
                    }
                } else {
                    isLoggedIn = false
                    scheduleError = "登录已过期，请重新登录"
                }
            } else {
                scheduleError = error.errorDescription
            }
        } catch {
            scheduleError = (error as? LocalizedError)?.errorDescription ?? "拉取课表失败"
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
