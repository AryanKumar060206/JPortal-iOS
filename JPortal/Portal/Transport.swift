import Foundation

/// talks to the portal: headers it insists on, the {status, response} envelope,
/// retries for its flaky gateway and the clock skew dance.
final class Transport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let defaultBaseURL = "https://webportal.jiit.ac.in:6011/StudentPortalAPI"

    let baseURL: String
    let clock: PortalClock
    private let retryDelays: [UInt64]
    private var session: URLSession!

    struct Raw {
        let code: Int
        let body: Data
        let contentType: String?
    }

    init(baseURL: String = Transport.defaultBaseURL, clock: PortalClock = PortalClock(), retryDelaysMs: [UInt64] = [500, 1500]) {
        self.baseURL = baseURL
        self.clock = clock
        self.retryDelays = retryDelaysMs
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 120
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// posts to path (relative to baseURL, or absolute) and unwraps the envelope.
    /// encrypt sends the payload as the portal's aes blob instead of json.
    /// pass retry false for anything that writes.
    func post(_ path: String, token: String?, payload: JSON?, encrypt: Bool, retry: Bool = true) async throws -> JSON {
        try await retryTransient(retry) {
            try await self.retryOnFreshSkew {
                // the body is built per attempt, a retry needs it keyed to the corrected clock
                var body: String?
                if let payload {
                    let text = payload.text()
                    body = encrypt ? PortalCipher.encrypt(text, at: self.clock.now()) : text
                }
                return try await self.exchange(path, method: "POST", token: token, body: body)
            }
        }
    }

    func get(_ path: String, token: String?) async throws -> JSON {
        try await retryTransient(true) {
            try await self.retryOnFreshSkew { try await self.exchange(path, method: "GET", token: token, body: nil) }
        }
    }

    /// raw bytes for pdf endpoints, errors still come back as json envelopes
    func bytes(_ path: String, token: String?) async throws -> Data {
        try await retryTransient(true) {
            let raw = try await self.exchange(path, method: "GET", token: token, body: nil)
            if raw.body.isEmpty { throw PortalError.emptyResponse }
            if raw.contentType?.contains("json") == true {
                _ = try self.unwrap(raw)
                throw PortalError.malformed("expected a file, got json")
            }
            return raw.body
        }
    }

    private func retryTransient<T>(_ enabled: Bool, _ send: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await send()
            } catch let e as PortalError {
                if !enabled || attempt >= retryDelays.count || !e.transient { throw e }
                try await Task.sleep(nanoseconds: retryDelays[attempt] * 1_000_000)
                attempt += 1
            }
        }
    }

    /// a fresh process doesn't know the server clock yet. around midnight our
    /// dateseq and the server's disagree, and the portal answers with nothing.
    /// that empty answer still carries a Date header, so retry once with it.
    private func retryOnFreshSkew(_ send: () async throws -> Raw) async throws -> JSON {
        let before = dateSeq(clock.now())
        let raw = try await send()
        do {
            return try unwrap(raw)
        } catch PortalError.emptyResponse {
            if dateSeq(clock.now()) == before { throw PortalError.emptyResponse }
            return try unwrap(try await send())
        }
    }

    func exchange(_ path: String, method: String, token: String?, body: String?) async throws -> Raw {
        let full = path.hasPrefix("https://") ? path : baseURL + path
        guard let url = URL(string: full) else { throw PortalError.malformed("bad url") }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
        req.setValue(PortalCipher.localName(clock.now()), forHTTPHeaderField: "LocalName")
        if let body { req.httpBody = Data(body.utf8) }
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw PortalError.malformed("not http") }
            clock.observe(http.value(forHTTPHeaderField: "Date"))
            return Raw(code: http.statusCode, body: data, contentType: http.value(forHTTPHeaderField: "Content-Type"))
        } catch let e as PortalError {
            throw e
        } catch let e as URLError {
            switch e.code {
            case .cancelled: throw CancellationError()
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired, .secureConnectionFailed:
                throw PortalError.untrusted(e.localizedDescription)
            case .timedOut:
                throw PortalError.network(e.localizedDescription, timedOut: true)
            default:
                throw PortalError.network(e.localizedDescription, timedOut: false)
            }
        }
    }

    func unwrap(_ raw: Raw) throws -> JSON {
        switch raw.code {
        case 401: throw PortalError.sessionExpired
        case 403: throw PortalError.forbidden
        default: break
        }
        let text = String(data: raw.body, encoding: .utf8) ?? ""
        let shape = "\(raw.contentType ?? "no type"), \(raw.body.count) bytes"
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if raw.code >= 500 { throw PortalError.serverUnavailable(code: raw.code, shape: shape) }
            if raw.code >= 400 { throw PortalError.portal(errors: [], code: raw.code) }
            throw PortalError.emptyResponse
        }
        guard let root = (try? JSON(parsing: raw.body))?.object else {
            if raw.code >= 500 { throw PortalError.serverUnavailable(code: raw.code, shape: shape) }
            throw PortalError.malformed("not an envelope (http \(raw.code))")
        }
        let status = root["status"]?.object
        let state = status?["responseStatus"]?.string
        if state == "Success" && raw.code < 400 { return root["response"] ?? .null }

        if raw.code >= 500 && status == nil {
            throw PortalError.serverError(code: raw.code, shape: shape, error: root["error"]?.string, detail: root["message"]?.string)
        }
        let errors = (status?["errors"]?.array ?? []).compactMap(\.string)
        throw PortalError.portal(errors: errors, code: raw.code)
    }

    // never follow redirects, the portal only redirects when something's wrong
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
