import Foundation

// MARK: - 广西职业师范学院适配器（正方 V9.0 jwglxt）
//
// 登录：GET 登录页（csrftoken + JSESSIONID）→ GET 公钥（1024 位 RSA，
// 请求带 ?time=&_= 和 X-Requested-With）→ RSA 加密密码 →
// POST login_slogin.html?time=<毫秒>（body 与浏览器完全一致）。
// 正确密码返回 302（Shiro 会话固定 = 成功，会给新已认证 JSESSIONID；
// 用新会话再 GET 一次登录页，出现菜单页即成功），错误密码返回 200。
// 会话约 12 分钟过期（HTTP 200 + 登录页），自动重登。
// 全部请求用 URLSession，手动管理 Cookie。
//
// 关键编码（Flutter 版实测）：
// - 公钥 modulus/exponent 是 Base64，密文也是 Base64。
// - POST body 用 Uri.encodeComponent 风格编码（逗号 → %2C）；
//   csrftoken、language=zh_CN、ydType 为空、yhm、mm 出现两次。

enum GXVNUService {
    private static var school: SchoolConfig { gxvnuSchool }
    private static var client: NetworkClient { .shared }

    /// 课表响应里顺带取到的学生姓名（xsxx.XM），供 AppState 显示。
    nonisolated(unsafe) static var lastStudentName: String?

    /// 模拟 iPhone Safari 的 UA（Flutter 版实测：Dart 默认 UA 会被
    /// 正方当成非浏览器请求、轮换会话）。
    private static let safariUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.2 Mobile/15E148 Safari/604.1"

    private static var browserHeaders: [String: String] {
        [
            "User-Agent": safariUA,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh-Hans;q=0.9",
        ]
    }

    // MARK: - 工具

    /// V9.0 没有 401：业务响应是登录页 = 会话已过期。
    private static func isLoginPage(_ body: String) -> Bool {
        body.contains("login_slogin") || body.contains("用户登录") || body.contains("csrftoken")
    }

    private static func extract(_ html: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[r])
    }

    /// 服务器自己说的“要不要验证码”：登录页 dlsfbxyzm（1=要，0=不要），
    /// 或页面里真的渲染了验证码输入框。
    private static func captchaRequired(html: String) -> Bool {
        if let flag = extract(html, pattern: #"name="dlsfbxyzm"[^>]*value=\s*"?(\d)"#), flag == "1" {
            return true
        }
        return html.contains("name=\"yzm\"") || html.contains("id=\"yzm\"")
    }

    /// Uri.encodeComponent 风格：只保留不保留字符（A-Z a-z 0-9 - . _ ~），
    /// 其余全部百分编码（逗号 → %2C，Base64 的 +/= 也编）。
    private static func formEncode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// 登录页 #tips 里的失败原因。
    private static func tipsText(_ html: String) -> String {
        guard let idx = html.range(of: "id=\"tips\"") else { return "" }
        let after = html[idx.upperBound...]
        guard let start = after.firstIndex(of: ">") else { return "" }
        let from = after[after.index(after: start)...]
        var end = from.range(of: "</p>")?.lowerBound ?? from.range(of: "</")?.lowerBound ?? from.endIndex
        if end == from.endIndex, let e = from.range(of: "</")?.lowerBound { end = e }
        let snippet = String(from[..<end])
        return snippet.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clearSession() {
        client.cookies.clear(host: school.host)
    }

    /// 学年码：只传起始年份，如 2026（代表 2026-2027 学年）。
    private static func yearString(_ year: Int) -> String { "\(year)" }

    /// 学期码：第一学期=3、第二学期=12、第三学期=16。
    private static func semesterCode(_ semester: String) -> String {
        switch semester {
        case "秋": return "3"
        case "春": return "12"
        default: return "3"
        }
    }

    // MARK: - 验证码

    /// GET 验证码图（先拿登录页刷新会话，再取图）。
    static func fetchCaptchaImage() async -> Data? {
        _ = await getLoginPage()
        let time = Date().millisecondsSinceEpoch
        guard let url = school.url("/kaptcha", query: ["time": "\(time)"]) else { return nil }
        do {
            let (data, response) = try await client.get(url, headers: browserHeaders)
            guard response.statusCode == 200, !data.isEmpty else { return nil }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - 登录

    /// GET 登录页：拿 csrftoken / mmsfjm / JSESSIONID。
    private static func getLoginPage() async -> String {
        guard let url = school.url("/xtgl/login_slogin.html") else { return "" }
        do {
            let (data, _) = try await client.get(url, headers: browserHeaders)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    /// 登录。captcha 为用户输入的验证码（默认不要，按服务器要求）。
    static func login(studentId: String, password: String, captcha: String) async -> LoginOutcome {
        // 验证码和 csrftoken 都跟会话绑定，不要在两次尝试之间清会话。
        var loginHtml = await getLoginPage()
        var csrftoken = extract(loginHtml, pattern: #"name="csrftoken"[^>]*value="([^"]+)""#)
        var sessionRefreshed = false
        if csrftoken == nil || csrftoken!.isEmpty {
            // 登录页没给 csrftoken：旧会话已失效。清掉、重新拿一次全新登录页。
            clearSession()
            loginHtml = await getLoginPage()
            csrftoken = extract(loginHtml, pattern: #"name="csrftoken"[^>]*value="([^"]+)""#)
            guard let token = csrftoken, !token.isEmpty else { return .failure("登录页异常，请重试") }
            sessionRefreshed = true
        }
        if sessionRefreshed && !captcha.isEmpty {
            // 会话被换过：用户输的验证码是对着旧会话取的，已作废。
            return .captchaRequired
        }
        // mmsfjm=1 表示密码要加密；=0 则明文提交。
        var mmsfjm = extract(loginHtml, pattern: #"name="mmsfjm"[^>]*value="([^"]+)""#) ?? "1"

        // 拿 RSA 公钥并加密密码（1024 位，PKCS#1 v1.5）。
        // 浏览器拿公钥是 GET …/login_getPublicKey.html?time=<ms>&_=<ms>
        // 并且带 X-Requested-With；不带这些时服务器会轮换 JSESSIONID。
        let sessionBeforeKey = client.cookies.value("JSESSIONID", host: school.host)
        let now = Date().millisecondsSinceEpoch
        guard let keyURL = school.url("/xtgl/login_getPublicKey.html", query: ["time": "\(now)", "_": "\(now)"]) else {
            return .failure("地址无效")
        }
        let keyData: Data
        do {
            let (data, _) = try await client.get(keyURL, headers: [
                "X-Requested-With": "XMLHttpRequest",
                "User-Agent": safariUA,
                "Accept": "application/json, text/javascript, */*; q=0.01",
                "Accept-Language": "zh-CN,zh-Hans;q=0.9",
            ])
            keyData = data
        } catch let error as NetworkError {
            return .failure(error.errorDescription ?? "网络错误")
        } catch {
            return .failure("未知异常")
        }
        let sessionAfterKey = client.cookies.value("JSESSIONID", host: school.host)
        if sessionBeforeKey != sessionAfterKey {
            // 公钥请求轮换了会话：重新拿登录页取新 csrftoken。
            let retryHtml = await getLoginPage()
            csrftoken = extract(retryHtml, pattern: #"name="csrftoken"[^>]*value="([^"]+)""#)
            guard let token = csrftoken, !token.isEmpty else { return .failure("登录页异常，请重试") }
            mmsfjm = extract(retryHtml, pattern: #"name="mmsfjm"[^>]*value="([^"]+)""#) ?? "1"
            if !captcha.isEmpty { return .captchaRequired }
        }
        guard let keyJson = try? JSONSerialization.jsonObject(with: keyData) as? [String: Any],
              let modulus = keyJson["modulus"] as? String,
              let exponent = keyJson["exponent"] as? String else {
            return .failure("获取公钥失败")
        }
        let encryptedPassword = (mmsfjm == "0") ? password : (rsaEncryptPKCS1(plaintext: password, modulusBase64: modulus, exponentBase64: exponent) ?? "")
        guard !encryptedPassword.isEmpty else { return .failure("密码加密失败") }

        // 登录 POST：按浏览器原样发。字段只有 5 个：csrftoken（逗号编成
        // %2C）、language、ydType（空值，必须出现）、yhm、mm（发两次，
        // 同一个密文）。不要再加登录页上其它隐藏字段。
        let time = Date().millisecondsSinceEpoch
        guard let url = school.url("/xtgl/login_slogin.html", query: ["time": "\(time)"]) else {
            return .failure("地址无效")
        }
        var body = "csrftoken=\(formEncode(csrftoken!))"
        body += "&language=zh_CN"
        body += "&ydType="
        body += "&yhm=\(formEncode(studentId))"
        body += "&mm=\(formEncode(encryptedPassword))"
        body += "&mm=\(formEncode(encryptedPassword))"
        if !captcha.isEmpty { body += "&yzm=\(formEncode(captcha))" }

        // NetworkClient 会自动拼 Cookie 头。
        let responseData: Data
        let response: HTTPURLResponse
        do {
            (responseData, response) = try await client.post(
                url,
                body: body.data(using: .utf8),
                headers: [
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Referer": school.url("/xtgl/login_slogin.html")?.absoluteString ?? "",
                    "Origin": "https://\(school.host)",
                    "User-Agent": safariUA,
                    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                    "Accept-Language": "zh-CN,zh-Hans;q=0.9",
                    "Sec-Fetch-Site": "same-origin",
                    "Sec-Fetch-Mode": "navigate",
                    "Sec-Fetch-Dest": "document",
                ]
            )
        } catch let error as NetworkError {
            return .failure(error.errorDescription ?? "网络错误")
        } catch {
            return .failure("未知异常")
        }

        if response.statusCode == 301 || response.statusCode == 302 {
            let location = response.value(forHTTPHeaderField: "Location") ?? ""
            if location.contains("login_slogin") {
                // 302 回登录页：先别急着判失败。正确密码回 302、错密码回
                // 200，说明密码比对已通过，302 发生在登录成功之后：
                // Shiro 会话固定保护销毁旧会话、下发已认证的新 JSESSIONID。
                // 带着新 JSESSIONID 再 GET 一次登录页：回的不是登录页
                // （被 302 到菜单页）= 已登录成功；回的还是登录页 = 真失败。
                let probeHtml = await getLoginPage()
                if !isLoginPage(probeHtml) {
                    AppLogger.shared.log("GXVNU login success (302 probe)")
                    return .success
                }
                // 真失败：这次 POST 的会话已脏，清掉。
                clearSession()
                let freshHtml = await getLoginPage()
                if captchaRequired(html: freshHtml) {
                    AppLogger.shared.log("GXVNU login captchaRequired (302)")
                    return .captchaRequired
                }
                AppLogger.shared.log("GXVNU login failure: 学号或密码错误")
                return .failure("学号或密码错误")
            }
            return .success
        }
        if response.statusCode == 200 {
            let bodyText = String(data: responseData, encoding: .utf8) ?? ""
            let tips = tipsText(bodyText)
            if tips.contains("验证码") || bodyText.contains("name=\"yzm\"") {
                clearSession()
                AppLogger.shared.log("GXVNU login captchaRequired (200)")
                return .captchaRequired
            }
            clearSession()
            AppLogger.shared.log("GXVNU login failure (200): \(tips)")
            return .failure(tips.isEmpty ? "学号或密码错误" : tips)
        }
        clearSession()
        return .failure("登录失败（\(response.statusCode)）")
    }

    /// 会话是否还有效（用课表索引页做探针：返回登录页即失效）。
    static func isLoggedIn() async -> Bool {
        guard let gnmkdm = school.gnmkdm["课表"],
              let url = school.url("/kbcx/xskbcx_cxXskbcxIndex.html", query: ["gnmkdm": gnmkdm]) else {
            return false
        }
        do {
            let (data, response) = try await client.get(url, headers: browserHeaders)
            let body = String(data: data, encoding: .utf8) ?? ""
            return response.statusCode == 200 && !isLoginPage(body)
        } catch {
            return false
        }
    }

    // MARK: - 课表

    /// 拉课表（JSON）。year 为日历年（如 2026），semester 为 "秋"/"春"。
    /// 会话失效时抛 ScheduleError.sessionExpired。
    static func fetchSchedule(year: Int, semester: String) async throws -> [Course] {
        guard await isLoggedIn() else { throw ScheduleError.sessionExpired }
        let params = [
            "xnm": yearString(year),
            "xqm": semesterCode(semester),
            "kzlx": "ck",
        ]
        guard let gnmkdm = school.gnmkdm["课表"] else {
            throw ScheduleError.network("配置缺失")
        }
        // POST 目标：先试 SDK 端点，失败再 POST 索引页本身。
        let targets = [
            school.url("/kbcx/xskbcx_cxXsgrkb.html", query: ["gnmkdm": gnmkdm]),
            school.url("/kbcx/xskbcx_cxXsksxxIndex.html", query: ["gnmkdm": gnmkdm]),
        ].compactMap { $0 }

        var lastError: Error = ScheduleError.parseError
        for target in targets {
            do {
                let (data, _) = try await client.postForm(
                    target,
                    form: params,
                    headers: [
                        "X-Requested-With": "XMLHttpRequest",
                        "User-Agent": safariUA,
                        "Accept": "application/json, text/javascript, */*; q=0.01",
                    ]
                )
                let body = String(data: data, encoding: .utf8) ?? ""
                if isLoginPage(body) { throw ScheduleError.sessionExpired }
                guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let kbList = decoded["kbList"] as? [[String: Any]] else {
                    lastError = ScheduleError.parseError
                    continue
                }
                // 姓名藏在课表响应的 xsxx.XM 里。
                if let xsxx = decoded["xsxx"] as? [String: Any] {
                    let xm = (xsxx["XM"] as? String) ?? (xsxx["xm"] as? String) ?? (xsxx["XSXM"] as? String)
                    if let xm, !xm.trimmingCharacters(in: .whitespaces).isEmpty {
                        lastStudentName = xm.trimmingCharacters(in: .whitespaces)
                    }
                }
                AppLogger.shared.log("GXVNU schedule: kbList=\(kbList.count)")
                return parseKbList(kbList)
            } catch let error as ScheduleError {
                throw error
            } catch let error as NetworkError {
                lastError = ScheduleError.network(error.errorDescription ?? "网络错误")
            } catch {
                lastError = ScheduleError.parseError
            }
        }
        throw lastError
    }

    // MARK: - 成绩

    /// 查成绩（全部：近 5 学年 × 秋/春，逐页拉完合并，与 Flutter 版一致）。
    /// 单条字段名未验证（0 条记录），用多键容错取。
    static func fetchScores(year: Int) async throws -> [CourseScore] {
        guard await isLoggedIn() else { throw ScheduleError.sessionExpired }
        var all: [CourseScore] = []
        for y in (year - 4...year).reversed() {
            for semester in ["秋", "春"] {
                var page = 1
                var totalPage = 1
                repeat {
                    let (items, tp) = try await fetchScoresPage(year: y, semester: semester, page: page)
                    all.append(contentsOf: items)
                    totalPage = tp
                    page += 1
                } while page <= totalPage
            }
        }
        AppLogger.shared.log("GXVNU scores: total \(all.count) items")
        return all
    }

    /// 单页成绩。返回（本页成绩，总页数）。
    private static func fetchScoresPage(year: Int, semester: String, page: Int) async throws -> ([CourseScore], Int) {
        guard let gnmkdm = school.gnmkdm["成绩"],
              let url = school.url("/cjcx/cjcx_cxDgXscj.html", query: [
                "doType": "query",
                "gnmkdm": gnmkdm,
                "xnm": yearString(year),
                "xqm": semesterCode(semester),
                "queryModel.showCount": "15",
                "queryModel.currentPage": "\(page)",
                "_search": "false",
                "nd": "\(Date().millisecondsSinceEpoch)",
              ]) else {
            throw ScheduleError.network("地址无效")
        }
        let data: Data
        do {
            (data, _) = try await client.get(url, headers: browserHeaders)
        } catch let error as NetworkError {
            throw ScheduleError.network(error.errorDescription ?? "网络错误")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        if isLoginPage(body) { throw ScheduleError.sessionExpired }
        guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScheduleError.parseError
        }
        let items = decoded["items"] as? [[String: Any]] ?? []
        let totalPage = (decoded["totalPage"] as? NSNumber)?.intValue ?? 1
        if page == 1 {
            AppLogger.shared.log("GXVNU scores \(year) \(semester): items=\(items.count) totalPage=\(totalPage)")
            if let first = items.first {
                AppLogger.shared.log("GXVNU scores first item keys: \(first.keys.sorted().joined(separator: ","))")
            }
        }
        return (items.compactMap { scoreFromItem($0) }, totalPage)
    }

    /// 单条成绩（字段名未验证，多键容错）。
    private static func scoreFromItem(_ item: [String: Any]) -> CourseScore? {
        func pick(_ keys: [String]) -> String {
            for k in keys {
                if let s = item[k] as? String, !s.isEmpty { return s }
                if let n = item[k] as? NSNumber { return n.stringValue }
            }
            return ""
        }
        let courseName = pick(["kcmc"])
        guard !courseName.isEmpty else { return nil }
        let rawScore = pick(["cj", "cjmc", "cjz"])
        return CourseScore(
            courseCode: pick(["kch", "kch_id"]),
            courseName: courseName,
            teacher: pick(["jsxm", "xm", "jsmc"]),
            score: Double(levelToNumber(rawScore)) ?? 0,
            rawScore: rawScore,
            gradePoint: Double(pick(["jd"])) ?? 0,
            credit: Double(pick(["xf"])) ?? 0,
            courseCategory: pick(["kcxzmc", "kclbmc", "kcxz"])
        )
    }

    /// 解析 kbList：kcmc 课程名、xm 老师、cdmc 地点、xqj 星期（1-7）、
    /// jcor 节次区间 "a-b"、zcd 周次（含 第/周/(单)/(双)）、jxbmc 备注。
    static func parseKbList(_ kbList: [[String: Any]]) -> [Course] {
        var courses: [Course] = []
        for item in kbList {
            let name = (item["kcmc"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let teacher = (item["xm"] as? String) ?? ""
            let locationRaw = (item["cdmc"] as? String) ?? ""
            let location = (locationRaw.isEmpty || locationRaw.contains("&nbsp;")) ? "未知" : locationRaw
            // 星期：字段是 xqj（"1"=星期一），不是 xq。
            let weekdayString = (item["xqj"] as? String) ?? (item["xq"] as? String) ?? "\(item["xqj"] as? Int ?? 0)"
            guard let weekday = Int(weekdayString), (1...7).contains(weekday) else { continue }
            // 节次：jcor 是区间串 "1-3"；jc 是 "1-3节"。
            var startSection = 0
            var endSection = 0
            let jcor = (item["jcor"] as? String) ?? ""
            if jcor.contains("-") {
                let parts = jcor.split(separator: "-")
                startSection = Int(parts[0]) ?? 0
                endSection = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
            } else {
                startSection = Int(jcor) ?? 0
                endSection = startSection
            }
            if startSection == 0 || endSection == 0 {
                let jc = ((item["jc"] as? String) ?? "").replacingOccurrences(of: "节", with: "")
                if jc.contains("-") {
                    let parts = jc.split(separator: "-")
                    startSection = Int(parts[0]) ?? 0
                    endSection = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
                } else if jc.count >= 4 {
                    startSection = Int(jc.prefix(2)) ?? 0
                    endSection = Int(jc.suffix(2)) ?? 0
                }
            }
            guard startSection >= 1, endSection >= startSection else { continue }
            // 周次：zcd 带 "第/周/(单)/(双)"，先归一化再解析。
            let zcdRaw = (item["zcd"] as? String) ?? ""
            guard !zcdRaw.isEmpty else { continue }
            let zcd = zcdRaw
                .replacingOccurrences(of: "第", with: "")
                .replacingOccurrences(of: "周", with: "")
                .replacingOccurrences(of: "(单)", with: "单")
                .replacingOccurrences(of: "(双)", with: "双")
            let parsed = parseWeekList(zcd)
            let weeks = expandWeeks(parsed, rawInterval: zcd)
            guard !weeks.isEmpty else { continue }
            let extra = (item["jxbmc"] as? String) ?? ""
            courses.append(Course(
                name: name,
                teacher: teacher,
                location: location,
                weekday: weekday,
                startSection: startSection,
                endSection: endSection,
                weeks: weeks,
                extra: extra
            ))
        }
        return courses
    }
}

private extension Date {
    /// 毫秒时间戳（正方接口的 time 参数）。
    var millisecondsSinceEpoch: Int {
        Int(timeIntervalSince1970 * 1000)
    }
}
