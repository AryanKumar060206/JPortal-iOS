import Foundation
import Observation
import Security

/// the portal token, sealed in the keychain. this-device-only, so it never
/// leaves the phone through a backup or a restore to another device.
struct SessionStore {
    private let service = "jportal.session"
    private let account = "portal"
    /// the google account the session came from, so silent re-auth asks for that one
    private let hintAccount = "google-hint"

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private func write(_ data: Data, _ account: String) {
        let attrs: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query(account) as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = query(account)
            add.merge(attrs) { _, b in b }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func load() -> Session? {
        guard let data = read(account) else { return nil }
        guard let s = try? JSONDecoder().decode(Session.self, from: data) else {
            SecItemDelete(query(account) as CFDictionary)
            return nil
        }
        return s
    }

    func save(_ session: Session) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        write(data, account)
    }

    func loadHint() -> String? {
        read(hintAccount).flatMap { String(data: $0, encoding: .utf8) }
    }

    func saveHint(_ email: String) {
        write(Data(email.utf8), hintAccount)
    }

    func clearHint() {
        SecItemDelete(query(hintAccount) as CFDictionary)
    }

    func clear() {
        SecItemDelete(query(account) as CFDictionary)
        clearHint()
    }
}

/// one place that knows whether we have a usable token. tokens live 2h and
/// refresh is unreliable, so an expired session asks the ui for a silent google
/// re-auth (hidden web view, see GoogleSilentAuth) and waits for it.
@MainActor
@Observable
final class SessionManager {
    private(set) var session: Session?
    /// true while a silent re-auth is wanted, the ui hosts the hidden web view for it
    private(set) var reauthWanted = false
    /// set when silent re-auth gave up: show the sign-in sheet, keep showing cached data
    var needsSheet = false
    private(set) var config: PortalConfig?

    @ObservationIgnored let transport: Transport
    @ObservationIgnored let auth: Auth
    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private var waiter: CheckedContinuation<Session?, Never>?
    @ObservationIgnored private var renewing: Task<Session, Error>?

    private static let margin: TimeInterval = 90
    private static let reauthTimeout: UInt64 = 30

    init(store: SessionStore, transport: Transport) {
        self.store = store
        self.transport = transport
        self.auth = Auth(transport: transport)
        self.session = store.load()
    }

    var signedIn: Bool { session != nil }

    /// the google account to ask for on silent re-auth, nil when we never saw one
    var googleHint: String? { store.loadHint() }


    func loadConfig() async -> PortalConfig? {
        if let config { return config }
        guard let c = try? await auth.config() else { return nil }
        config = c
        return c
    }

    /// googleCredential is the google id token the session was traded for, when there was one.
    /// it decides which google account silent re-auth asks for, any other way in forgets it.
    func signedIn(_ s: Session, googleCredential: String? = nil) {
        if !Demo.owns(s) {
            store.save(s)
            if let email = googleCredential.flatMap({ jwtClaims($0)?["email"].string }), !email.isEmpty {
                store.saveHint(email)
            } else {
                store.clearHint()
            }
        }
        session = s
        needsSheet = false
        finishReauth(s)
    }

    /// the end of a silent re-auth. google may hand back whichever account the web
    /// view is signed in to, so a session for anyone else is refused, never swapped in.
    func renewed(_ s: Session, googleCredential: String) {
        guard let old = session, Session.sameStudent(old, s) else {
            DebugLog.note("reauth", "renewed session belongs to someone else")
            finishReauth(nil)
            return
        }
        signedIn(s, googleCredential: googleCredential)
    }

    func reauthFailed() { finishReauth(nil) }

    func signOut() {
        store.clear()
        session = nil
        needsSheet = false
        finishReauth(nil)
    }

    private func finishReauth(_ s: Session?) {
        reauthWanted = false
        if let w = waiter {
            waiter = nil
            w.resume(returning: s)
        }
    }

    private func fresh(_ s: Session) -> Bool {
        guard let exp = s.expiresAt else { return true }
        return transport.clock.now().addingTimeInterval(SessionManager.margin) < exp
    }

    private func valid(forceRenew: Bool) async throws -> Session {
        guard let current = session else { throw SignInRequired() }
        if !forceRenew && fresh(current) { return current }
        if let r = renewing { return try await r.value }
        let t = Task<Session, Error> { @MainActor in
            defer { self.renewing = nil }
            guard let now = self.session else { throw SignInRequired() }
            // another caller renewed while we waited
            if now.token != current.token && self.fresh(now) { return now }
            guard let renewed = await self.waitForReauth() else {
                self.needsSheet = true
                throw SignInRequired()
            }
            return renewed
        }
        renewing = t
        return try await t.value
    }

    private func waitForReauth() async -> Session? {
        reauthWanted = true
        return await withCheckedContinuation { (c: CheckedContinuation<Session?, Never>) in
            waiter = c
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: SessionManager.reauthTimeout * 1_000_000_000)
                if self.waiter != nil { self.finishReauth(nil) }
            }
        }
    }

    /// runs block with a live portal, renewing once if the server says the token died.
    /// everything heavy (json, the marks pdf) happens inside block, off the main actor.
    func call<T: Sendable>(_ block: @escaping @Sendable (Portal) async throws -> T) async throws -> T {
        let s = try await valid(forceRenew: false)
        if Demo.owns(s) { throw PortalError.malformed("the demo student has no portal behind it") }
        let transport = transport
        do {
            return try await block(Portal(session: s, transport: transport))
        } catch PortalError.sessionExpired {
            let renewed = try await valid(forceRenew: true)
            return try await block(Portal(session: renewed, transport: transport))
        }
    }
}
