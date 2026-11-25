import Foundation
import Security

// MARK: - 联网层：URLSession 封装，手动管理 Cookie，不自动跟随重定向
//
// 两校教务都不走系统 Cookie：NSURLSession 的自动 Cookie 必须关掉，
// App 自己管（按 host 分桶存，请求时手动拼 Cookie 头，回包时手动
// 解析 Set-Cookie）。登录成败要看 302 的 Location 头，所以重定向
// 也不能自动跟随——全部请求都只返回原始响应，由调用方判断。
//
// build 43（专家意见）：
// - Cookie 持久化到 UserDefaults：桂工每次登录都要输图形验证码，
//   Cookie 只在内存里的话，App 一重启就得重输验证码；持久化后
//   25 分钟有效期内重启 App，桂工也能直接免验证码刷课表/成绩。
// - 超时 40s → 15s（请求）/ 30s（资源），网络超时/闪断自动重试
//   最多 2 次（退避 0.8s、1.6s），只重试超时/断网/DNS 类错误。
// - Cookie 按 path 长度排序存入：同名 JSESSIONID 时，/jwglxt
//  （长路径）永远覆盖根路径 / 的同名 Cookie。

/// 不跟随重定向的 delegate：收到 3xx 直接把原始响应交给调用方。
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum NetworkError: Error, LocalizedError {
    case invalidURL
    case noResponse
    case timeout
    case noNetwork
    case httpStatus(Int)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "地址无效"
        case .noResponse: return "服务器没有响应"
        case .timeout: return "连接超时，请检查网络后重试"
        case .noNetwork: return "网络未连接"
        case .httpStatus(let code): return "服务器返回 \(code)"
        case .unknown(let msg): return msg
        }
    }
}

/// 手动 Cookie 桶：按 host 分桶，[host: [name: value]]。
/// 只发给教务服务器的 Cookie，不会发给别处。
/// 持久化到 UserDefaults（build 43），App 重启后会话还在有效期内就能复用。
final class CookieJar: @unchecked Sendable {
    private var store: [String: [String: String]] = [:]
    private let lock = NSLock()
    private let storageKey = "PersistedCookieJar_v1"
    private let keychainService = Bundle.main.bundleIdentifier ?? "GlutnnGxunuAssistant.CookieJar"
    
    init() {
        if let saved = loadFromKeychain() {
                                           store = saved
            } else if let saved = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [String: String]] {
            store = saved
            if saveToKeychain(saved) {
         UserDefaults.standard.removeObject(forKey: storageKey)
            }
        }
    }

    private func persistLocked() {
        saveToKeychain(store)
    }
    private func loadFromKeychain() -> [String: [String: String]]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: storageKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode([String: [String: String]].self, from: data)
    }

    @discardableResult
    private func saveToKeychain(_ cookies: [String: [String: String]]) -> Bool {
        guard let data = try? JSONEncoder().encode(cookies) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: storageKey
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
    }
    
    /// 该 host 的 Cookie 头（"a=1; b=2"），没有则返回 nil。
    func header(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let cookies = store[host], !cookies.isEmpty else { return nil }
        return cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// 从回包的 Set-Cookie 头里存 Cookie。
    /// 用 Foundation 的 HTTPCookie 解析（能正确处理 Expires 日期里的
    /// 逗号）。同名 Cookie 按 path 长度升序存入，长路径（/jwglxt、
    /// /academic）最后写入、优先生效；空值 / "delete" / "null" /
    /// 已过期的一律删掉，不存。
    func store(from response: HTTPURLResponse, for url: URL) {
        guard let host = url.host?.lowercased() else { return }
        var headerFields: [String: String] = [:]
        for (k, v) in response.allHeaderFields {
            if let ks = k as? String, let vs = v as? String {
                headerFields[ks] = vs
            }
        }
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        guard !parsed.isEmpty else { return }
        // 按 path 长度升序：具体子路径的同名 Cookie 最后写入、覆盖根路径的。
        let sorted = parsed.sorted { $0.path.count < $1.path.count }
        lock.lock()
        defer { lock.unlock() }
        var bucket = store[host] ?? [:]
        let now = Date()
        for cookie in sorted {
            if let expires = cookie.expiresDate, !cookie.isSessionOnly, expires <= now {
                bucket.removeValue(forKey: cookie.name)
            } else if cookie.value.isEmpty
                        || cookie.value.lowercased() == "delete"
                        || cookie.value.lowercased() == "null" {
                bucket.removeValue(forKey: cookie.name)
            } else {
                bucket[cookie.name] = cookie.value
            }
        }
        store[host] = bucket
        persistLocked()
    }

    /// 取某 host 的某个 Cookie 值（供登录流程判断会话是否被轮换）。
    func value(_ name: String, host: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return store[host.lowercased()]?[name]
    }

    /// 清掉某 host 的全部 Cookie（登录失败后清脏会话用）。
    func clear(host: String) {
        lock.lock()
        defer { lock.unlock() }
        store.removeValue(forKey: host.lowercased())
        persistLocked()
    }

    /// 清掉全部 Cookie。
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        store.removeAll()
        persistLocked()
    }
}

/// 联网客户端。超时 15 秒（请求）/ 30 秒（资源）；不自动存 Cookie、不自动跟随重定向。
/// 网络超时/闪断自动重试最多 2 次（退避 0.8s、1.6s）。
final class NetworkClient: @unchecked Sendable {
    static let shared = NetworkClient()
    /// 请求超时（build 43：40s → 15s，丢包时 40s 假死太久）。
    static let timeout: TimeInterval = 15
    static let resourceTimeout: TimeInterval = 30

    let cookies = CookieJar()

    private let session: URLSession
    private let delegate = NoRedirectDelegate()

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.timeout
        config.timeoutIntervalForResource = Self.resourceTimeout
        // 关掉系统自动 Cookie（手动管，见上）。
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        // 关掉系统缓存：教务数据每次都要最新。
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// GET。返回 (正文 Data, HTTP 响应)。不抛 302 等“错误”状态码——
    /// 调用方按状态码自己判断（登录成功就是 302）。
    func get(_ url: URL, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyCommonHeaders(&request, headers: headers)
        return try await perform(request)
    }

    /// POST，body 为表单编码后的 Data（调用方自己拼 body）。
    func post(_ url: URL, body: Data?, headers: [String: String] = [:], maxRetries: Int = 0) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        applyCommonHeaders(&request, headers: headers)
        return try await perform(request, maxRetries: maxRetries)
    }

    /// POST，body 为表单字典（按 application/x-www-form-urlencoded 编码）。
    func postForm(_ url: URL, form: [String: String], headers: [String: String] = [:], maxRetries: Int = 0) async throws -> (Data, HTTPURLResponse) {
        var allHeaders = headers
        allHeaders["Content-Type"] = "application/x-www-form-urlencoded"
        let formAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let bodyString = form
            .map { "\($0.key.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? $0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? $0.value)" }
            .joined(separator: "&")
        return try await post(url, body: bodyString.data(using: .utf8), headers: allHeaders, maxRetries: maxRetries)
    }

    // MARK: - 内部

    private func applyCommonHeaders(_ request: inout URLRequest, headers: [String: String]) {
        request.timeoutInterval = Self.timeout
        if let cookie = cookies.header(for: request.url!) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    /// 通用请求执行器：网络超时/闪断自动重试最多 2 次（退避 0.8s、1.6s）。
    /// 只重试超时、连接丢失、DNS 类错误；用户取消直接抛出；其他错误直接抛出。
    private func perform(_ baseRequest: URLRequest, maxRetries: Int = 2) async throws -> (Data, HTTPURLResponse) {
        var lastError: URLError?
        for attempt in 0...maxRetries {
            if attempt > 0 {
                let delayNs = UInt64(800_000_000 * attempt) // 0.8s、1.6s
                try await Task.sleep(nanoseconds: delayNs)
            }
            var request = baseRequest
            request.timeoutInterval = Self.timeout
            if let url = request.url, let cookieHeader = cookies.header(for: url) {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }

            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NetworkError.noResponse
                }
                if let url = request.url {
                    cookies.store(from: httpResponse, for: url)
                }
                return (data, httpResponse)
            } catch let urlError as URLError {
                lastError = urlError
                if urlError.code == .cancelled {
                    throw urlError
                }
                let retryable: Set<URLError.Code> = [
                    .timedOut, .networkConnectionLost, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed
                ]
                if !retryable.contains(urlError.code) || attempt == maxRetries {
                    throw mapURLError(urlError)
                }
                // 可重试：继续下一轮。
            } catch {
                throw NetworkError.unknown(error.localizedDescription)
            }
        }
        throw mapURLError(lastError)
    }

    private func mapURLError(_ error: URLError?) -> NetworkError {
        guard let error else { return .unknown("网络请求失败，请稍后重试") }
        switch error.code {
        case .timedOut:
            return .timeout
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return .noNetwork
        default:
            return .unknown(error.localizedDescription)
        }
    }
}
