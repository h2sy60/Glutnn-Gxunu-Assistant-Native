import Foundation

// MARK: - 桂林理工大学适配器（老正方）
//
// 登录：GET 验证码图 → POST /academic/j_acegi_security_check
// （j_username=学号，j_password=双重 MD5，j_captcha=验证码）。
// 成功标志：回包 Location 头 == "/academic/index_new.jsp"。
// 课表：GET /academic/student/currcourse/currcourse.jsdo，HTML 解析。
// 会话校验：GET /academic/showPersonalInfo.do，正文不含“请重新登录”。

enum GUTService {
    private static var school: SchoolConfig { gutSchool }
    private static var client: NetworkClient { .shared }

    // MARK: - 验证码

    /// GET 验证码图。失败返回 nil。
    static func fetchCaptchaImage() async -> Data? {
        // build 43：加毫秒级防缓存参数（专家意见）——校园网透明缓存
        // 代理会对无参 getCaptcha.do 返回缓存图片，导致用户输旧图必失败。
        guard let url = school.url("/academic/getCaptcha.do", query: ["random": "\(Int(Date().timeIntervalSince1970 * 1000))"]) else { return nil }
        do {
            let (data, _) = try await client.get(url)
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    // MARK: - 登录

    /// 登录。captcha 为用户输入的验证码（桂工每次都要）。
    static func login(studentId: String, password: String, captcha: String) async -> LoginOutcome {
        guard let url = school.url("/academic/j_acegi_security_check") else {
            return .failure("地址无效")
        }
        do {
            let form = [
                "j_username": studentId,
                "j_password": gutPasswordHash(password),
                "j_captcha": captcha,
            ]
            let (data, response) = try await client.postForm(url, form: form)
            // 成功：302 跳到 /academic/index_new.jsp（Location 头）。
            // 302 不会自动跟随（NetworkClient 关了重定向），直接读头。
            // build 43：Location 用 contains 不用 ==（专家意见）——不同网关
            // 或首次无 Cookie 时，Tomcat 可能返回完整 URL 或带 ;jsessionid=
            // 后缀，== 会把真成功误判为失败。
            let location = response.value(forHTTPHeaderField: "Location") ?? ""
            if location.contains("/academic/index_new.jsp") {
                AppLogger.shared.log("GUT login success")
                return .success
            }
            // 失败：顺手 GET 一次错误页（302 跳回的登录页），读具体失败原因，
            // 精确区分“验证码错误”和“学号或密码错误”（build 43，专家意见）。
            var errorHtml = decodeGUTHTML(data) ?? ""
            if (response.statusCode == 301 || response.statusCode == 302),
               !location.isEmpty,
               let errURL = URL(string: location, relativeTo: url)?.absoluteURL {
                if let (errData, _) = try? await client.get(errURL) {
                    errorHtml = decodeGUTHTML(errData) ?? errorHtml
                }
            }
            AppLogger.shared.log("GUT login failure, location=\(location)")
            if errorHtml.contains("验证码") {
                return .failure("验证码错误，请重新输入")
            } else if errorHtml.contains("密码") || errorHtml.contains("用户") || location.contains("login_error") {
                return .failure("学号或密码错误")
            } else {
                return .failure("登录未通过，请重试")
            }
        } catch let error as NetworkError {
            return .failure(error.errorDescription ?? "网络错误")
        } catch {
            return .failure("未知异常")
        }
    }

    /// 会话是否还有效。
    static func isLoggedIn() async -> Bool {
        guard let url = school.url("/academic/showPersonalInfo.do") else { return false }
        do {
            let (data, response) = try await client.get(url)
            let html = decodeGUTHTML(data, response: response) ?? ""
            if isGUTSessionExpired(response: response, html: html) { return false }
            // 正向特征：个人信息页应含业务词（build 43：旧代码只查不含
            // “请重新登录”，502/空白页也会误判成有效）。
            let ok = html.contains("学号") || html.contains("姓名") || html.contains("个人信息")
            AppLogger.shared.log("GUT isLoggedIn: \(ok)")
            return ok
        } catch {
            return false
        }
    }

    /// 桂工会话过期统一检测（build 43，专家意见）：
    /// 302 到登录页/安全页、或正文含未登录特征、或含跳出框架脚本。
    static func isGUTSessionExpired(response: HTTPURLResponse, html: String) -> Bool {
        if response.statusCode == 301 || response.statusCode == 302 {
            let loc = (response.value(forHTTPHeaderField: "Location") ?? "").lowercased()
            if loc.contains("login") || loc.contains("index.jsp") || loc.contains("security") {
                return true
            }
        }
        return html.contains("请重新登录")
            || html.contains("您尚未登录")
            || html.contains("j_acegi_security_check")
            || html.contains("affairLogin.jsp")
            || html.contains("top.location.href")
    }

    /// 桂工老正方返回 GBK 编码的 HTML（Flutter 版 getHtml 用 gbk.decode）。
    /// build 43：优先 GB18030（GBK 的超集），除非响应明确声明 utf-8；
    /// 失败再 fallback 到另一种编码（专家意见：旧代码先试 UTF-8，
    /// 小概率 GBK 字节恰好能解成合法 UTF-8 乱码）。
    static func decodeGUTHTML(_ data: Data, response: HTTPURLResponse? = nil) -> String? {
        let gb18030Encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let encodingName = (response?.textEncodingName ?? "").lowercased()
        if encodingName.contains("utf-8") || encodingName.contains("utf8") {
            if let s = String(data: data, encoding: .utf8), !s.isEmpty { return s }
            return String(data: data, encoding: gb18030Encoding)
        }
        if let s = String(data: data, encoding: gb18030Encoding), !s.isEmpty { return s }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 课表

    /// 拉课表（HTML 解析）。year 为日历年（如 2026），semester 为 "秋"/"春"。
    /// 会话失效时抛 ScheduleError.sessionExpired。
    static func fetchSchedule(year: Int, semester: String) async throws -> [Course] {
        // build 43：砍掉事前 isLoggedIn() 探针（专家意见）——每次多发一倍
        // 请求且易误判。直接发业务请求，拿响应后检查是否会话过期。
        // 老正方参数：year = 日历年 - 1980，term 秋=3、春=1。
        // 注意：updateTermFromDate 已保证春季传学年起始年（2027 春 → 2026-1980=46）。
        let params = [
            "year": String(year - 1980),
            "term": semester == "秋" ? "3" : "1",
        ]
        guard let url = school.url("/academic/student/currcourse/currcourse.jsdo", query: params) else {
            throw ScheduleError.network("地址无效")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await client.get(url)
        } catch let error as NetworkError {
            throw ScheduleError.network(error.errorDescription ?? "网络错误")
        }
        guard let html = decodeGUTHTML(data, response: response), !html.isEmpty else {
            AppLogger.shared.log("GUT schedule: empty or undecodable response, bytes=\(data.count)")
            throw ScheduleError.parseError
        }
        // 会话过期检测：302 到登录页、或正文含未登录特征。
        if isGUTSessionExpired(response: response, html: html) {
            throw ScheduleError.sessionExpired
        }
        AppLogger.shared.log("GUT schedule: bytes=\(data.count), decoded chars=\(html.count)")
        let courses = try parseScheduleHTML(html)
        AppLogger.shared.log("GUT schedule: parsed \(courses.count) courses")
        return courses
    }

    // MARK: - 课表 HTML 解析

    /// 解析桂工课表页。外层每行 .infolist_common：td[2]=课程名、
    /// td[3]=老师；内嵌 table.none 的每行：周次区间、星期、节次区间、地点。
    /// 用正则提取（无内置 HTML 解析器）。结构以 Flutter 版为准。
    /// 页面特征白名单校验（build 43，专家意见）：会话过期、欠费、未完成
    /// 评教被拦截时，服务器返回的 200 HTML 里根本没有课表特征。
    /// 此时若返回 []，上层会误以为“本周没课”并把本地缓存清空！
    /// 必须含课表页表头特征才解析，否则抛 parseError。
    static func parseScheduleHTML(_ html: String) throws -> [Course] {
        let hasScheduleFeatures = html.contains("infolist_common")
            || html.contains("infolist_tab")
            || (html.contains("课程") && html.contains("周次"))
        guard hasScheduleFeatures else {
            AppLogger.shared.log("GUT parse: page lacks schedule features (expired or blocked?)")
            throw ScheduleError.parseError
        }
        var courses: [Course] = []
        // 外层行：从 <tr ... infolist_common ...> 到内嵌 </table> 后的 </tr>。
        // 分组 1=内嵌表之前的 td，2=内嵌表体，3=内嵌表之后的 td。
        let rowPattern = #"<tr[^>]*infolist_common[^>]*>([\s\S]*?)<table[^>]*class="[^"]*none[^"]*"[^>]*>([\s\S]*?)</table>([\s\S]*?)</tr>"#
        guard let rowRegex = try? NSRegularExpression(pattern: rowPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(html.startIndex..., in: html)
        let matches = rowRegex.matches(in: html, options: [], range: range)
        AppLogger.shared.log("GUT parse: infolist rows matched=\(matches.count)")

        for match in matches {
            guard match.numberOfRanges == 4,
                  let outerRange = Range(match.range(at: 1), in: html),
                  let innerRange = Range(match.range(at: 2), in: html) else { continue }
            let outerHTML = String(html[outerRange])
            let innerHTML = String(html[innerRange])

            // 外层 td 文本（去标签、去空白）。td[2]=课程名，td[3]=老师。
            let outerCells = tdTexts(outerHTML)
            guard outerCells.count > 3 else { continue }
            let name = outerCells[2]
            let teacher = outerCells[3]
            guard !name.isEmpty else { continue }

            // 内嵌表每行：4 个 td（周次区间、星期、节次区间、地点）。
            let innerRows = trRows(innerHTML)
            for rowHTML in innerRows {
                var cells = tdTexts(rowHTML)
                guard cells.count >= 4 else { continue }
                // Flutter 版：去掉 第/节/周 字符。
                cells = cells.map { $0.replacingOccurrences(of: "[第节周]", with: "", options: .regularExpression) }
                // 含 nbsp 的空行跳过。
                if (cells[1] + cells[2]).contains("nbsp") { continue }
                let weekInterval = cells[0]
                let weekText = cells[1]
                let lessonInterval = cells[2]
                var location = cells[3]
                if location.contains("nbsp") { location = "未知" }
                guard let weekday = weekdayNumber(from: weekText) else { continue }
                let lessons = lessonInterval.split(separator: "-").compactMap { Int($0) }
                guard lessons.count >= 2 else { continue }
                let startSection = lessons[0]
                let endSection = lessons[1]
                guard startSection >= 1, endSection >= startSection else { continue }

                let parsed = parseWeekList(weekInterval)
                let weeks = expandWeeks(parsed, rawInterval: weekInterval)
                guard !weeks.isEmpty else { continue }

                courses.append(Course(
                    name: name,
                    teacher: teacher,
                    location: location,
                    weekday: weekday,
                    startSection: startSection,
                    endSection: endSection,
                    weeks: weeks
                ))
            }
        }
        return courses
    }

    /// 提取一段 HTML 里所有 <td> 的去标签文本。
    private static func tdTexts(_ html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<td[^>]*>([\s\S]*?)</td>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, options: [], range: range).compactMap { match in
            guard match.numberOfRanges >= 2, let r = Range(match.range(at: 1), in: html) else { return nil }
            return stripTags(String(html[r])).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// 提取一段 HTML 里所有 <tr> 的内容。
    private static func trRows(_ html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<tr[^>]*>([\s\S]*?)</tr>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, options: [], range: range).compactMap { match in
            guard match.numberOfRanges >= 2, let r = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[r])
        }
    }

    /// 去掉 HTML 标签和 &nbsp;。
    private static func stripTags(_ s: String) -> String {
        let noTags = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return noTags.replacingOccurrences(of: "&nbsp;", with: "")
    }

    // MARK: - 成绩

    /// 查成绩（全部学年学期：year/term 留空）。列与 Flutter 版一致：
    /// td[2]=课程号、td[3]=课程名、td[4]=老师、td[5]=成绩、td[6]=绩点、
    /// td[7]=学分、td[9]=含“免考”时成绩记“合格”、td[11]=课程类别。
    static func fetchScores(year: Int? = nil, term: String? = nil) async throws -> [CourseScore] {
        // build 43：砍掉事前 isLoggedIn() 探针，直接发业务请求，拿响应后检查。
        // build 53：year/term 为筛选（nil = 全部）。
        // build 58：按旧项目（已验证）——year 传日历年-1980（如 2026→46），
        // term 秋=3、春=1（ScoreView.termCode 负责映射）。之前直接传日历年是错的。
        let form = [
            "year": year.map { String($0 - 1980) } ?? "",
            "term": term ?? "",
            "prop": "",
            "groupName": "",
            "para": "0",
            "sortColumn": "",
            "Submit": "查询",
        ]
        guard let url = school.url("/academic/manager/score/studentOwnScore.do") else {
            throw ScheduleError.network("地址无效")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await client.postForm(url, form: form)
        } catch let error as NetworkError {
            throw ScheduleError.network(error.errorDescription ?? "网络错误")
        }
        guard let html = decodeGUTHTML(data, response: response), !html.isEmpty else {
            throw ScheduleError.parseError
        }
        if isGUTSessionExpired(response: response, html: html) {
            throw ScheduleError.sessionExpired
        }
        if html.contains("提示信息") {
            throw ScheduleError.network("请重试")
        }
        let scores = try parseScoresHTML(html)
        AppLogger.shared.log("GUT scores: parsed \(scores.count) items")
        return scores
    }

    /// 解析桂工成绩页：取 class=datalist 的表，跳过表头行。
    /// build 43：先校验 datalist 存在性（不含且无“没有成绩”提示时抛
    /// parseError，而不是静默返回 []）；列数放宽到 8 列以上。
    static func parseScoresHTML(_ html: String) throws -> [CourseScore] {
        var scores: [CourseScore] = []
        guard html.contains("datalist") else {
            if html.contains("没有成绩") || html.contains("暂无成绩") {
                return []
            }
            throw ScheduleError.parseError
        }
        guard let tableRegex = try? NSRegularExpression(
            pattern: #"<table[^>]*datalist[^>]*>([\s\S]*?)</table>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]),
            let tableMatch = tableRegex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
            tableMatch.numberOfRanges >= 2,
            let tableRange = Range(tableMatch.range(at: 1), in: html) else { throw ScheduleError.parseError }
        let tableHTML = String(html[tableRange])
        let rows = trRows(tableHTML)
        // 第 0 行是表头，从第 1 行开始。
        for rowHTML in rows.dropFirst() {
            let cells = tdTexts(rowHTML)
            guard cells.count >= 8 else { continue }
            var rawScore = cells[5]
            if cells.count > 9 && cells[9].contains("免考") { rawScore = "合格" }
            let score = Double(levelToNumber(rawScore)) ?? 0
            scores.append(CourseScore(
                courseCode: cells[2],
                courseName: cells[3],
                teacher: cells[4],
                score: score,
                rawScore: rawScore,
                gradePoint: Double(cells[6]) ?? 0,
                credit: Double(cells[7]) ?? 0,
                courseCategory: cells.count > 11 ? cells[11] : ""
            ))
        }
        return scores
    }

    // MARK: - 考试

    /// 查考试安排（build 43 新增，专家给的老正方接口）。
    /// 查考试安排（build 58 按旧项目 getExams 重写，旧项目已验证）。
    /// POST /academic/manager/examstu/studentQueryAllExam.do（无 body）。
    /// 之前 build 43 的 GET + 按表头定位列与旧项目不符，改回旧项目写法。
    static func fetchExams() async throws -> [ExamItem] {
        guard let url = school.url("/academic/manager/examstu/studentQueryAllExam.do") else {
            throw ScheduleError.network("地址无效")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await client.post(url, body: nil)
        } catch let error as NetworkError {
            throw ScheduleError.network(error.errorDescription ?? "网络错误")
        }
        guard let html = decodeGUTHTML(data, response: response), !html.isEmpty else {
            throw ScheduleError.parseError
        }
        if isGUTSessionExpired(response: response, html: html) {
            throw ScheduleError.sessionExpired
        }
        let exams = try parseExamsHTML(html)
        AppLogger.shared.log("GUT exams: parsed \(exams.count) items")
        return exams
    }

    /// 解析桂工考试页（旧项目 getExams）：datalist 表，跳过表头，固定列号：
    /// [1]=课程名、[2]=考试时间、[3]=考场（取最后一段，如 "雁山 5-101" → "5-101"）。
    static func parseExamsHTML(_ html: String) throws -> [ExamItem] {
        guard let tableRegex = try? NSRegularExpression(
            pattern: #"<table[^>]*datalist[^>]*>([\s\S]*?)</table>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]),
            let tableMatch = tableRegex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
            tableMatch.numberOfRanges >= 2,
            let tableRange = Range(tableMatch.range(at: 1), in: html) else {
            if html.contains("没有考试") || html.contains("暂无考试") {
                return []
            }
            throw ScheduleError.parseError
        }
        let tableHTML = String(html[tableRange])
        let rows = trRows(tableHTML)
        guard !rows.isEmpty else { return [] }
        var exams: [ExamItem] = []
        for rowHTML in rows.dropFirst() {
            let cells = tdTexts(rowHTML)
            guard cells.count > 3 else { continue }
            let name = cells[1]
            guard !name.isEmpty else { continue }
            let timeRange = cells[2]
            let location = cells[3].split(separator: " ").last.map(String.init) ?? cells[3]
            exams.append(ExamItem(
                courseName: name,
                time: timeRange.isEmpty ? "时间待定" : timeRange,
                location: location.isEmpty ? "地点待定" : location,
                seatNumber: "",
                examName: "",
                campus: "",
                isPast: examIsPast(timeRange: timeRange)
            ))
        }
        return exams
    }

    /// 旧项目逻辑：考试时间形如 "2026-01-05 08:00--10:00"，取结束时间，过了即已考。
    private static func examIsPast(timeRange: String) -> Bool {
        let parts = timeRange.split(separator: " ")
        guard parts.count >= 2 else { return false }
        let datePart = String(parts[0])
        let times = parts[1].split(separator: "--")
        guard times.count >= 2 else { return false }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let endTime = formatter.date(from: "\(datePart) \(times[1])") else { return false }
        return Date() > endTime
    }

    // MARK: - 教学计划

    /// 查教学计划（build 58 新增，按旧项目 getTeachingPlan，旧项目已验证）。
    /// 两步：先 GET studentSelfSchedule.jsdo，取 table.broken_tab 最后一个链接里的
    /// studentId/classId；再 GET studentScheduleShowByTerm.do?z=z&studentId=&classId=。
    static func fetchTeachingPlan() async throws -> GUTTeachingPlan {
        guard let listURL = school.url("/academic/manager/studyschedule/studentSelfSchedule.jsdo") else {
            throw ScheduleError.network("地址无效")
        }
        let listData: Data
        let listResponse: HTTPURLResponse
        do {
            (listData, listResponse) = try await client.get(listURL)
        } catch let error as NetworkError {
            throw ScheduleError.network(error.errorDescription ?? "网络错误")
        }
        guard let listHTML = decodeGUTHTML(listData, response: listResponse), !listHTML.isEmpty else {
            throw ScheduleError.parseError
        }
        if isGUTSessionExpired(response: listResponse, html: listHTML) {
            throw ScheduleError.sessionExpired
        }
        guard let ids = teachingPlanIDs(from: listHTML) else {
            throw ScheduleError.parseError
        }
        guard let planURL = school.url(
            "/academic/manager/studyschedule/studentScheduleShowByTerm.do",
            query: ["z": "z", "studentId": ids.studentId, "classId": ids.classId]
        ) else {
            throw ScheduleError.network("地址无效")
        }
        let planData: Data
        let planResponse: HTTPURLResponse
        do {
            (planData, planResponse) = try await client.get(planURL)
        } catch let error as NetworkError {
            throw ScheduleError.network(error.errorDescription ?? "网络错误")
        }
        guard let planHTML = decodeGUTHTML(planData, response: planResponse), !planHTML.isEmpty else {
            throw ScheduleError.parseError
        }
        if isGUTSessionExpired(response: planResponse, html: planHTML) {
            throw ScheduleError.sessionExpired
        }
        let plan = try parseTeachingPlanHTML(planHTML)
        AppLogger.shared.log("GUT teaching plan: \(plan.semesters.count) semesters, \(plan.totalCourseCount) courses")
        return plan
    }

    /// 从 studentSelfSchedule 页取 studentId/classId：
    /// table.broken_tab 里最后一个 <a> 的 href 查询参数（旧项目做法）。
    private static func teachingPlanIDs(from html: String) -> (studentId: String, classId: String)? {
        guard let tableRegex = try? NSRegularExpression(
            pattern: #"<table[^>]*broken_tab[^>]*>([\s\S]*?)</table>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]),
            let tableMatch = tableRegex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
            tableMatch.numberOfRanges >= 2,
            let tableRange = Range(tableMatch.range(at: 1), in: html) else { return nil }
        let tableHTML = String(html[tableRange])
        guard let hrefRegex = try? NSRegularExpression(
            pattern: #"href="([^"]+)""#,
            options: [.caseInsensitive]) else { return nil }
        let matches = hrefRegex.matches(in: tableHTML, options: [], range: NSRange(tableHTML.startIndex..., in: tableHTML))
        guard let last = matches.last, last.numberOfRanges >= 2,
              let hrefRange = Range(last.range(at: 1), in: tableHTML) else { return nil }
        let href = String(tableHTML[hrefRange])
        guard let queryStart = href.firstIndex(of: "?") else { return nil }
        let query = String(href[href.index(after: queryStart)...])
        var studentId: String?
        var classId: String?
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            if kv[0] == "studentId" { studentId = String(kv[1]) }
            if kv[0] == "classId" { classId = String(kv[1]) }
        }
        guard let studentId, let classId, !studentId.isEmpty, !classId.isEmpty else { return nil }
        return (studentId, classId)
    }

    /// 解析教学计划页（旧项目 getTeachingPlan 的 next 部分）。
    static func parseTeachingPlanHTML(_ html: String) throws -> GUTTeachingPlan {
        // 通过/未通过/未知计数：img.no_output 的图片名。
        let failCount = countOccurrences(html, "course_failed.png") + countOccurrences(html, "course_failed_reelect.png")
        let passCount = countOccurrences(html, "course_pass.png") + countOccurrences(html, "course_pass_reelect.png")
        let unknownCount = countOccurrences(html, "course_unknown_pass.png")
        // 院系/专业/年级/层次：取 datalist 表里“恰好 4 格”的最后一行
        // （旧项目取 table.datalist tr:last-child 的前 4 格；课程行是 6 格，不会误取）。
        var department = "", major = "", educationalLevel = ""
        var grade = 0
        if let tableRegex = try? NSRegularExpression(
            pattern: #"<table[^>]*datalist[^>]*>([\s\S]*?)</table>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let range = NSRange(html.startIndex..., in: html)
            for tableMatch in tableRegex.matches(in: html, options: [], range: range) {
                guard tableMatch.numberOfRanges >= 2,
                      let tableRange = Range(tableMatch.range(at: 1), in: html) else { continue }
                let tableHTML = String(html[tableRange])
                guard let lastRow = trRows(tableHTML).last else { continue }
                let cells = tdTexts(lastRow)
                guard cells.count == 4 else { continue }
                department = cells[0]
                major = cells[1]
                grade = Int(cells[2].filter { $0.isNumber }) ?? 0
                educationalLevel = cells[3]
                break
            }
        }
        // 课程：table.datalist.output_ctx 的行；单格含“学年”即新学期。
        var semesters: [[GUTPlanCourse]] = []
        var totalCourseCount = 0, totalExamCount = 0, totalMajorCourseCount = 0
        if let tableRegex = try? NSRegularExpression(
            pattern: #"<table[^>]*datalist[^>]*output_ctx[^>]*>([\s\S]*?)</table>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]),
            let tableMatch = tableRegex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
            tableMatch.numberOfRanges >= 2,
            let tableRange = Range(tableMatch.range(at: 1), in: html) {
            let tableHTML = String(html[tableRange])
            for rowHTML in trRows(tableHTML) {
                let cells = tdTexts(rowHTML)
                if cells.count == 1, cells[0].contains("学年") {
                    semesters.append([])
                    continue
                }
                guard cells.count > 5 else { continue }
                totalCourseCount += 1
                if cells[2].contains("考试") { totalExamCount += 1 }
                if cells[5].contains("专业") { totalMajorCourseCount += 1 }
                if semesters.isEmpty { semesters.append([]) }
                semesters[semesters.count - 1].append(GUTPlanCourse(
                    code: cells[0], name: cells[1], assessmentType: cells[2],
                    credit: cells[3], hours: cells[4].replacingOccurrences(of: ".0", with: ""),
                    category: cells[5]
                ))
            }
        }
        guard !semesters.isEmpty else { throw ScheduleError.parseError }
        // 学制 = 学期数 / 2 向上取整（旧项目：(semesterCount / 2).ceil()）。
        let schoolingLength = (semesters.count + 1) / 2
        return GUTTeachingPlan(
            department: department, major: major, grade: grade,
            educationalLevel: educationalLevel, schoolingLength: schoolingLength,
            semesters: semesters, passCount: passCount, failCount: failCount,
            unknownCount: unknownCount, totalCourseCount: totalCourseCount,
            totalExamCount: totalExamCount, totalMajorCourseCount: totalMajorCourseCount
        )
    }

    /// 统计一段文本里某个子串出现次数。
    private static func countOccurrences(_ text: String, _ needle: String) -> Int {
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }

    // MARK: - 空教室

    /// 取教学楼下拉选项（build 58 新增，按旧项目 getFreeClassrooms 日模式，旧项目已验证）。
    /// POST 空教室日查询（默认参数），解析 #buildingid 的 option（跳过“请选择”）。
    static func fetchClassroomBuildings() async throws -> [GUTClassroomBuilding] {
        let form = [
            "aid": "1",
            "buildingid": "-1",
            "room": "-1",
            "whichweek": "-1",
            "week": "-1",
            "Submit": "确 定",
        ]
        guard let url = school.url("/academic/teacher/teachresource/roomschedulequery.jsdo") else {
            throw ScheduleError.network("地址无效")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await client.postForm(url, form: form)
        } catch let error as NetworkError {
            throw ScheduleError.network(error.errorDescription ?? "网络错误")
        }
        guard let html = decodeGUTHTML(data, response: response), !html.isEmpty else {
            throw ScheduleError.parseError
        }
        if isGUTSessionExpired(response: response, html: html) {
            throw ScheduleError.sessionExpired
        }
        guard let selectRegex = try? NSRegularExpression(
            pattern: #"<select[^>]*id="buildingid"[^>]*>([\s\S]*?)</select>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]),
            let selectMatch = selectRegex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
            selectMatch.numberOfRanges >= 2,
            let selectRange = Range(selectMatch.range(at: 1), in: html) else {
            throw ScheduleError.parseError
        }
        let selectHTML = String(html[selectRange])
        guard let optionRegex = try? NSRegularExpression(
            pattern: #"<option[^>]*value="([^"]*)"[^>]*>([^<]*)</option>"#,
            options: [.caseInsensitive]) else { return [] }
        let range = NSRange(selectHTML.startIndex..., in: selectHTML)
        var buildings: [GUTClassroomBuilding] = []
        for match in optionRegex.matches(in: selectHTML, options: [], range: range) {
            guard match.numberOfRanges >= 3,
                  let idRange = Range(match.range(at: 1), in: selectHTML),
                  let nameRange = Range(match.range(at: 2), in: selectHTML) else { continue }
            let id = String(selectHTML[idRange])
            let name = String(selectHTML[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if id == "-1" || name.isEmpty { continue }
            buildings.append(GUTClassroomBuilding(buildingId: id, name: name))
        }
        return buildings
    }

    /// 按教学楼/周次/星期查空教室（旧项目 getFreeClassrooms 周模式）。
    static func fetchFreeClassrooms(building: String, week: String, dayOfWeek: String) async throws -> [GUTClassroom] {
        let form = [
            "aid": "1",
            "buildingid": building,
            "room": "-1",
            "whichweek": week,
            "week": dayOfWeek,
            "Submit": "确 定",
        ]
        guard let url = school.url("/academic/teacher/teachresource/roomschedule_week.jsdo") else {
            throw ScheduleError.network("地址无效")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await client.postForm(url, form: form)
        } catch let error as NetworkError {
            throw ScheduleError.network(error.errorDescription ?? "网络错误")
        }
        guard let html = decodeGUTHTML(data, response: response), !html.isEmpty else {
            throw ScheduleError.parseError
        }
        if isGUTSessionExpired(response: response, html: html) {
            throw ScheduleError.sessionExpired
        }
        let rooms = try parseFreeClassroomsHTML(html)
        AppLogger.shared.log("GUT free classrooms: parsed \(rooms.count) rooms")
        return rooms
    }

    /// 解析空教室周模式页（旧项目 getFreeClassrooms 周模式）：
    /// 每行 tr.infolist_common，[0]=教室号、[1]=座位数、[3]=考试座位数、[5]=类型；
    /// 嵌套表第二行 11 格，含 &nbsp; 即该节空闲。
    static func parseFreeClassroomsHTML(_ html: String) throws -> [GUTClassroom] {
        guard let rowRegex = try? NSRegularExpression(
            pattern: #"<tr[^>]*infolist_common[^>]*>([\s\S]*?</table>[\s\S]*?)</tr>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var rooms: [GUTClassroom] = []
        for match in rowRegex.matches(in: html, options: [], range: range) {
            guard match.numberOfRanges >= 2,
                  let rowRange = Range(match.range(at: 1), in: html) else { continue }
            let rowHTML = String(html[rowRange])
            // 嵌套表单独解析占用；行里去掉嵌套表后再取外层格子。
            let nestedTable = firstMatch(in: rowHTML, pattern: #"<table[\s\S]*?</table>"#) ?? ""
            let rowWithoutTable = nestedTable.isEmpty ? rowHTML : rowHTML.replacingOccurrences(of: nestedTable, with: "")
            let cells = tdTexts(rowWithoutTable)
            guard cells.count > 5 else { continue }
            let roomNumber = cells[0]
            guard !roomNumber.isEmpty else { continue }
            let occupancy = parseClassroomOccupancy(nestedTable)
            let freeCount = occupancy.filter { $0 }.count
            rooms.append(GUTClassroom(
                roomNumber: roomNumber,
                seatCount: Int(cells[1]) ?? 0,
                examSeatCount: Int(cells[3]) ?? 0,
                type: cells[5],
                occupancy: occupancy,
                isAllDayFree: freeCount == 11
            ))
        }
        return rooms
    }

    /// 嵌套表第二行 11 格：含 &nbsp; 即该节空闲（旧项目 isFree 判断）。
    private static func parseClassroomOccupancy(_ tableHTML: String) -> [Bool] {
        guard !tableHTML.isEmpty else { return [] }
        let rows = trRows(tableHTML)
        guard rows.count >= 2 else { return [] }
        guard let tdRegex = try? NSRegularExpression(
            pattern: #"<td[^>]*>([\s\S]*?)</td>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let rowHTML = rows[1]
        let range = NSRange(rowHTML.startIndex..., in: rowHTML)
        return tdRegex.matches(in: rowHTML, options: [], range: range).compactMap { match in
            guard match.numberOfRanges >= 2,
                  let r = Range(match.range(at: 1), in: rowHTML) else { return nil }
            return String(rowHTML[r]).contains("&nbsp;")
        }
    }

    /// 取一段 HTML 里第一个匹配的整段（用于嵌套表）。
    private static func firstMatch(in html: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges >= 1,
              let r = Range(match.range(at: 0), in: html) else { return nil }
        return String(html[r])
    }
}
