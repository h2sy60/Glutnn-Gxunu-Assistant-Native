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
        guard let url = school.url("/academic/getCaptcha.do") else { return nil }
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
            let (_, response) = try await client.postForm(url, form: form)
            // 成功：302 跳到 /academic/index_new.jsp（Location 头）。
            // 302 不会自动跟随（NetworkClient 关了重定向），直接读头。
            let location = response.value(forHTTPHeaderField: "Location") ?? ""
            if location == "/academic/index_new.jsp" {
                AppLogger.shared.log("GUT login success")
                return .success
            }
            AppLogger.shared.log("GUT login failure, location=\(location)")
            return .failure("学号、密码或验证码错误")
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
            let (data, _) = try await client.get(url)
            let html = decodeGUTHTML(data) ?? ""
            let ok = !html.contains("请重新登录")
            AppLogger.shared.log("GUT isLoggedIn: \(ok)")
            return ok
        } catch {
            return false
        }
    }

    /// 桂工老正方返回 GBK 编码的 HTML（Flutter 版 getHtml 用 gbk.decode）。
    /// 先试 UTF-8（UTF-8 页面直接成功），失败再试 GB18030（GBK 的超集）。
    /// GBK 字节几乎不可能通过 UTF-8 校验，所以这个顺序对两种编码都对。
    static func decodeGUTHTML(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8), !s.isEmpty {
            return s
        }
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: gb18030))
    }

    // MARK: - 课表

    /// 拉课表（HTML 解析）。year 为日历年（如 2026），semester 为 "秋"/"春"。
    /// 会话失效时抛 ScheduleError.sessionExpired。
    static func fetchSchedule(year: Int, semester: String) async throws -> [Course] {
        guard await isLoggedIn() else { throw ScheduleError.sessionExpired }
        // 老正方参数：year = 日历年 - 1980，term 秋=3、春=1。
        let params = [
            "year": String(year - 1980),
            "term": semester == "秋" ? "3" : "1",
        ]
        guard let url = school.url("/academic/student/currcourse/currcourse.jsdo", query: params) else {
            throw ScheduleError.network("地址无效")
        }
        let data: Data
        do {
            (data, _) = try await client.get(url)
        } catch let error as NetworkError {
            throw ScheduleError.network(error.errorDescription ?? "网络错误")
        }
        guard let html = decodeGUTHTML(data), !html.isEmpty else {
            AppLogger.shared.log("GUT schedule: empty or undecodable response, bytes=\(data.count)")
            throw ScheduleError.parseError
        }
        AppLogger.shared.log("GUT schedule: bytes=\(data.count), decoded chars=\(html.count)")
        let courses = parseScheduleHTML(html)
        AppLogger.shared.log("GUT schedule: parsed \(courses.count) courses")
        return courses
    }

    // MARK: - 课表 HTML 解析

    /// 解析桂工课表页。外层每行 .infolist_common：td[2]=课程名、
    /// td[3]=老师；内嵌 table.none 的每行：周次区间、星期、节次区间、地点。
    /// 用正则提取（无内置 HTML 解析器）。结构以 Flutter 版为准。
    static func parseScheduleHTML(_ html: String) -> [Course] {
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
    static func fetchScores() async throws -> [CourseScore] {
        guard await isLoggedIn() else { throw ScheduleError.sessionExpired }
        let form = [
            "year": "",
            "term": "",
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
        do {
            (data, _) = try await client.postForm(url, form: form)
        } catch let error as NetworkError {
            throw ScheduleError.network(error.errorDescription ?? "网络错误")
        }
        guard let html = decodeGUTHTML(data), !html.isEmpty else {
            throw ScheduleError.parseError
        }
        if html.contains("提示信息") {
            throw ScheduleError.network("请重试")
        }
        let scores = parseScoresHTML(html)
        AppLogger.shared.log("GUT scores: parsed \(scores.count) items")
        return scores
    }

    /// 解析桂工成绩页：取 class=datalist 的表，跳过表头行。
    static func parseScoresHTML(_ html: String) -> [CourseScore] {
        var scores: [CourseScore] = []
        guard let tableRegex = try? NSRegularExpression(
            pattern: #"<table[^>]*datalist[^>]*>([\s\S]*?)</table>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]),
            let tableMatch = tableRegex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
            tableMatch.numberOfRanges >= 2,
            let tableRange = Range(tableMatch.range(at: 1), in: html) else { return [] }
        let tableHTML = String(html[tableRange])
        let rows = trRows(tableHTML)
        // 第 0 行是表头，从第 1 行开始。
        for rowHTML in rows.dropFirst() {
            let cells = tdTexts(rowHTML)
            guard cells.count >= 12 else { continue }
            var rawScore = cells[5]
            if cells[9].contains("免考") { rawScore = "合格" }
            let score = Double(levelToNumber(rawScore)) ?? 0
            scores.append(CourseScore(
                courseCode: cells[2],
                courseName: cells[3],
                teacher: cells[4],
                score: score,
                rawScore: rawScore,
                gradePoint: Double(cells[6]) ?? 0,
                credit: Double(cells[7]) ?? 0,
                courseCategory: cells[11]
            ))
        }
        return scores
    }
}
