import XCTest
@testable import JPortal

/// an unsigned jwt with these claims, enough for code that only reads them
private func jwt(_ claims: [String: Any]) -> String {
    func b64(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let header = b64(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
    let body = b64(try! JSONSerialization.data(withJSONObject: claims))
    return "\(header).\(body).sig"
}

final class SilentAuthTests: XCTestCase {

    func testURLAsksGoogleForAnIdTokenWithoutUI() throws {
        let url = GoogleSilentAuth.url(clientId: "cid.apps", nonce: "n0nce", loginHint: "a@jiit.ac.in")
        let c = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(c.host, "accounts.google.com")
        XCTAssertEqual(q["client_id"], "cid.apps")
        // exactly the registered origin, google rejects it with a trailing slash
        XCTAssertEqual(q["redirect_uri"], "https://webportal.jiit.ac.in:6011")
        XCTAssertEqual(q["response_type"], "id_token")
        XCTAssertEqual(q["prompt"], "none")
        XCTAssertEqual(q["nonce"], "n0nce")
        XCTAssertEqual(q["login_hint"], "a@jiit.ac.in")
        XCTAssertTrue(q["scope"]?.contains("email") == true)
    }

    func testURLWithoutHint() {
        let url = GoogleSilentAuth.url(clientId: "cid", nonce: "n", loginHint: nil)
        XCTAssertFalse(url.absoluteString.contains("login_hint"))
    }

    func testNoncesDiffer() {
        XCTAssertNotEqual(GoogleSilentAuth.nonce(), GoogleSilentAuth.nonce())
        XCTAssertGreaterThan(GoogleSilentAuth.nonce().count, 16)
    }

    func testRedirectCarryingAToken() {
        let token = jwt(["nonce": "abc", "email": "a@jiit.ac.in", "exp": 1_900_000_000])
        let url = URL(string: "https://webportal.jiit.ac.in:6011/#id_token=\(token)&authuser=0&prompt=none")!
        XCTAssertEqual(GoogleSilentAuth.outcome(url, nonce: "abc"), .token(token))
    }

    func testTokenWithTheWrongNonceIsRefused() {
        let token = jwt(["nonce": "someone-elses"])
        let url = URL(string: "https://webportal.jiit.ac.in:6011#id_token=\(token)")!
        XCTAssertEqual(GoogleSilentAuth.outcome(url, nonce: "abc"), .refused("nonce_mismatch"))
    }

    // what google actually sent back for a cookieless request with prompt=none
    func testGoogleWantingThePerson() {
        let url = URL(string: "https://webportal.jiit.ac.in:6011/#error_subtype=access_denied&error=interaction_required")!
        XCTAssertEqual(GoogleSilentAuth.outcome(url, nonce: "abc"), .refused("interaction_required/access_denied"))
        let plain = URL(string: "https://webportal.jiit.ac.in:6011#error=login_required")!
        XCTAssertEqual(GoogleSilentAuth.outcome(plain, nonce: "abc"), .refused("login_required"))
    }

    func testOnlyTheRedirectCounts() {
        XCTAssertNil(GoogleSilentAuth.outcome(URL(string: "https://accounts.google.com/#id_token=x")!, nonce: "n"))
        XCTAssertNil(GoogleSilentAuth.outcome(URL(string: "https://webportal.jiit.ac.in:6011/studentportal/#id_token=x")!, nonce: "n"))
        XCTAssertNil(GoogleSilentAuth.outcome(URL(string: "https://webportal.jiit.ac.in/#id_token=x")!, nonce: "n"))
        XCTAssertNil(GoogleSilentAuth.outcome(URL(string: "http://webportal.jiit.ac.in:6011/#id_token=x")!, nonce: "n"))
        XCTAssertTrue(GoogleSilentAuth.isRedirect(URL(string: "https://webportal.jiit.ac.in:6011")!))
    }

    func testExpiryStillReadFromTheToken() {
        let s = Session(token: jwt(["exp": 1_900_000_000]), username: "u", instituteId: "I")
        XCTAssertEqual(s.expiresAt, Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertNil(Session(token: "opaque", username: "u", instituteId: "I").expiresAt)
    }

    func testRenewalMustBeTheSameStudent() {
        let me = Session(token: "a", username: "Me", instituteId: "JIIT", memberId: "M1", enrollmentNo: "9921")
        XCTAssertTrue(Session.sameStudent(me, Session(token: "b", username: "Me", instituteId: "JIIT", memberId: "M1", enrollmentNo: "9921")))
        XCTAssertFalse(Session.sameStudent(me, Session(token: "b", username: "Other", instituteId: "JIIT", memberId: "M2", enrollmentNo: "9922")))
        XCTAssertFalse(Session.sameStudent(me, Session(token: "b", username: "Me", instituteId: "OTHER", memberId: "M1", enrollmentNo: "9921")))
        // a session code without an enrollment number still matches by member id
        XCTAssertTrue(Session.sameStudent(Session(token: "a", username: "", instituteId: "JIIT", memberId: "M1"),
                                          Session(token: "b", username: "", instituteId: "JIIT", memberId: "M1", enrollmentNo: "9921")))
        // nothing to compare is never a match
        XCTAssertFalse(Session.sameStudent(Session(token: "a", username: "", instituteId: "JIIT"), Session(token: "b", username: "", instituteId: "JIIT")))
    }
}
