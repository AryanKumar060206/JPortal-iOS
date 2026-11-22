import SwiftUI
import WebKit

/// turns what a sign-in page said into a session, or a message for the person
@MainActor
private func handle(_ signal: WebSignal, graph: AppGraph, busy: @escaping (Bool) -> Void, error: @escaping (String?) -> Void) {
    switch signal {
    case .credential(let token, _):
        busy(true)
        Task {
            do {
                let s = try await graph.sessions.auth.exchangeGoogleToken(token, config: graph.sessions.config)
                graph.signedIn(s, googleCredential: token)
            } catch {
                DebugLog.record("signin", error)
                busy(false)
                handleError(describe(error))
            }
        }
    case .loginResponse(let body):
        do {
            let s = try graph.sessions.auth.sessionFrom(try JSON(parsing: body)["response"])
            graph.signedIn(s)
        } catch {
            DebugLog.record("signin-a", error)
            handleError("The portal signed you in, but JPortal couldn't read it")
        }
    case .failed:
        handleError("Google sign-in didn't load, check your connection")
    case .ready, .noAuto:
        break
    }

    func handleError(_ m: String) { error(m) }
}

/// google's own button, rendered by google inside a small transparent web view
/// so it sits in our layout like any other control
struct GoogleButton: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p
    @State private var config: PortalConfig?
    @State private var loaded = false
    @State private var ready = false
    @State private var busy = false
    @State private var error: String?
    @State private var popup: PopupBox?
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { g in
                let width = Int(min(400, g.size.width))
                ZStack {
                    if busy || !loaded {
                        LoadingBlob(size: 40)
                    } else if let cid = config?.googleClientId, !cid.isEmpty {
                        if !ready { LoadingBlob(size: 40) }
                        PortalWebView(page: .signin(clientId: cid, dark: false, width: width)) { s in
                            if case .ready = s { ready = true } else { handle(s, graph: graph, busy: { busy = $0 }, error: { error = $0 }) }
                        } onPopup: { web in
                            popup = web.map { PopupBox(web: $0) }
                        }
                        .opacity(ready ? 1 : 0)
                        .id(attempt)
                    } else {
                        Button("Can't reach the portal, retry") {
                            loaded = false
                            attempt += 1
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }
                .frame(width: g.size.width, height: g.size.height)
            }
            .frame(height: 56)
            if let error {
                Text(error).font(.subheadline).foregroundStyle(p.error).multilineTextAlignment(.center).transition(.opacity)
            }
        }
        .animation(.easeInOut, value: error)
        .task(id: attempt) {
            config = await graph.sessions.loadConfig()
            loaded = true
        }
        .sheet(item: $popup) { box in
            PopupHost(box: box) { popup = nil }
        }
    }
}

/// the real portal login page, we just read its answer. for when google blocks our own page
private struct PortalPageSignIn: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p
    @State private var error: String?
    @State private var popup: PopupBox?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error {
                    Text(error).font(.subheadline).foregroundStyle(p.error).padding(.horizontal, 16).padding(.vertical, 8)
                }
                PortalWebView(page: .portal) { s in
                    handle(s, graph: graph, busy: { _ in }, error: { error = $0 })
                } onPopup: { web in
                    popup = web.map { PopupBox(web: $0) }
                }
            }
            .navigationTitle("Sign in on the portal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .sheet(item: $popup) { box in PopupHost(box: box) { popup = nil } }
    }
}

private struct SessionCodeForm: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p
    @State private var code = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Session code", text: $code, axis: .vertical)
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(p.containerLow, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).stroke(error == nil ? p.outlineVariant : p.error))
                .onChange(of: code) { error = nil }
            Text(error ?? "From another device running JPortal").font(.caption).foregroundStyle(error == nil ? p.onSurfaceVariant : p.error)
            Button {
                if let s = decodeSessionCode(code) { graph.signedIn(s) } else { error = "That code doesn't look right" }
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(code.isBlank)
        }
    }
}

/// the other ways in, tucked under the google button
private struct OtherWays: View {
    @State private var portal = false
    @State private var code = false

    var body: some View {
        VStack(spacing: 8) {
            Button("Having trouble? Use the portal page") { portal = true }
                .font(.subheadline.weight(.semibold))
            if code {
                SessionCodeForm().transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Button("I have a session code") { withAnimation { code = true } }
                    .font(.subheadline.weight(.semibold))
            }
        }
        .fullScreenCover(isPresented: $portal) { PortalPageSignIn() }
    }
}

struct SignInScreen: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p
    @State private var starting = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer().frame(height: 56)
                AppMark(size: 144)
                Text("JPortal").font(.system(size: 40, weight: .bold, design: .rounded)).padding(.top, 20)
                Text("Your attendance, marks and grades, without the portal.")
                    .font(.body).foregroundStyle(p.onSurfaceVariant).multilineTextAlignment(.center).padding(.top, 8)
                GoogleButton().padding(.top, 48)
                Text("Use your JIIT Google account.")
                    .font(.footnote).foregroundStyle(p.onSurfaceVariant).multilineTextAlignment(.center).padding(.top, 8)
                OtherWays().padding(.top, 24)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(p.surface.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            Button {
                starting = true
                Task { await graph.startDemo() }
            } label: {
                Text("Demo").font(.subheadline.weight(.semibold))
            }
            .disabled(starting)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }
}

/// shown over cached data when the token died and silent re-auth couldn't fix it
struct SignInSheet: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Sign in again").font(.title2.weight(.semibold))
                Text("Your portal session ran out.").font(.subheadline).foregroundStyle(p.onSurfaceVariant)
                GoogleButton().padding(.vertical, 8)
                OtherWays()
                Button("Sign out instead", role: .destructive) { graph.signOut() }.padding(.top, 8)
            }
            .padding(24)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(p.surface)
    }
}

/// silent re-auth: an invisible web view asking google's oauth endpoint for a
/// fresh id token with prompt=none. google answers without any ui when it still
/// has a session for the account, see GoogleSilentAuth for why not one tap
struct ReauthHost: View {
    @Environment(AppGraph.self) private var graph
    @State private var cid: String?
    @State private var done = false
    @State private var nonce = GoogleSilentAuth.nonce()

    var body: some View {
        ZStack {
            if let cid, !cid.isEmpty {
                PortalWebView(page: .silentGoogle(clientId: cid, loginHint: graph.sessions.googleHint, nonce: nonce)) { s in
                    switch s {
                    case .credential(let token, _):
                        Task {
                            do {
                                let session = try await graph.sessions.auth.exchangeGoogleToken(token, config: graph.sessions.config)
                                done = true
                                graph.sessions.renewed(session, googleCredential: token)
                            } catch {
                                DebugLog.record("reauth", error)
                                done = true
                                graph.sessions.reauthFailed()
                            }
                        }
                    case .noAuto(let why), .failed(let why):
                        DebugLog.note("reauth", "google said \(why)")
                        done = true
                        graph.sessions.reauthFailed()
                    default: break
                    }
                } onPopup: { web in
                    // a popup means google wants the person, that's the sheet's job
                    if web != nil {
                        done = true
                        graph.sessions.reauthFailed()
                    }
                }
            }
        }
        .opacity(0.001)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            let c = await graph.sessions.loadConfig()
            if (c?.googleClientId ?? "").isEmpty { graph.sessions.reauthFailed() } else { cid = c?.googleClientId }
        }
        .onDisappear { if !done { graph.sessions.reauthFailed() } }
    }
}
