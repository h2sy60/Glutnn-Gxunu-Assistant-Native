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
        // build 53：year/term 为筛选（nil = 全部）。桂工学期码暂按 1=第一学期、2=第二学期。
        let form = [
            "year": year.map(String.init) ?? "",
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
    /// 依次尝试两个端点，解析 datalist/infolist_tab 表，按表头列名
    /// （课程名称、考试时间、考场/地点、座位）提取每行。
    static func fetchExams() async throws -> [ExamItem] {
        let paths = [
            "/academic/manager/examstu/studentQueryAllExam.do",
            "/academic/student/exam/index.jsdo",
        ]
        var lastError: Error = ScheduleError.parseError
        for path in paths {
            guard let url = school.url(path) else { continue }
            do {
                let (data, response) = try await client.get(url)
                guard let html = decodeGUTHTML(data, response: response), !html.isEmpty else {
                    lastError = ScheduleError.parseError
                    continue
                }
                if isGUTSessionExpired(response: response, html: html) {
                    throw ScheduleError.sessionExpired
                }
                let exams = try parseExamsHTML(html)
                AppLogger.shared.log("GUT exams: parsed \(exams.count) items from \(path)")
                return exams
            } catch let error as ScheduleError {
                if error == .sessionExpired { throw error }
                lastError = error
            } catch let error as NetworkError {
                lastError = ScheduleError.network(error.errorDescription ?? "网络错误")
            } catch {
                lastError = ScheduleError.parseError
            }
        }
        throw lastError
    }

    /// 解析桂工考试页：找 datalist/infolist_tab 表，按表头定位列。
    static func parseExamsHTML(_ html: String) throws -> [ExamItem] {
        guard let tableRegex = try? NSRegularExpression(
            pattern: #"<table[^>]*(?:datalist|infolist_tab)[^>]*>([\s\S]*?)</table>"#,
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
        // 表头定位列下标（表头用 <th>，用 cellTexts 同时取 td/th）。
        let headerCells = cellTexts(rows[0])
        func colIndex(_ names: [String]) -> Int? {
            for (i, cell) in headerCells.enumerated() {
                for name in names {
                    if cell.contains(name) { return i }
                }
            }
            return nil
        }
        let nameIdx = colIndex(["课程名称", "课程名", "科目"])
        let timeIdx = colIndex(["考试时间", "时间"])
        let locIdx = colIndex(["考场", "地点", "教室"])
        let seatIdx = colIndex(["座位", "座号"])
        guard nameIdx != nil || timeIdx != nil else {
            throw ScheduleError.parseError
        }
        var exams: [ExamItem] = []
        for rowHTML in rows.dropFirst() {
            let cells = tdTexts(rowHTML)
            guard !cells.isEmpty else { continue }
            func cell(_ idx: Int?) -> String {
                guard let idx, idx < cells.count else { return "" }
                return cells[idx]
            }
            let name = cell(nameIdx)
            guard !name.isEmpty else { continue }
            exams.append(ExamItem(
                courseName: name,
                time: cell(timeIdx).isEmpty ? "时间待定" : cell(timeIdx),
                location: cell(locIdx).isEmpty ? "地点待定" : cell(locIdx),
                seatNumber: cell(seatIdx),
                examName: "",
                campus: ""
            ))
        }
        return exams
    }

    /// 提取一段 HTML 里所有 <td> 或 <th> 的文本（表头定位用）。
    private static func cellTexts(_ html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<(?:td|th)[^>]*>([\s\S]*?)</(?:td|th)>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, options: [], range: range).compactMap { match in
            guard match.numberOfRanges >= 2, let r = Range(match.range(at: 1), in: html) else { return nil }
            return stripTags(String(html[r])).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
