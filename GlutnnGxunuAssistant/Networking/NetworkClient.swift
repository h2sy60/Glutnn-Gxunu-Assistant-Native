import Foundation

// MARK: - 联网层：URLSession 封装，手动管理 Cookie，不自动跟随重定向
//
// 两校教务都不走系统 Cookie：NSURLSession 的自动 Cookie 必须关掉，
// App 自己管（按 host 分桶存，请求时手动拼 Cookie 头，回包时手动
// 解析 Set-Cookie）。登录成败要看 302 的 Location 头，所以重定向
// 也不能自动跟随——全部请求都只返回原始响应，由调用方判断。

/// 不跟随重定向的 delegate：收到 3xx 直接把原始响应交给调用方。
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
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
final class CookieJar {
    private var store: [String: [String: String]] = [:]
    private let lock = NSLock()

    /// 该 host 的 Cookie 头（"a=1; b=2"），没有则返回 nil。
    func header(for url: URL) -> String? {
        guard let host = url.host else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let cookies = store[host], !cookies.isEmpty else { return nil }
        return cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// 从回包的 Set-Cookie 头里存 Cookie。
    /// 用 Foundation 的 HTTPCookie 解析（能正确处理 Expires 日期里的
    /// 逗号）；Max-Age=0 按语义删掉该 Cookie，不存。
    func store(from response: HTTPURLResponse, for url: URL) {
        guard let host = url.host else { return }
        let fields = response.allHeaderFields as? [String: String] ?? [:]
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !parsed.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var bucket = store[host] ?? [:]
        for cookie in parsed {
            if cookie.isSessionOnly == false,
               let expires = cookie.expiresDate, expires < Date() {
                bucket.removeValue(forKey: cookie.name)
            } else {
                bucket[cookie.name] = cookie.value
            }
        }
        store[host] = bucket
    }

    /// 取某 host 的某个 Cookie 值（供登录流程判断会话是否被轮换）。
    func value(_ name: String, host: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return store[host]?[name]
    }

    /// 清掉某 host 的全部 Cookie（登录失败后清脏会话用）。
    func clear(host: String) {
        lock.lock()
        defer { lock.unlock() }
        store.removeValue(forKey: host)
    }

    /// 清掉全部 Cookie。
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        store.removeAll()
    }
}

/// 联网客户端。超时统一 40 秒；不自动存 Cookie、不自动跟随重定向。
final class NetworkClient {
    nonisolated(unsafe) static let shared = NetworkClient()
    static let timeout: TimeInterval = 40

    let cookies = CookieJar()

    private let session: URLSession
    private let delegate = NoRedirectDelegate()

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.timeout
        config.timeoutIntervalForResource = Self.timeout
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
    func post(_ url: URL, body: Data?, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        applyCommonHeaders(&request, headers: headers)
        return try await perform(request)
    }

    /// POST，body 为表单字典（按 application/x-www-form-urlencoded 编码）。
    func postForm(_ url: URL, form: [String: String], headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var allHeaders = headers
        allHeaders["Content-Type"] = "application/x-www-form-urlencoded"
        let bodyString = form
            .map { "\($0.key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        return try await post(url, body: bodyString.data(using: .utf8), headers: allHeaders)
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

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw NetworkError.timeout
            case .notConnectedToInternet, .networkConnectionLost: throw NetworkError.noNetwork
            default: throw NetworkError.unknown(error.localizedDescription)
            }
        } catch {
            throw NetworkError.unknown(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.noResponse
        }
        cookies.store(from: httpResponse, for: url)
        return (data, httpResponse)
    }
}
