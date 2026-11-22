import AuthenticationServices
import LynxCore
import LynxSync
import SwiftUI

/// First run: Welcome → (Sign in | Continue without account) (SPEC §9).
struct WelcomeFlow: View {
    @Environment(AppModel.self) private var model
    @State private var showAuth = ProcessInfo.processInfo.environment["LYNX_SCREEN"] == "signin"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if showAuth {
                // Wide windows keep the stage beside the form, so the screen still has its hero.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Brand.Space.xxl) {
                        AuthStage().frame(width: 380)
                        AuthView(onBack: { showAuth = false }, onDone: {}, showMark: false)
                    }
                    .padding(Brand.Space.xxl)
                    .frame(minWidth: 900)
                    AuthView(onBack: { showAuth = false }, onDone: {})
                }
                .transition(Motion.slide(.trailing, reduce: reduceMotion))
            } else {
                WelcomeView(onSignIn: { showAuth = true }, onSkip: { model.settings.onboarded = true; model.notifications.requestAuthorization() })
                    .transition(Motion.slide(.leading, distance: 12, reduce: reduceMotion))
            }
        }
        .animation(Motion.content, value: showAuth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WelcomeView: View {
    let onSignIn: () -> Void
    let onSkip: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var pal

    var body: some View {
        VStack(spacing: Brand.Space.xl) {
            Stage(padding: Brand.Space.xxl) {
                VStack(alignment: .leading, spacing: Brand.Space.xl) {
                    EtherlynxMark().frame(width: 64, height: 64).foregroundStyle(pal.fg)
                        .entrance(1)
                    VStack(alignment: .leading, spacing: Brand.Space.s) {
                        Text("Lynx Reminders").font(Brand.display(40)).tracking(-1.2)
                        Text("Reminders that find you: at a time, every 45 minutes between nine and six, when you leave home, when your headphones connect.")
                            .font(Brand.text(15)).foregroundStyle(pal.fg.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .entrance(2)
                    Spacer(minLength: 0)
                    HStack(spacing: Brand.Space.xl) {
                        InkPill(title: "Sign in", action: onSignIn).disabled(model.backend == nil)
                        LinkButton(title: "Continue without account", action: onSkip)
                    }
                    .entrance(3)
                    if model.backend == nil {
                        Text("No server is configured in this build, so everything stays on this device.")
                            .font(Brand.caption).foregroundStyle(pal.fg.opacity(0.6))
                            .entrance(4)
                    }
                }
                .frame(maxWidth: 460, alignment: .leading)
            }
            .frame(maxWidth: 560, maxHeight: 520)
            .entrance(0)
        }
        .padding(Brand.Space.xxl)
    }
}

/// The stage beside the sign-in form: the mark and what an account adds.
struct AuthStage: View {
    @Environment(\.palette) private var pal
    var body: some View {
        Stage(padding: Brand.Space.xxl) {
            VStack(alignment: .leading, spacing: Brand.Space.xl) {
                EtherlynxMark().frame(width: 56, height: 56).foregroundStyle(pal.fg)
                Spacer(minLength: Brand.Space.xxl)
                Text("One account,\nevery device.").font(Brand.display(34)).tracking(-1)
                    .entrance(1)
                VStack(alignment: .leading, spacing: Brand.Space.s) {
                    let lines = ["Sync between Mac, iPhone, iPad and Android", "Share a list or a single reminder", "Assign reminders to people in a list"]
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        HStack(alignment: .firstTextBaseline, spacing: Brand.Space.s) {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                            Text(line).font(Brand.text(13.5))
                        }
                        .foregroundStyle(pal.fg.opacity(0.75))
                        .entrance(2 + i)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: 560)
    }
}

/// Sign in / Create account on one screen with a capsule switch, plus "Email me a code" and passkeys.
struct AuthView: View {
    let onBack: (() -> Void)?
    let onDone: () -> Void
    var showMark = true
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var pal
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var passkeyBusy = false

    enum Mode: Hashable { case signIn, create, code }
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.xl) {
            HStack {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)).frame(width: 30, height: 30)
                            .background(pal.sunk, in: Circle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Back")
                }
                Spacer()
                if showMark { EtherlynxMark().frame(width: 28, height: 28).foregroundStyle(pal.fg) }
            }
            VStack(alignment: .leading, spacing: Brand.Space.s) {
                Text(mode == .create ? "Create your account" : "Sign in").font(Brand.display(28)).tracking(-0.8)
                Text("Your reminders sync between your Mac, iPhone and Android, and you can share lists.")
                    .font(Brand.text(13)).foregroundStyle(pal.muted).fixedSize(horizontal: false, vertical: true)
            }
            // Clearing the message here (not in onChange) keeps "We sent a code" when sign-up moves to the code step itself.
            CapsuleTabs(items: [(Mode.signIn, "Sign in"), (.create, "Create account"), (.code, "Email me a code")],
                        selection: Binding(get: { mode }, set: { mode = $0; message = nil; isError = false }))
            VStack(alignment: .leading, spacing: Brand.Space.s) {
                SunkField(placeholder: "Email", text: $email)
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.emailAddress).textContentType(.username)
                    #endif
                if mode != .code {
                    SunkField(placeholder: mode == .create ? "Password (8+ characters)" : "Password", text: $password, secure: true)
                        .onSubmit(submit)
                } else if codeSent {
                    SunkField(placeholder: "6-digit code", text: $code, mono: true).onSubmit(submit)
                }
            }
            if let message {
                Text(message).font(Brand.caption).foregroundStyle(isError ? pal.signal : pal.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Brand.Space.l) {
                InkPill(title: buttonTitle, busy: busy, action: submit).disabled(!canSubmit || busy || passkeyBusy)
                if mode == .code && codeSent {
                    LinkButton(title: "Send again") { codeSent = false; submit() }
                }
                if mode == .signIn && model.backend?.supportsPasskeys == true {
                    SoftButton(title: passkeyBusy ? "Waiting for passkey…" : "Use a passkey", symbol: "person.badge.key", action: signInWithPasskey)
                        .disabled(busy || passkeyBusy)
                }
            }
            if model.db.lists.values.contains(where: { !$0.isDeleted }) && !model.signedIn {
                Text("Reminders already on this device are uploaded to your account.")
                    .font(Brand.caption).foregroundStyle(pal.muted)
            }
        }
        .frame(maxWidth: 420)
        .padding(Brand.Space.xxl)
        // Fields and the message slide in and out as the mode changes instead of jumping.
        .animation(Motion.content, value: mode)
        .animation(Motion.content, value: codeSent)
        .animation(Motion.content, value: message)
    }

    private var buttonTitle: String {
        switch mode {
        case .signIn: return "Sign in"
        case .create: return "Create account"
        case .code: return codeSent ? "Sign in" : "Send code"
        }
    }

    private var canSubmit: Bool {
        guard email.contains("@") else { return false }
        switch mode {
        case .signIn: return !password.isEmpty
        case .create: return password.count >= 8
        case .code: return !codeSent || code.count >= 6
        }
    }

    private func submit() {
        guard canSubmit, let backend = model.backend else { return }
        let email = self.email.trimmingCharacters(in: .whitespaces).lowercased()
        busy = true
        message = nil
        isError = false
        Task {
            defer { busy = false }
            do {
                switch mode {
                case .signIn:
                    model.signedIn(try await backend.signIn(email: email, password: password))
                    onDone()
                case .create:
                    switch try await backend.signUp(email: email, password: password) {
                    case .signedIn(let u):
                        model.signedIn(u)
                        onDone()
                    case .confirmEmail:
                        // The confirmation email carries a 6-digit code; verifying it confirms and signs in.
                        mode = .code
                        codeSent = true
                        code = ""
                        message = "We sent a 6-digit code to \(email). Type it to finish creating your account."
                    }
                case .code:
                    if !codeSent {
                        try await backend.sendCode(email: email)
                        codeSent = true
                        message = "We sent a code to \(email)."
                    } else {
                        model.signedIn(try await backend.verifyCode(email: email, code: code.trimmingCharacters(in: .whitespaces)))
                        onDone()
                    }
                }
            } catch {
                isError = true
                message = Self.describe(error)
            }
        }
    }

    /// Opens the passkey page in a browser sheet; it signs in and hands the session back (SPEC §9).
    private func signInWithPasskey() {
        guard let backend = model.backend else { return }
        passkeyBusy = true
        message = nil
        isError = false
        Task {
            defer { passkeyBusy = false }
            do {
                let state = LynxBackend.newPasskeyState()
                guard let callback = try await webAuth.passkeyPage(backend.passkeySignInURL(state: state)) else { return }
                model.signedIn(try await backend.completePasskeySignIn(callback: callback, state: state))
                onDone()
            } catch PasskeyError.cancelled {
                // Went back on the page: nothing to report.
            } catch {
                isError = true
                message = Self.describe(error)
            }
        }
    }

    static func describe(_ error: Error) -> String {
        let s = error.localizedDescription
        if (error as? URLError) != nil || s.localizedCaseInsensitiveContains("could not connect") {
            return "Can't reach the server. You can keep using Lynx without an account."
        }
        return s
    }
}

/// Account: name, email, sign out (keep / remove local data), delete account.
struct AccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var pal
    @State private var name = ""
    @State private var confirmSignOut = false
    @State private var confirmDelete = false
    @State private var busy = false
    @State private var error: String?
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var passkeys: [PasskeyInfo] = []
    @State private var passkeyBusy = false
    @State private var removingPasskey: PasskeyInfo?
    @State private var renamingPasskey: PasskeyInfo?
    @State private var passkeyName = ""

    var body: some View {
        Group {
            if let u = model.user {
                SheetScaffold(title: "Account", doneTitle: "Close", onCancel: { dismiss() }, onDone: { dismiss() }) {
                    HStack(spacing: Brand.Space.m) {
                        Avatar(profile: model.profile ?? Profile(id: u.id, email: u.email, displayName: nil), size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.profile?.name ?? u.email ?? "").font(Brand.title)
                            Text(u.email ?? "").font(Brand.mono(11, .regular)).foregroundStyle(pal.muted)
                        }
                    }
                    Panel(padding: 0) {
                        VStack(spacing: 0) {
                            FormRow("Name") {
                                TextField("Your name", text: $name).textFieldStyle(.plain).font(Brand.text(13)).multilineTextAlignment(.trailing)
                                    .onSubmit { Task { await model.updateDisplayName(name) } }
                            }
                            Hairline()
                            FormRow("Sync") {
                                Text(syncText).font(Brand.mono(11, .regular)).foregroundStyle(model.syncError == nil ? pal.muted : pal.signal)
                                    .lineLimit(2).multilineTextAlignment(.trailing)
                                SoftButton(title: "Sync now") { Task { await model.runSync(manifest: true) } }
                            }
                        }
                    }
                    if model.backend?.supportsPasskeys == true { passkeyPanel }
                    if let error { Text(error).font(Brand.caption).foregroundStyle(pal.signal) }
                    HStack {
                        SoftButton(title: "Sign out", symbol: "rectangle.portrait.and.arrow.right") { confirmSignOut = true }
                        Spacer()
                        LinkButton(title: "Delete account…", role: .destructive) { confirmDelete = true }
                    }
                    Spacer(minLength: 0)
                }
                .onAppear { name = model.profile?.name ?? "" }
                .task { await loadPasskeys() }
                .alert("Rename passkey", isPresented: Binding(get: { renamingPasskey != nil }, set: { if !$0 { renamingPasskey = nil } }),
                       presenting: renamingPasskey) { p in
                    TextField("Passkey name", text: $passkeyName)
                    Button("Cancel", role: .cancel) {}
                    Button("Save") { Task { await renamePasskey(p) } }
                        .disabled(passkeyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } message: { _ in
                    Text("A name that tells you where it's saved, like the device or password manager.")
                }
                .confirmationDialog("Remove this passkey?", isPresented: Binding(get: { removingPasskey != nil }, set: { if !$0 { removingPasskey = nil } }),
                                    titleVisibility: .visible, presenting: removingPasskey) { p in
                    Button("Remove passkey", role: .destructive) { Task { await removePasskey(p) } }
                    Button("Cancel", role: .cancel) {}
                } message: { _ in
                    Text("You can't sign in with it any more. It also stays in your password manager until you delete it there.")
                }
                .confirmationDialog("Sign out", isPresented: $confirmSignOut, titleVisibility: .visible) {
                    Button("Keep a local copy") { Task { await model.signOut(.keep); dismiss() } }
                    Button("Remove from this device", role: .destructive) { Task { await model.signOut(.remove); dismiss() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Your reminders stay in your account either way.")
                }
                .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete account and data", role: .destructive) {
                        Task {
                            do { try await model.deleteAccount(); dismiss() } catch { self.error = error.localizedDescription }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This deletes your account and every list you own, on all devices. It can't be undone.")
                }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        LinkButton(title: "Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                    .padding([.top, .horizontal], Brand.Space.xl)
                    if model.backend == nil {
                        Text("No server is configured in this build (Config/Supabase.json), so Lynx works on this device only.")
                            .font(Brand.text(13)).foregroundStyle(pal.muted).padding(Brand.Space.xxl)
                    } else {
                        AuthView(onBack: nil, onDone: { dismiss() })
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 500, height: model.user == nil ? 520 : (model.backend?.supportsPasskeys == true ? 520 : 400))
        #endif
        .background(pal.bg)
    }

    /// Passkeys on this account, plus "Add a passkey" (SPEC §9).
    private var passkeyPanel: some View {
        Panel(padding: 0) {
            VStack(spacing: 0) {
                ForEach(passkeys) { p in
                    FormRow(p.name ?? "Passkey", symbol: "person.badge.key") {
                        Text("Added \(p.createdAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(Brand.mono(11, .regular)).foregroundStyle(pal.muted)
                        LinkButton(title: "Rename") { passkeyName = p.name ?? ""; renamingPasskey = p }
                        LinkButton(title: "Remove", role: .destructive) { removingPasskey = p }
                    }
                    Hairline()
                }
                FormRow("Passkeys") {
                    if passkeys.isEmpty {
                        Text("Sign in with Face ID or Touch ID").font(Brand.caption).foregroundStyle(pal.muted)
                            .lineLimit(2).multilineTextAlignment(.trailing)
                    }
                    SoftButton(title: passkeyBusy ? "Waiting…" : "Add a passkey", symbol: "plus", action: addPasskey)
                        .disabled(passkeyBusy)
                }
            }
        }
    }

    private func loadPasskeys() async {
        guard let backend = model.backend, backend.supportsPasskeys else { return }
        if let list = try? await backend.passkeys() { passkeys = list }
    }

    private func addPasskey() {
        guard let backend = model.backend else { return }
        passkeyBusy = true
        error = nil
        Task {
            defer { passkeyBusy = false }
            do {
                let state = LynxBackend.newPasskeyState()
                guard let callback = try await webAuth.passkeyPage(backend.passkeyAddURL(state: state)) else { return }
                try backend.completePasskeyAdd(callback: callback, state: state)
                await loadPasskeys()
            } catch PasskeyError.cancelled {
            } catch {
                self.error = AuthView.describe(error)
            }
        }
    }

    private func renamePasskey(_ p: PasskeyInfo) async {
        guard let backend = model.backend else { return }
        let name = String(passkeyName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !name.isEmpty, name != p.name else { return }
        do {
            try await backend.renamePasskey(p.id, to: name)
            if let i = passkeys.firstIndex(where: { $0.id == p.id }) { passkeys[i].name = name }
        } catch {
            self.error = AuthView.describe(error)
        }
    }

    private func removePasskey(_ p: PasskeyInfo) async {
        guard let backend = model.backend else { return }
        do {
            try await backend.removePasskey(p.id)
            passkeys.removeAll { $0.id == p.id }
        } catch {
            self.error = AuthView.describe(error)
        }
    }

    private var syncText: String {
        if model.syncing { return "Syncing…" }
        if let e = model.syncError { return e }
        if let t = model.db.sync.lastSyncAt { return "Last synced \(Formats.time(t))" }
        return "Not synced yet"
    }
}

extension WebAuthenticationSession {
    /// Shows the passkey page (on the relying party's domain) in a browser sheet and returns its
    /// `lynxreminders://auth-callback` URL; nil when the user closed the sheet. An ephemeral session
    /// needs no cookies and skips the "wants to use … to sign in" prompt; passkeys aren't cookies.
    func passkeyPage(_ url: URL) async throws -> URL? {
        do {
            return try await authenticate(using: url, callbackURLScheme: LynxBackend.passkeyCallbackScheme,
                                          preferredBrowserSession: .ephemeral)
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            return nil
        }
    }
}
