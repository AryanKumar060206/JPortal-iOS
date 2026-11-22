import Foundation

struct PortalConfig: Codable, Hashable, Sendable {
    var googleClientId: String = ""
    var googleButtonShow: String = ""
    /// full url of the google token exchange, lives on a different port and api
    var loginUrl: String = PortalConfig.defaultLoginURL

    static let defaultLoginURL = "https://webportal.jiit.ac.in:6013/CLXSSOAPI/token/generate-token-google-signin"

    var googleEnabled: Bool { googleButtonShow == "Y" && !googleClientId.isEmpty }

    init(googleClientId: String = "", googleButtonShow: String = "", loginUrl: String = PortalConfig.defaultLoginURL) {
        self.googleClientId = googleClientId
        self.googleButtonShow = googleButtonShow
        self.loginUrl = loginUrl
    }

    init(json j: JSON) {
        googleClientId = j["loadGoogleClientId"].str
        googleButtonShow = j["loadGoogleButtonShow"].str
        loginUrl = j["URLapiBase"].string.flatMap { $0.isEmpty ? nil : $0 } ?? PortalConfig.defaultLoginURL
    }
}

/// what generate-token-google-signin hands back, trimmed to what we use.
/// the json keys match the android app's, so a session code from it works here too.
struct Session: Codable, Hashable, Sendable {
    var token: String
    /// the portal calls this Username, it's the display name and the refresh key
    var username: String
    var instituteId: String
    var instituteName: String = ""
    var clientId: String = ""
    var memberId: String = ""
    var userId: String = ""
    var enrollmentNo: String = ""
    var name: String = ""
    var memberType: String = ""
    /// `new Date().toString()` from the moment of login, refresh wants it back verbatim
    var tokenDate: String = ""
    var obtainedAt: Int64 = 0

    init(token: String, username: String, instituteId: String, instituteName: String = "", clientId: String = "",
         memberId: String = "", userId: String = "", enrollmentNo: String = "", name: String = "",
         memberType: String = "", tokenDate: String = "", obtainedAt: Int64 = 0) {
        self.token = token
        self.username = username
        self.instituteId = instituteId
        self.instituteName = instituteName
        self.clientId = clientId
        self.memberId = memberId
        self.userId = userId
        self.enrollmentNo = enrollmentNo
        self.name = name
        self.memberType = memberType
        self.tokenDate = tokenDate
        self.obtainedAt = obtainedAt
    }

    enum CodingKeys: String, CodingKey {
        case token, username, instituteId, instituteName, clientId, memberId, userId, enrollmentNo, name, memberType, tokenDate, obtainedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil ?? "" }
        token = s(.token)
        username = s(.username)
        instituteId = s(.instituteId)
        instituteName = s(.instituteName)
        clientId = s(.clientId)
        memberId = s(.memberId)
        userId = s(.userId)
        enrollmentNo = s(.enrollmentNo)
        name = s(.name)
        memberType = s(.memberType)
        tokenDate = s(.tokenDate)
        obtainedAt = ((try? c.decodeIfPresent(Int64.self, forKey: .obtainedAt)) ?? nil) ?? 0
    }

    /// whether two sessions are the same student, by enrollment number, else portal member id
    static func sameStudent(_ a: Session, _ b: Session) -> Bool {
        guard a.instituteId == b.instituteId else { return false }
        if !a.enrollmentNo.isEmpty && !b.enrollmentNo.isEmpty { return a.enrollmentNo == b.enrollmentNo }
        if !a.memberId.isEmpty && !b.memberId.isEmpty { return a.memberId == b.memberId }
        return false
    }

    /// exp claim of the jwt, in server time
    var expiresAt: Date? {
        guard let exp = jwtClaims(token)?["exp"].double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

struct Auth: Sendable {
    let transport: Transport

    func config() async throws -> PortalConfig {
        PortalConfig(json: try await transport.get("/token/getlogoClientWise", token: nil))
    }

    /// trades a google id token (the gsi `credential`) for a portal session
    func exchangeGoogleToken(_ credential: String, config: PortalConfig?) async throws -> Session {
        var url = config?.loginUrl
        if url == nil { url = (try? await self.config())?.loginUrl }
        let payload: JSON = ["googleToken": .string(credential), "modulename": "studentportal"]
        return try sessionFrom(try await transport.post(url ?? PortalConfig.defaultLoginURL, token: nil, payload: payload, encrypt: false))
    }

    /// builds a session from the login `response` object, e.g. one sniffed out of the portal page
    func sessionFrom(_ r: JSON) throws -> Session {
        let token = r["token"].str
        let institute = r["value"].str
        if token.isEmpty || institute.isEmpty { throw PortalError.malformed("login response without token") }
        let now = transport.clock.now()
        return Session(
            token: token,
            username: r["Username"].str,
            instituteId: institute,
            instituteName: r["label"].str,
            clientId: r["clientid"].str,
            memberId: r["memberid"].str,
            userId: r["userid"].str,
            enrollmentNo: r["enrollmentno"].str,
            name: r["name"].str,
            memberType: r["membertype"].str,
            tokenDate: Auth.jsDateString(now),
            obtainedAt: Int64(now.timeIntervalSince1970 * 1000)
        )
    }

    static func jsDateString(_ at: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = IST
        f.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0530 (India Standard Time)'"
        return f.string(from: at)
    }
}

/// base64url(session json), the last-resort way in
func decodeSessionCode(_ code: String) -> Session? {
    var b64 = code.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while b64.count % 4 != 0 { b64 += "=" }
    guard let data = Data(base64Encoded: b64), let s = try? JSONDecoder().decode(Session.self, from: data) else { return nil }
    return s.token.trimmingCharacters(in: .whitespaces).isEmpty || s.instituteId.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s
}

/// the other direction, so this phone can hand its session to another device
func encodeSessionCode(_ session: Session) -> String? {
    guard let data = try? JSONEncoder().encode(session) else { return nil }
    return data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
