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
    private static let stateLock = NSLock(); private nonisolated(unsafe) static var _lastStudentName: String?; static var lastStudentName: String? { get { stateLock.withLock { _lastStudentName } } set { stateLock.withLock { _lastStudentName = newValue } } }

    /// 取验证码图那次登录页的 csrftoken / mmsfjm / JSESSIONID。
    /// 验证码跟取图时的会话绑定；登录 POST 必须用同一个会话的 csrftoken，
    /// 否则服务端认不出验证码（用户明明输对了也会被判错）。
    /// build 66：有验证码时复用这三个值，不再先 GET 登录页——那次 GET
    /// 可能轮换 JSESSIONID，让验证码作废（点了“继续”却永远提示重新输入，
    /// Russell 2026-11-19 09:14 报的 bug）。取图时存，登录时复用。
    private nonisolated(unsafe) static var _captchaCsrfToken: String?; static var captchaCsrfToken: String? { get { stateLock.withLock { _captchaCsrfToken } } set { stateLock.withLock { _captchaCsrfToken = newValue } } }
    private nonisolated(unsafe) static var _captchaMmsfjm: String?; static var captchaMmsfjm: String? { get { stateLock.withLock { _captchaMmsfjm } } set { stateLock.withLock { _captchaMmsfjm = newValue } } }
    private nonisolated(unsafe) static var _captchaSessionId: String?; static var captchaSessionId: String? { get { stateLock.withLock { _captchaSessionId } } set { stateLock.withLock { _captchaSessionId = newValue } } }

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
        body.contains("login_slogin") || body.contains("用户登录") || body.contains("csrftoken") || body.contains("请重新登录") || body.contains("登录超时") || body.contains("会话已过期")
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

    /// 清掉该校 Cookie（登录失败后清脏会话用）。
    /// build 44：去掉 private——AppState.reloginGXVNU 需要从外部调它
    /// （build 43 误写成 private，CI 编译失败）。
    static func clearSession() {
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
    /// 顺手把这次登录页的 csrftoken / mmsfjm / JSESSIONID 存下来，
    /// 登录时有验证码就直接复用（build 66，见上面注释）。
    static func fetchCaptchaImage() async -> Data? {
        let loginHtml = await getLoginPage()
        captchaCsrfToken = extract(loginHtml, pattern: #"name="csrftoken"[^>]*value="([^"]+)""#)
        captchaMmsfjm = extract(loginHtml, pattern: #"name="mmsfjm"[^>]*value="([^"]+)""#)
        captchaSessionId = client.cookies.value("JSESSIONID", host: school.host)
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
        // build 66：用户已输验证码时，复用取图那次的 csrftoken / mmsfjm / 会话，
        // 不再先 GET 登录页——那次 GET 可能轮换 JSESSIONID，让验证码作废
        // （点了“继续”却永远提示重新输入，Russell 2026-11-19 09:14 报的 bug）。
        var loginHtml = ""
        var csrftoken: String?
        var sessionRefreshed = false
        var reusedCaptchaSession = false
        if !captcha.isEmpty,
           let savedToken = captchaCsrfToken, !savedToken.isEmpty,
           let savedSession = captchaSessionId,
           client.cookies.value("JSESSIONID", host: school.host) == savedSession {
            // 取图时的会话还在：直接用它的 csrftoken。
            csrftoken = savedToken
            reusedCaptchaSession = true
        } else {
            loginHtml = await getLoginPage()
            csrftoken = extract(loginHtml, pattern: #"name="csrftoken"[^>]*value="([^"]+)""#)
            if csrftoken == nil || csrftoken!.isEmpty {
                // 登录页没给 csrftoken：旧会话已失效。清掉、重新拿一次全新登录页。
                clearSession()
                loginHtml = await getLoginPage()
                csrftoken = extract(loginHtml, pattern: #"name="csrftoken"[^>]*value="([^"]+)""#)
                guard let token = csrftoken, !token.isEmpty else { return .failure("登录页异常，请重试") }
                sessionRefreshed = true
            }
        }
        if sessionRefreshed && !captcha.isEmpty {
            // 会话被换过：用户输的验证码是对着旧会话取的，已作废。
            AppLogger.shared.log("GXVNU login captcha discarded: session refreshed before POST")
            return .captchaRequired
        }
        // 静默登录（captcha 为空）时先读 dlsfbxyzm 标志：若当前 JSESSIONID
        // 已被服务端锁定必须输验证码，不要浪费一次 RSA+POST，直接清掉
        // 旧会话拿全新 JSESSIONID；全新会话仍要求验证码，说明全校强制
        // 开启或 IP 被风控，直接返回 .captchaRequired 弹框。
        // 用户已输验证码时（captcha 非空）绝不走这里——必须复用取图时的
        // 同一个 JSESSIONID，否则验证码作废（build 43，专家意见）。
        if captcha.isEmpty && captchaRequired(html: loginHtml) {
            clearSession()
            loginHtml = await getLoginPage()
            csrftoken = extract(loginHtml, pattern: #"name="csrftoken"[^>]*value="([^"]+)""#)
            guard let token = csrftoken, !token.isEmpty else { return .failure("登录页异常，请重试") }
            if captchaRequired(html: loginHtml) {
                return .captchaRequired
            }
        }
        // mmsfjm=1 表示密码要加密；=0 则明文提交。
        // 复用取图时会话的：用取图时存的 mmsfjm（没重新 GET 登录页）。
        // var：公钥轮换会话重拿登录页时要再赋值。
        var mmsfjm: String
        if reusedCaptchaSession, let savedMmsfjm = captchaMmsfjm, !savedMmsfjm.isEmpty {
            mmsfjm = savedMmsfjm
        } else {
            mmsfjm = extract(loginHtml, pattern: #"name="mmsfjm"[^>]*value="([^"]+)""#) ?? "1"
        }

        // 拿 RSA 公钥并加密密码（1024 位，PKCS#1 v1.5）。
        // 公钥存在服务端当前 HttpSession 里：若 GET 公钥轮换了 JSESSIONID，
        // 必须重拿登录页（新 csrftoken）再重取一次新会话的公钥，否则用旧
        // 会话的公钥加密、新会话的私钥解密必定乱码（build 43，专家意见）。
        // 最多重试一次，避免无限循环。
        var keyData: Data?
        var keyFetchOK = false
        for _ in 0..<2 {
            let sessionBeforeKey = client.cookies.value("JSESSIONID", host: school.host)
            let now = Date().millisecondsSinceEpoch
            guard let keyURL = school.url("/xtgl/login_getPublicKey.html", query: ["time": "\(now)", "_": "\(now)"]) else {
                return .failure("地址无效")
            }
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
            if sessionBeforeKey == sessionAfterKey {
                keyFetchOK = true
                break
            }
            // 轮换了会话：重拿登录页取新 csrftoken，下轮循环重取新会话的公钥。
            let retryHtml = await getLoginPage()
            loginHtml = retryHtml
            csrftoken = extract(retryHtml, pattern: #"name="csrftoken"[^>]*value="([^"]+)""#)
            guard let token = csrftoken, !token.isEmpty else { return .failure("登录页异常，请重试") }
            mmsfjm = extract(retryHtml, pattern: #"name="mmsfjm"[^>]*value="([^"]+)""#) ?? "1"
            if !captcha.isEmpty {
                // 公钥那次 GET 轮换了会话：用户输的验证码作废，换张图重输。
                AppLogger.shared.log("GXVNU login captcha discarded: public-key fetch rotated session")
                return .captchaRequired
            }
        }
        guard keyFetchOK, let keyData else { return .failure("获取公钥失败") }
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
            let location = (response.value(forHTTPHeaderField: "Location") ?? "").lowercased()
            // 账号在别处登录被挤下线 / 强制改密码：先排除，不走探针。
            if location.contains("kickout") {
                clearSession()
                return .failure("账号已在其他地方登录，请重新登录")
            }
            if location.contains("mmgl") || location.contains("xgmm") {
                clearSession()
                return .failure("请先在教务网站修改密码")
            }
            if location.contains("login_slogin") {
                // 302 回登录页：先别急着判失败。正确密码回 302、错密码回
                // 200，说明密码比对已通过，302 发生在登录成功之后：
                // Shiro 会话固定保护销毁旧会话、下发已认证的新 JSESSIONID。
                // 带着新 JSESSIONID 再 GET 一次登录页：回的不是登录页
                // （被 302 到菜单页）= 已登录成功；回的还是登录页 = 真失败。
                // 探针必须校验 HTTP 200 + 正文非空 + 不是登录页，否则一律
                // 不判成功（build 43：旧代码探针网络失败时空串
                // isLoginPage("")=false，会把失败误判成 .success）。
                var probeLoggedIn = false
                var probeNetworkError = false
                do {
                    guard let probeURL = school.url("/xtgl/login_slogin.html") else {
                        return .failure("地址无效")
                    }
                    let (probeData, probeResponse) = try await client.get(probeURL, headers: browserHeaders)
                    let probeHtml = String(data: probeData, encoding: .utf8) ?? ""
                    if probeResponse.statusCode == 200 && !probeHtml.isEmpty && !isLoginPage(probeHtml) {
                        probeLoggedIn = true
                    } else if probeResponse.statusCode == 301 || probeResponse.statusCode == 302 {
                        // build 45：已认证会话 GET 登录页会被 302 到菜单页，
                        // 这是登录成功，不是网络错误（build 43 只认 200，
                        // 302 空正文被误判成 probeNetworkError → “网络错误，
                        // 请重试”，Russell 2026-11-18 17:06 职师院登录报的就是它）。
                        // 302 回登录页 = 真失败；302 到别处 = 已登录。
                        let probeLocation = (probeResponse.value(forHTTPHeaderField: "Location") ?? "").lowercased()
                        if !probeLocation.isEmpty && !probeLocation.contains("login") {
                            probeLoggedIn = true
                        } else if probeLocation.contains("login") {
                            // 还是登录页 = 真失败，两个标志都 false。
                        } else {
                            probeNetworkError = true
                        }
                    } else if !isLoginPage(probeHtml) {
                        // 非 200/302 或空正文，且不是登录页 = 探针本身失败。
                        probeNetworkError = true
                    }
                    // 是登录页 = 真失败，两个标志都 false，继续走下面分支。
                } catch {
                    probeNetworkError = true
                }
                if probeLoggedIn {
                    AppLogger.shared.log("GXVNU login success (302 probe)")
                    return .success
                }
                if probeNetworkError {
                    // 探针本身网络失败：登录状态未知，不判成功、不清会话。
                    return .failure("网络错误，请重试")
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
            clearSession()
            AppLogger.shared.log("GXVNU login failure (200): \(tips)")
            // 只有 tips 明确说密码不对才报密码错；锁定/次数原样返回；
            // tips 为空但仍是登录页，报会话已刷新；连登录页都不是，报服务器异常。
            // （build 43：旧代码 tips 为空时 fallback 成“学号或密码错误”，
            //  会把网关报错/系统维护都误报成密码错。）
            if tips.contains("用户名或密码") || tips.contains("不正确") {
                return .failure("学号或密码错误")
            }
            if tips.contains("锁定") || tips.contains("次数") {
                return .failure(tips)
            }
            if tips.contains("验证码") || bodyText.contains("name=\"yzm\"") {
                clearSession()
                AppLogger.shared.log("GXVNU login captchaRequired (200)")
                return .captchaRequired
            }
            if !tips.isEmpty {
                return .failure(tips)
            }
            if isLoginPage(bodyText) {
                return .failure("会话已刷新，请重试")
            }
            return .failure("教务服务器响应异常，请稍后重试")
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
        // build 43：砍掉事前 isLoggedIn() 探针（专家意见）——探针把网络抖动
        // 当成会话过期。直接发业务请求：收到登录页 HTML 或 302 到登录页
        // 才抛 sessionExpired；网络错误直接抛 NetworkError（上层提示网络
        // 异常并保留离线缓存课表）。
        let params = [
            "xnm": yearString(year),
            "xqm": semesterCode(semester),
            "kzlx": "ck",
        ]
        guard let gnmkdm = school.gnmkdm["课表"] else {
            throw ScheduleError.network("配置缺失")
        }
        // POST 目标：主端点 + 备用端点（xskbcx_cxXsKb）。
        // build 43：旧备用端点 xskbcx_cxXsksxxIndex 是考试信息首页（HTML），
        // 根本不是课表接口，改成真正的备用课表端点。
        let targets = [
            school.url("/kbcx/xskbcx_cxXsgrkb.html", query: ["gnmkdm": gnmkdm]),
            school.url("/kbcx/xskbcx_cxXsKb.html", query: ["gnmkdm": gnmkdm]),
        ].compactMap { $0 }

        var lastError: Error = ScheduleError.parseError
        for target in targets {
            do {
                // build 83：会话过期会被误报成“课表解析失败”（2026-11-22 日志）：
                // 过期会话调课表接口，服务器返回 302 跳转（网络层不跟跳转，拿到
                // 0 字节空包）或无 kbList 的响应；旧代码只认登录页 HTML 才算
                // 会话过期，空包/无 kbList 都认不出来，当 JSON 解析失败报 parseError，
                // 而 refreshSchedule 只在 sessionExpired 时才重登+重试，于是
                // 一直刷一直失败。302/空包/无 kbList 不可能是一份有效课表，
                // 一律按 sessionExpired 抛，走重登+重试；正常课表（200 + 带 kbList
                // 的 JSON）完全不动。
                let (data, response) = try await client.postForm(
                    target,
                    form: params,
                    headers: [
                        "X-Requested-With": "XMLHttpRequest",
                        "User-Agent": safariUA,
                        "Accept": "application/json, text/javascript, */*; q=0.01",
                    ]
                )
                if (300..<400).contains(response.statusCode) { throw ScheduleError.sessionExpired }
                if data.isEmpty { throw ScheduleError.sessionExpired }
                let body = String(data: data, encoding: .utf8) ?? ""
                if isLoginPage(body) { throw ScheduleError.sessionExpired }
                guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    lastError = ScheduleError.parseError
                    continue
                }
                guard let kbList = decoded["kbList"] as? [[String: Any]] else {
                    lastError = ScheduleError.sessionExpired; continue
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

    /// 查成绩（build 43：必须用 POST！GET 必然返回 0 条）。
    /// xnm="" 且 xqm="" 时，正方一次 POST 直接返回大学四年全部成绩，
    /// 无需 5 年 × 2 学期循环（专家意见，whx1024/zfn_api12）。
    static func fetchScores(year: Int?, term: String? = nil) async throws -> [CourseScore] {
        // year/term 为筛选条件（nil = 全部）。xnm 传学年（如 2026），xqm 传学期码（第一学期 3、第二学期 12）。
        let gnmkdm = school.gnmkdm["成绩"] ?? "N305005"
        let endpoints = [
            "/cjcx/cjcx_cxDgXscj.html",
            "/cjcx/cjcx_cxXsgrcj.html",
        ]
        let nowMs = "\(Date().millisecondsSinceEpoch)"
        let formBody: [String: String] = [
            "xnm": year.map(String.init) ?? "",
            "xqm": term ?? "",
            "_search": "false",
            "nd": nowMs,
            "queryModel.showCount": "500",
            "queryModel.currentPage": "1",
            "queryModel.sortName": "",
            "queryModel.sortOrder": "asc",
            "time": "0",
        ]
        var lastError: Error = ScheduleError.parseError
        for path in endpoints {
            guard let url = school.url(path, query: ["doType": "query", "gnmkdm": gnmkdm]) else { continue }
            do {
                let (data, response) = try await client.postForm(url, form: formBody, headers: browserHeaders)
                if response.statusCode == 301 || response.statusCode == 302 {
                    let loc = (response.value(forHTTPHeaderField: "Location") ?? "").lowercased()
                    if loc.contains("login") { throw ScheduleError.sessionExpired }
                }
                guard response.statusCode == 200 else {
                    throw ScheduleError.network("成绩接口返回 HTTP \(response.statusCode)")
                }
                let text = String(data: data, encoding: .utf8) ?? ""
                if isLoginPage(text) { throw ScheduleError.sessionExpired }
                guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let items = decoded["items"] as? [[String: Any]] else {
                    lastError = ScheduleError.parseError
                    continue
                }
                // 成功拿到 items（即使为空数组也代表接口正常、真没成绩）。
                let scores = items.compactMap { scoreFromItem($0) }
                AppLogger.shared.log("GXVNU scores: total \(scores.count) items")
                return scores
            } catch let error as ScheduleError {
                // 会话过期立即抛，不试备用端点；其他错误记下、试下一个端点。
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

    /// 单条成绩（字段名按专家给的正方 V9 真实字段，多键容错）。
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
        let rawScore = pick(["cj", "bfzcj", "cjmc", "cjz"])
        return CourseScore(
            courseCode: pick(["kch", "kch_id"]),
            courseName: courseName,
            teacher: pick(["jsxm", "jsmc"]),
            score: Double(levelToNumber(rawScore)) ?? 0,
            rawScore: rawScore,
            gradePoint: Double(pick(["jd"])) ?? 0,
            credit: Double(pick(["xf"])) ?? 0,
            courseCategory: pick(["kcxzmc", "kclbmc", "ksxz", "kcxz"])
        )
    }

    // MARK: - 考试

    /// 查考试安排（build 43 新增，专家给的正方 V9 接口规范）。
    /// POST /kwgl/kscx_cxXsksxxIndex.html?doType=query&gnmkdm=N358105。
    static func fetchExams(year: Int, semester: String) async throws -> [ExamItem] {
        let gnmkdm = school.gnmkdm["考试"] ?? "N358105"
        guard let url = school.url("/kwgl/kscx_cxXsksxxIndex.html", query: [
            "doType": "query",
            "gnmkdm": gnmkdm,
        ]) else {
            throw ScheduleError.network("考试接口地址无效")
        }
        let xqm: String
        switch semester {
        case "秋": xqm = "3"
        case "春": xqm = "12"
        case "夏": xqm = "16"
        default: xqm = ""
        }
        let formBody: [String: String] = [
            "xnm": "\(year)",
            "xqm": xqm,
            "ksmcdmb_id": "",
            "kch": "",
            "kc": "",
            "ksrq": "",
            "kkbm_id": "",
            "_search": "false",
            "nd": "\(Date().millisecondsSinceEpoch)",
            "queryModel.showCount": "100",
            "queryModel.currentPage": "1",
            "queryModel.sortName": "",
            "queryModel.sortOrder": "asc",
            "time": "0",
        ]
        let (data, response) = try await client.postForm(url, form: formBody, headers: browserHeaders)
        if response.statusCode == 301 || response.statusCode == 302 {
            throw ScheduleError.sessionExpired
        }
        guard response.statusCode == 200 else {
            throw ScheduleError.network("考试接口返回 HTTP \(response.statusCode)")
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoginPage(text) { throw ScheduleError.sessionExpired }
        guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = decoded["items"] as? [[String: Any]] else {
            throw ScheduleError.customParseError("考试数据解析失败")
        }
        return items.compactMap { item in
            let name = (item["kcmc"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return nil }
            let time = (item["kssj"] as? String) ?? "时间待定"
            let location = (item["cdmc"] as? String) ?? "地点待定"
            let seat = (item["zwh"] as? String) ?? ""
            let examName = (item["ksmc"] as? String) ?? ""
            let campus = (item["xqmc"] as? String) ?? (item["cdxqmc"] as? String) ?? ""
            return ExamItem(
                courseName: name,
                time: time,
                location: location,
                seatNumber: seat,
                examName: examName,
                campus: campus
            )
        }
    }

    /// 周次解析（build 43，专家意见）：支持 "1-5周(单),6-12周(双),15周"
    /// 逐段独立判断单双周。输入已归一化（去 第/周，(单)→单，(双)→双）。
    static func parseWeeks(_ raw: String) -> [Int] {
        let segments = raw.components(separatedBy: CharacterSet(charactersIn: ",，、;；"))
        var result = Set<Int>()
        let numberRegex = try? NSRegularExpression(pattern: #"\d+"#)
        for seg in segments {
            let isOddOnly = seg.contains("单")
            let isEvenOnly = seg.contains("双")
            let nsRange = NSRange(seg.startIndex..<seg.endIndex, in: seg)
            let matches = numberRegex?.matches(in: seg, range: nsRange) ?? []
            let nums = matches.compactMap { match -> Int? in
                guard let r = Range(match.range, in: seg) else { return nil }
                return Int(seg[r])
            }
            if nums.count >= 2, nums[0] <= nums[1] {
                for w in nums[0]...nums[1] {
                    if isOddOnly && w % 2 == 0 { continue }
                    if isEvenOnly && w % 2 != 0 { continue }
                    result.insert(w)
                }
            } else if let single = nums.first {
                result.insert(single)
            }
        }
        return result.sorted()
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
            // 同天同课多时段：jcor 可能是 "1-2,5-6"，按逗号拆成多段，
            // 每段生成一条 Course（build 43：旧代码只取首尾会变成 1-6 节）。
            let jcorRaw = (item["jcor"] as? String) ?? ""
            var sectionRanges: [(Int, Int)] = []
            for seg in jcorRaw.components(separatedBy: CharacterSet(charactersIn: ",，、;；")) {
                let seg = seg.trimmingCharacters(in: .whitespaces)
                guard !seg.isEmpty else { continue }
                if seg.contains("-") {
                    let parts = seg.split(separator: "-")
                    if parts.count >= 2,
                       let s = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                       let e = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                       s <= e {
                        sectionRanges.append((s, e))
                    }
                } else if let single = Int(seg) {
                    sectionRanges.append((single, single))
                }
            }
            if sectionRanges.isEmpty {
                // fallback：jc 字段。
                let jc = ((item["jc"] as? String) ?? "").replacingOccurrences(of: "节", with: "")
                if jc.contains("-") {
                    let parts = jc.split(separator: "-")
                    if parts.count >= 2,
                       let s = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                       let e = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                       s <= e {
                        sectionRanges.append((s, e))
                    }
                } else if jc.count >= 4 {
                    if let s = Int(jc.prefix(2)), let e = Int(jc.suffix(2)) {
                        sectionRanges.append((s, e))
                    }
                } else if let single = Int(jc) {
                    sectionRanges.append((single, single))
                }
            }
            guard !sectionRanges.isEmpty else { continue }
            // 周次：zcd 带 "第/周/(单)/(双)"，先归一化再解析。
            // 多段混排单双周（"1-5周(单),6-12周(双),15周"）必须按逗号拆段、
            // 每段独立判断单/双（build 43，专家意见）。
            let zcdRaw = (item["zcd"] as? String) ?? ""
            guard !zcdRaw.isEmpty else { continue }
            let zcd = zcdRaw
                .replacingOccurrences(of: "第", with: "")
                .replacingOccurrences(of: "周", with: "")
                .replacingOccurrences(of: "(单)", with: "单")
                .replacingOccurrences(of: "(双)", with: "双")
            let weeks = parseWeeks(zcd)
            guard !weeks.isEmpty else { continue }
            let extra = (item["jxbmc"] as? String) ?? ""
            for (startSection, endSection) in sectionRanges {
                guard startSection >= 1, endSection >= startSection else { continue }
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
        }
        return courses
    }

    // MARK: - 更多功能（build 50，职师院专属；抓包 HAR 核验的正方 V9 接口）
    //
    // 待办事项、学生评教、已选课程/学分、教学执行计划、学籍预警、个人信息。
    // 全部只读查询（POST/GET），与成绩/考试同一套会话与请求风格。
    // 教学计划与学籍预警要学生的学院/年级/专业代码（jg_id/njdm_id/zyh_id），
    // 需先 resolveAcademicIDs()（读个人信息页 HTML + 专业下拉 JSON）拿到；
    // 拿不到就抛错，调用方显示错误，不崩。

    /// jqGrid 标准响应：{"items": [...], "totalCount": n, ...} → 取 items 数组。
    /// 返回 nil 表示不是 jqGrid JSON（可能是登录页或报错文本）。
    private static func jqGridItems(from data: Data) -> [[String: Any]]? {
        guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = decoded["items"] as? [[String: Any]] else {
            return nil
        }
        return items
    }

    /// 读 jqGrid 响应的通用 POST：会话过期抛 sessionExpired，非 200 抛 network，
    /// 登录页抛 sessionExpired；成功返回 items（空数组也算成功）。
    private static func postGrid(url: URL, form: [String: String]) async throws -> [[String: Any]] {
        let (data, response) = try await client.postForm(url, form: form, headers: browserHeaders)
        if response.statusCode == 301 || response.statusCode == 302 {
            let loc = (response.value(forHTTPHeaderField: "Location") ?? "").lowercased()
            if loc.contains("login") { throw ScheduleError.sessionExpired }
            throw ScheduleError.network("接口返回 HTTP \(response.statusCode)")
        }
        guard response.statusCode == 200 else {
            throw ScheduleError.network("接口返回 HTTP \(response.statusCode)")
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        if isLoginPage(text) { throw ScheduleError.sessionExpired }
        guard let items = jqGridItems(from: data) else {
            throw ScheduleError.parseError
        }
        return items
    }

    /// jqGrid 通用表单体（showCount 拉全量；sortName 留空走服务端默认排序，
    /// 避免逗号等多值排序的编码问题）。
    private static func gridForm(showCount: String = "100", sortName: String = "", sortOrder: String = "asc") -> [String: String] {
        [
            "_search": "false",
            "nd": "\(Date().millisecondsSinceEpoch)",
            "queryModel.showCount": showCount,
            "queryModel.currentPage": "1",
            "queryModel.sortName": sortName,
            "queryModel.sortOrder": sortOrder,
            "time": "0",
        ]
    }

    // MARK: 待办事项

    /// 待办事项（调课/补课提醒）：POST /xtgl/index_cxDbsy.html?doType=query。
    /// flag=1, sfyy=1（浏览器实测）；按创建时间倒序。未读 clzt=0。
    static func fetchTodos() async throws -> [GXVNUTodoItem] {
        guard let url = school.url("/xtgl/index_cxDbsy.html", query: ["doType": "query"]) else {
            throw ScheduleError.network("待办接口地址无效")
        }
        var form = gridForm(showCount: "100", sortName: "cjsj", sortOrder: "desc")
        form["flag"] = "1"
        form["sfyy"] = "1"
        let items = try await postGrid(url: url, form: form)
        return items.compactMap { item in
            let title = (item["xxbt"] as? String) ?? ""
            guard !title.isEmpty else { return nil }
            return GXVNUTodoItem(
                title: title,
                content: (item["xxnr"] as? String) ?? "",
                time: (item["cjsj"] as? String) ?? "",
                isRead: ((item["clzt"] as? String) ?? "0") != "0"
            )
        }
    }

    // MARK: 学生评教

    /// 学生评教列表：POST /xspjgl/xspj_cxXspjIndex.html?doType=query&gnmkdm=N401605。
    /// tjzt=-1 未评，其他为已评/已提交。
    static func fetchEvaluations() async throws -> [GXVNUEvaluationItem] {
        let gnmkdm = school.gnmkdm["评教"] ?? "N401605"
        guard let url = school.url("/xspjgl/xspj_cxXspjIndex.html", query: ["doType": "query", "gnmkdm": gnmkdm]) else {
            throw ScheduleError.network("评教接口地址无效")
        }
        let items = try await postGrid(url: url, form: gridForm(showCount: "100"))
        return items.compactMap { item in
            let courseName = (item["kcmc"] as? String) ?? ""
            guard !courseName.isEmpty else { return nil }
            let status = (item["tjzt"] as? String) ?? ""
            return GXVNUEvaluationItem(
                courseName: courseName,
                teacher: (item["jzgmc"] as? String) ?? "",
                className: (item["jxbmc"] as? String) ?? "",
                location: (item["jxdd"] as? String) ?? "",
                time: (item["sksj"] as? String) ?? "",
                statusText: (item["tjztmc"] as? String) ?? "",
                isPending: status == "-1"
            )
        }
    }

    /// 评教统计：POST /xspjgl/xspj_cxXspjqk.html?gnmkdm=N401605（无 body）。
    /// 返回 {wpgs: 未评数, bcgs: 本次个数, tjgs: 已提交数}。
    static func fetchEvaluationStats() async throws -> GXVNUEvaluationStats {
        let gnmkdm = school.gnmkdm["评教"] ?? "N401605"
        guard let url = school.url("/xspjgl/xspj_cxXspjqk.html", query: ["gnmkdm": gnmkdm]) else {
            throw ScheduleError.network("评教统计接口地址无效")
        }
        let (data, response) = try await client.postForm(url, form: [:], headers: browserHeaders)
        if response.statusCode == 301 || response.statusCode == 302 {
            throw ScheduleError.sessionExpired
        }
        guard response.statusCode == 200 else {
            throw ScheduleError.network("评教统计接口返回 HTTP \(response.statusCode)")
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        if isLoginPage(text) { throw ScheduleError.sessionExpired }
        guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScheduleError.parseError
        }
        func intVal(_ key: String) -> Int {
            if let n = decoded[key] as? NSNumber { return n.intValue }
            if let s = decoded[key] as? String { return Int(s) ?? 0 }
            return 0
        }
        return GXVNUEvaluationStats(
            pending: intVal("wpgs"),
            total: intVal("bcgs"),
            submitted: intVal("tjgs")
        )
    }

    // MARK: 已选课程 / 学分

    /// 已选课程（含学分）：POST /xsxxxggl/xsxxwh_cxXsxkxx.html?gnmkdm=N100801。
    /// xh_id 留空走会话（与成绩接口同款：不传 xh_id 也能拿到当前学生的数据）。
    static func fetchSelectedCourses() async throws -> [GXVNUSelectedCourse] {
        let gnmkdm = school.gnmkdm["选课信息"] ?? "N100801"
        guard let url = school.url("/xsxxxggl/xsxxwh_cxXsxkxx.html", query: ["gnmkdm": gnmkdm]) else {
            throw ScheduleError.network("选课信息接口地址无效")
        }
        var form = gridForm(showCount: "100")
        form["xh_id"] = ""
        form["xnm"] = ""
        form["xqm"] = ""
        let items = try await postGrid(url: url, form: form)
        return items.compactMap { item in
            let courseName = (item["kcmc"] as? String) ?? ""
            guard !courseName.isEmpty else { return nil }
            func num(_ key: String) -> Double {
                if let n = item[key] as? NSNumber { return n.doubleValue }
                if let s = item[key] as? String { return Double(s) ?? 0 }
                return 0
            }
            return GXVNUSelectedCourse(
                courseName: courseName,
                courseCode: (item["kch"] as? String) ?? "",
                teacher: (item["jsxm"] as? String) ?? "",
                className: (item["jxbmc"] as? String) ?? "",
                location: (item["jxdd"] as? String) ?? "",
                time: (item["sksj"] as? String) ?? "",
                credit: num("xf"),
                category: (item["kclbmc"] as? String) ?? "",
                term: ((item["xnmc"] as? String) ?? "") + ((item["xqmmc"] as? String) ?? "")
            )
        }
    }

    // MARK: 个人信息与学籍代码

    /// 个人信息（HTML 解析）：GET /xsxxxggl/xsgrxxwh_cxXsgrxx.html?gnmkdm=N100801。
    /// 页面是服务端直出的 HTML，含“年级 / 学院名称 / 专业名称（代码）/ 班级名称 /
    /// 学制 / 学籍状态”等文本。用标签正则提取。
    static func fetchProfile() async throws -> GXVNUProfile {
        let gnmkdm = school.gnmkdm["个人信息"] ?? "N100801"
        guard let url = school.url("/xsxxxggl/xsgrxxwh_cxXsgrxx.html", query: ["gnmkdm": gnmkdm]) else {
            throw ScheduleError.network("个人信息接口地址无效")
        }
        let (data, response) = try await client.get(url, headers: browserHeaders)
        if response.statusCode == 301 || response.statusCode == 302 {
            throw ScheduleError.sessionExpired
        }
        guard response.statusCode == 200 else {
            throw ScheduleError.network("个人信息接口返回 HTTP \(response.statusCode)")
        }
        let html = String(data: data, encoding: .utf8) ?? ""
        if isLoginPage(html) { throw ScheduleError.sessionExpired }
        // 去标签后按“标签：值”提取（值到下一个空白结束，均为单 token）。
        let plain = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
        func field(_ label: String) -> String {
            let pattern = label + "：\\s*([^\\s]+)"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)),
                  m.numberOfRanges >= 2,
                  let r = Range(m.range(at: 1), in: plain) else { return "" }
            let val = String(plain[r]); return val.contains("：") ? "" : val
        }
        let majorRaw = field("专业名称")  // 如“工程造价（普专本）(0509)”
        var majorCode = ""
        if let m = majorRaw.range(of: "\\((\\d+)\\)", options: .regularExpression) {
            majorCode = String(majorRaw[m]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        }
        let majorName = majorRaw.replacingOccurrences(of: "\\(\\d+\\)", with: "", options: .regularExpression)
        return GXVNUProfile(
            grade: field("年级"),
            college: field("学院名称"),
            major: majorName,
            majorCode: majorCode,
            className: field("班级名称"),
            duration: field("学制"),
            status: field("学籍状态"),
            enrollStatus: field("报到注册状态"),
            level: field("培养层次"),
            category: field("学生类别")
        )
    }

    /// 学生照片：先 GET 首页用户信息拿到照片 URL（含 xh_id），再 GET 照片 JPEG。
    /// GET /xtgl/index_cxYhxxIndex.html?gnmkdm=index 里有
    /// <img src="/jwglxt/xtgl/photo_cxXszp4.html?xh_id=...&zplx=rxqzp">。
    static func fetchProfilePhoto() async throws -> Data {
        guard let infoURL = school.url("/xtgl/index_cxYhxxIndex.html", query: ["gnmkdm": "index"]) else {
            throw ScheduleError.network("用户信息接口地址无效")
        }
        let (infoData, infoResponse) = try await client.get(infoURL, headers: browserHeaders)
        if infoResponse.statusCode == 301 || infoResponse.statusCode == 302 {
            throw ScheduleError.sessionExpired
        }
        guard infoResponse.statusCode == 200 else {
            throw ScheduleError.network("用户信息接口返回 HTTP \(infoResponse.statusCode)")
        }
        let infoHTML = String(data: infoData, encoding: .utf8) ?? ""
        if isLoginPage(infoHTML) { throw ScheduleError.sessionExpired }
        guard let xhId = extract(infoHTML, pattern: #"photo_cxXszp4\.html\?xh_id=(\d+)"#),
              let photoURL = school.url("/xtgl/photo_cxXszp4.html", query: ["xh_id": xhId, "zplx": "rxqzp"]) else {
            throw ScheduleError.parseError
        }
        let (photoData, photoResponse) = try await client.get(photoURL, headers: browserHeaders)
        guard photoResponse.statusCode == 200, !photoData.isEmpty else {
            throw ScheduleError.network("照片接口返回异常")
        }
        return photoData
    }

    /// 专业下拉（取学院/专业代码）：GET /xtgl/comm_cxZydmList.html。
    /// 返回 [{jg_id, jgmc, zyh_id, zyh, zymc, ...}]，按学院名/专业代码匹配。
    private static func fetchMajorList() async throws -> [[String: Any]] {
        guard let url = school.url("/xtgl/comm_cxZydmList.html", query: [:]) else {
            throw ScheduleError.network("专业列表接口地址无效")
        }
        let (data, response) = try await client.get(url, headers: browserHeaders)
        if response.statusCode == 301 || response.statusCode == 302 {
            throw ScheduleError.sessionExpired
        }
        guard response.statusCode == 200 else {
            throw ScheduleError.network("专业列表接口返回 HTTP \(response.statusCode)")
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        if isLoginPage(text) { throw ScheduleError.sessionExpired }
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ScheduleError.parseError
        }
        return list
    }

    /// 解析学生的学院/年级/专业代码（供教学计划与学籍预警用）：
    /// 个人信息页取 年级/学院名/专业代码 → 专业下拉按学院名取 jg_id、按专业代码取 zyh_id。
    /// 年级取不到即抛错；学院/专业代码取不到时留空，调用方按空结果处理。
    static func resolveAcademicIDs() async throws -> GXVNUAcademicIDs {
        let profile = try await fetchProfile()
        let majors = try await fetchMajorList()
        func str(_ item: [String: Any], _ key: String) -> String {
            (item[key] as? String) ?? ""
        }
        var jgId = ""
        var zyhId = ""
        for m in majors {
            if !profile.college.isEmpty && str(m, "jgmc") == profile.college && jgId.isEmpty {
                jgId = str(m, "jg_id")
            }
            if !profile.majorCode.isEmpty && str(m, "zyh") == profile.majorCode && zyhId.isEmpty {
                zyhId = str(m, "zyh_id")
            }
        }
        guard !profile.grade.isEmpty else {
            throw ScheduleError.parseError
        }
        return GXVNUAcademicIDs(
            jgId: jgId,
            njdmId: profile.grade,
            zyhId: zyhId,
            college: profile.college,
            major: profile.major,
            grade: profile.grade,
            className: profile.className
        )
    }

    // MARK: 教学执行计划

    /// 教学执行计划：POST /jxzxjhgl/jxzxjhck_cxJxzxjhckIndex.html?doType=query&gnmkdm=N153540。
    /// 按学院 + 年级过滤（jg_id/njdm_id 来自 resolveAcademicIDs）。
    static func fetchTeachingPlan(ids: GXVNUAcademicIDs) async throws -> [GXVNUTeachingPlan] {
        let gnmkdm = school.gnmkdm["教学计划"] ?? "N153540"
        guard let url = school.url("/jxzxjhgl/jxzxjhck_cxJxzxjhckIndex.html", query: ["doType": "query", "gnmkdm": gnmkdm]) else {
            throw ScheduleError.network("教学计划接口地址无效")
        }
        var form = gridForm(showCount: "100")
        form["jg_id"] = ids.jgId
        form["njdm_id"] = ids.njdmId
        form["dlbs"] = ""
        form["zyh_id"] = ""
        form["currentPage_cx"] = ""
        form["time"] = "1"
        let items = try await postGrid(url: url, form: form)
        return items.compactMap { item in
            let majorName = (item["zymc"] as? String) ?? ""
            guard !majorName.isEmpty else { return nil }
            func num(_ key: String) -> Int {
                if let n = item[key] as? NSNumber { return n.intValue }
                if let s = item[key] as? String { return Int(s) ?? 0 }
                return 0
            }
            return GXVNUTeachingPlan(
                majorName: majorName,
                gradeName: (item["njmc"] as? String) ?? "",
                campus: (item["xqmc"] as? String) ?? "",
                courseCount: num("kcs"),
                hours: num("jhrs"),
                totalCredits: (item["zdxf"] as? String) ?? "",
                category: (item["dlbs"] as? String) ?? "",
                planId: (item["jxzxjhxx_id"] as? String) ?? ""
            )
        }
    }

    // MARK: 学籍预警

    /// 学籍预警：POST /xjyj/xjyj_cxXjyjjdlb.html?gnmkdm=N105505。
    /// jg_id/njdm_id/zyh_id 来自 resolveAcademicIDs。返回每条预警的
    /// 风险课程列表（kcList，含 kcmc）与预警学分。
    static func fetchAcademicWarning(ids: GXVNUAcademicIDs) async throws -> [GXVNUWarning] {
        let gnmkdm = school.gnmkdm["学籍预警"] ?? "N105505"
        guard let url = school.url("/xjyj/xjyj_cxXjyjjdlb.html", query: ["gnmkdm": gnmkdm]) else {
            throw ScheduleError.network("学籍预警接口地址无效")
        }
        let form: [String: String] = [
            "jg_id": ids.jgId,
            "njdm_id": ids.njdmId,
            "zyh_id": ids.zyhId,
        ]
        let (data, response) = try await client.postForm(url, form: form, headers: browserHeaders)
        if response.statusCode == 301 || response.statusCode == 302 {
            throw ScheduleError.sessionExpired
        }
        guard response.statusCode == 200 else {
            throw ScheduleError.network("学籍预警接口返回 HTTP \(response.statusCode)")
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        if isLoginPage(text) { throw ScheduleError.sessionExpired }
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ScheduleError.parseError
        }
        return list.compactMap { item in
            let courses: [String] = ((item["kcList"] as? [[String: Any]]) ?? []).compactMap { kc in
                let name = (kc["kcmc"] as? String) ?? ""
                return name.isEmpty ? nil : name
            }
            guard !courses.isEmpty else { return nil }
            return GXVNUWarning(
                term: ((item["xnm"] as? String) ?? "") + " " + ((item["xqm"] as? String) ?? ""),
                courses: courses,
                warningCredits: (item["yqzdxf"] as? String) ?? ""
            )
        }
    }

// MARK: - 毕业进度（build 53）

/// 教学执行计划课程明细：POST /jxzxjhgl/jxzxjhkcxx_cxJxzxjhkcxxIndex.html?doType=query&gnmkdm=N153540。
/// body 需 jxzxjhxx_id（计划 ID，来自 fetchTeachingPlan 的 planId）。showCount 拉全量。
/// 返回全部计划课程（含 KCXZMC 课程性质、XF 学分、JYXDXNM/JYXDXQM 建议修读学年/学期）。
static func fetchPlanCourses(planId: String) async throws -> [GXVNUPlanCourse] {
    let gnmkdm = school.gnmkdm["教学计划"] ?? "N153540"
    guard let url = school.url("/jxzxjhgl/jxzxjhkcxx_cxJxzxjhkcxxIndex.html", query: ["doType": "query", "gnmkdm": gnmkdm]) else {
        throw ScheduleError.network("计划课程接口地址无效")
    }
    var form = gridForm(showCount: "100")
    form["jxzxjhxx_id"] = planId
    let items = try await postGrid(url: url, form: form)
    return items.compactMap { item in
        let name = (item["kcmc"] as? String) ?? ""
        guard !name.isEmpty else { return nil }
        func num(_ key: String) -> Double {
            if let n = item[key] as? NSNumber { return n.doubleValue }
            if let s = item[key] as? String { return Double(s) ?? 0 }
            return 0
        }
        return GXVNUPlanCourse(
            courseName: name,
            courseCode: (item["kch"] as? String) ?? "",
            category: (item["kcxzmc"] as? String) ?? "",
            credit: num("xf"),
            year: (item["jyxdxnm"] as? String) ?? "",
            term: (item["jyxdxqm"] as? String) ?? ""
        )
    }
}

// MARK: - 通知公告（build 53）

/// 通知公告列表：POST /xtgl/index_cxNews.html?localeKey=zh_CN&gnmkdm=index（无 body），返回 HTML。
/// 解析 list-group 里的 <a>：href 含 xwbh、title 属性为标题、块内日期 YYYY-MM-DD。
/// 三者按出现顺序一一对应（实测各 32 条）。
static func fetchNotifications() async throws -> [GXVNUNotification] {
    guard let url = school.url("/xtgl/index_cxNews.html", query: ["localeKey": "zh_CN", "gnmkdm": "index"]) else {
        throw ScheduleError.network("通知接口地址无效")
    }
    let (data, response) = try await client.postForm(url, form: [:], headers: browserHeaders)
    if response.statusCode == 301 || response.statusCode == 302 {
        throw ScheduleError.sessionExpired
    }
    guard response.statusCode == 200 else {
        throw ScheduleError.network("通知接口返回 HTTP \(response.statusCode)")
    }
    let html = String(data: data, encoding: .utf8) ?? ""
    if isLoginPage(html) { throw ScheduleError.sessionExpired }
    let linkPattern = #"<a[^>]*href="[^"]*xwbh=([A-F0-9]+)[^"]*"[^>]*title="([^"]*)"[^>]*>"#
    guard let linkRegex = try? NSRegularExpression(pattern: linkPattern, options: []),
          let dateRegex = try? NSRegularExpression(pattern: #"20\d\d-\d\d-\d\d"#, options: []) else {
        throw ScheduleError.parseError
    }
    let ns = html as NSString
    let linkMatches = linkRegex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
    let dateMatches = dateRegex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
    var result: [GXVNUNotification] = []
    for (index, m) in linkMatches.enumerated() {
        guard index < dateMatches.count else { break }
        let xwbh = ns.substring(with: m.range(at: 1))
        var title = ns.substring(with: m.range(at: 2))
        title = title.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { continue }
        let date = ns.substring(with: dateMatches[index].range)
        result.append(GXVNUNotification(xwbh: xwbh, title: title, date: date))
    }
    return result
}

/// 通知详情：GET /xtgl/xwck_ckXw.html?xwbh=<id>&doType=save，返回 HTML，去标签后取纯文本。
static func fetchNotificationDetail(xwbh: String) async throws -> String {
    guard let url = school.url("/xtgl/xwck_ckXw.html", query: ["xwbh": xwbh, "doType": "save"]) else {
        throw ScheduleError.network("通知详情地址无效")
    }
    let (data, response) = try await client.get(url, headers: browserHeaders)
    if response.statusCode == 301 || response.statusCode == 302 {
        throw ScheduleError.sessionExpired
    }
    guard response.statusCode == 200 else {
        throw ScheduleError.network("通知详情返回 HTTP \(response.statusCode)")
    }
    let html = String(data: data, encoding: .utf8) ?? ""
    if isLoginPage(html) { throw ScheduleError.sessionExpired }
    return stripHTML(html)
}

/// 去 HTML 标签，转纯文本（通知详情用）。
private static func stripHTML(_ html: String) -> String {
    var text = html
    if let re = try? NSRegularExpression(pattern: #"<(script|style)[\s\S]*?</\1>"#, options: .caseInsensitive) {
        text = re.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
    text = text.replacingOccurrences(of: "<br", with: "\n<br")
    text = text.replacingOccurrences(of: "</p>", with: "\n")
    text = text.replacingOccurrences(of: "</div>", with: "\n")
    if let re = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
        text = re.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
    text = text
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
    let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    return lines.joined(separator: "\n")
}

// MARK: - 培养方案 PDF（build 53）

/// 培养方案 PDF：先 GET 个人信息页取隐藏字段 pyfaxx_id，再 GET pyfaxxck_dyPyfaxx.html 下载 PDF。
/// 返回 PDF 原始数据（调用方用 PDFKit 展示）。
static func fetchTrainingPlanPDF() async throws -> Data {
    let gnmkdm = school.gnmkdm["个人信息"] ?? "N100801"
    guard let profileURL = school.url("/xsxxxggl/xsgrxxwh_cxXsgrxx.html", query: ["gnmkdm": gnmkdm]) else {
        throw ScheduleError.network("个人信息页地址无效")
    }
    let (profileData, profileResponse) = try await client.get(profileURL, headers: browserHeaders)
    if profileResponse.statusCode == 301 || profileResponse.statusCode == 302 {
        throw ScheduleError.sessionExpired
    }
    guard profileResponse.statusCode == 200 else {
        throw ScheduleError.network("个人信息页返回 HTTP \(profileResponse.statusCode)")
    }
    let profileHTML = String(data: profileData, encoding: .utf8) ?? ""
    if isLoginPage(profileHTML) { throw ScheduleError.sessionExpired }
    guard let idRegex = try? NSRegularExpression(pattern: #"id="pyfaxx_id"[^>]*value="([^"]+)""#, options: []),
          let m = idRegex.firstMatch(in: profileHTML, options: [], range: NSRange(profileHTML.startIndex..., in: profileHTML)),
          let range = Range(m.range(at: 1), in: profileHTML) else {
        throw ScheduleError.parseError
    }
    let pyfaId = String(profileHTML[range])
    guard let pdfURL = school.url("/pyfagl/pyfaxxck_dyPyfaxx.html", query: ["fromXh_id": "", "id": pyfaId, "gnmkdm": gnmkdm]) else {
        throw ScheduleError.network("培养方案地址无效")
    }
    let (pdfData, pdfResponse) = try await client.get(pdfURL, headers: browserHeaders)
    if pdfResponse.statusCode == 301 || pdfResponse.statusCode == 302 {
        throw ScheduleError.sessionExpired
    }
    guard pdfResponse.statusCode == 200 else {
        throw ScheduleError.network("培养方案返回 HTTP \(pdfResponse.statusCode)")
    }
    if let text = String(data: pdfData, encoding: .utf8), isLoginPage(text) {
        throw ScheduleError.sessionExpired
    }
    guard pdfData.count > 100 else {
        throw ScheduleError.parseError
    }
    return pdfData
}

// MARK: - 毕设（build 53）

/// 毕设已选题数：POST /xsbysjgl/xsxt_getYxts.html?gnmkdm=N532530，返回 "0" 这样的 JSON 字符串。
static func fetchThesisCount() async throws -> Int {
    let gnmkdm = school.gnmkdm["毕设"] ?? "N532530"
    guard let url = school.url("/xsbysjgl/xsxt_getYxts.html", query: ["gnmkdm": gnmkdm]) else {
        throw ScheduleError.network("毕设接口地址无效")
    }
    let (data, response) = try await client.postForm(url, form: [:], headers: browserHeaders)
    if response.statusCode == 301 || response.statusCode == 302 {
        throw ScheduleError.sessionExpired
    }
    guard response.statusCode == 200 else {
        throw ScheduleError.network("毕设接口返回 HTTP \(response.statusCode)")
    }
    let text = String(data: data, encoding: .utf8) ?? ""
    if isLoginPage(text) { throw ScheduleError.sessionExpired }
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    return Int(cleaned) ?? 0
}

/// 毕设选题列表：POST /xsbysjgl/xsxt_cxXsxtIndex.html?doType=query&gnmkdm=N532530，jqGrid。大一为空。
static func fetchThesisTopics() async throws -> [GXVNUThesisTopic] {
    let gnmkdm = school.gnmkdm["毕设"] ?? "N532530"
    guard let url = school.url("/xsbysjgl/xsxt_cxXsxtIndex.html", query: ["doType": "query", "gnmkdm": gnmkdm]) else {
        throw ScheduleError.network("毕设选题地址无效")
    }
    let items = try await postGrid(url: url, form: gridForm(showCount: "100"))
    return items.compactMap { item in
        func pick(_ keys: [String]) -> String {
            for k in keys {
                if let s = item[k] as? String, !s.isEmpty { return s }
                if let n = item[k] as? NSNumber { return n.stringValue }
            }
            return ""
        }
        let title = pick(["tm", "ktmc", "bt", "tmmc"])
        guard !title.isEmpty else { return nil }
        return GXVNUThesisTopic(
            title: title,
            teacher: pick(["jsmc", "zdjs", "jzgmc", "dsxm"]),
            status: pick(["zt", "ztmc", "shzt"])
        )
    }
}
}

// MARK: - 更多功能模型（build 50，职师院专属）

/// 待办事项（调课/补课提醒）。
struct GXVNUTodoItem: Identifiable {
    let id = UUID()
    var title: String
    var content: String
    var time: String
    var isRead: Bool
}

/// 学生评教条目。
struct GXVNUEvaluationItem: Identifiable {
    let id = UUID()
    var courseName: String
    var teacher: String
    var className: String
    var location: String
    var time: String
    var statusText: String
    var isPending: Bool
}

/// 评教统计。
struct GXVNUEvaluationStats {
    var pending: Int
    var total: Int
    var submitted: Int
}

/// 已选课程（含学分）。
struct GXVNUSelectedCourse: Identifiable {
    let id = UUID()
    var courseName: String
    var courseCode: String
    var teacher: String
    var className: String
    var location: String
    var time: String
    var credit: Double
    var category: String
    var term: String
}

/// 教学执行计划（一条 = 一个专业的培养方案概览）。
struct GXVNUTeachingPlan: Identifiable {
    let id = UUID()
    var majorName: String
    var gradeName: String
    var campus: String
    var courseCount: Int
    var hours: Int
    var totalCredits: String
    var category: String
    var planId: String = ""
}

/// 学籍预警（一条 = 一个学期的预警，含风险课程）。
struct GXVNUWarning: Identifiable {
    let id = UUID()
    var term: String
    var courses: [String]
    var warningCredits: String
}

/// 个人信息（个人信息页 HTML 解析）。
struct GXVNUProfile {
    var grade: String
    var college: String
    var major: String
    var majorCode: String
    var className: String
    var duration: String
    var status: String
    var enrollStatus: String
    var level: String
    var category: String
}

/// 学生的学院/年级/专业代码（教学计划与学籍预警的过滤参数）。
struct GXVNUAcademicIDs {
    var jgId: String
    var njdmId: String
    var zyhId: String
    var college: String
    var major: String
    var grade: String
    var className: String
}

// MARK: - build 53 模型

/// 教学执行计划课程明细（毕业进度用）。
struct GXVNUPlanCourse: Identifiable {
    let id = UUID()
    var courseName: String
    var courseCode: String
    var category: String
    var credit: Double
    var year: String
    var term: String
}

/// 通知公告条目。
struct GXVNUNotification: Identifiable {
    let id = UUID()
    var xwbh: String
    var title: String
    var date: String
}

/// 毕设选题条目。
struct GXVNUThesisTopic: Identifiable {
    let id = UUID()
    var title: String
    var teacher: String
    var status: String
}

private extension Date {
    /// 毫秒时间戳（正方接口的 time 参数）。
    var millisecondsSinceEpoch: Int {
        Int(timeIntervalSince1970 * 1000)
    }
}
