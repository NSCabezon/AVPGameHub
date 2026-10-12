import AppKit
import Darwin
import HubCore
import MetaStore
import Observation
import SteamDepot
import SwiftUI

// MARK: - Steam

/// Steam sign-in through SteamDepot (QR or password + Steam Guard). Only the refresh token is
/// stored (the same JSON file the `steamdepot` CLI uses, path in Settings); the password goes to
/// Steam RSA-encrypted and is dropped right after.
@MainActor @Observable
final class SteamAccount {
    let settings: AppSettings
    /// Login name: never shown (masked in logs). The UI shows only the public persona name.
    var accountName: String?
    /// Public Steam persona name (cached in UserDefaults once fetched after sign-in).
    var personaName: String? = UserDefaults.standard.string(forKey: "steamPersona")
    var qr: NSImage?
    var message = ""
    var busy = false
    var guardType: SteamGuardType?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var session: SteamSession?
    @ObservationIgnored private var auth: CredentialsAuthSession?

    init(settings: AppSettings) {
        self.settings = settings
        refresh()
    }

    var store: FileCredentialStore { FileCredentialStore(url: settings.expanded(settings.steamTokenPath)) }
    var signedIn: Bool { accountName != nil }

    func refresh() {
        accountName = (try? store.load())?.accountName
        Privacy.register([accountName])
        if accountName == nil { setPersona(nil) }
    }

    private func setPersona(_ name: String?) {
        personaName = name
        UserDefaults.standard.set(name, forKey: "steamPersona")
    }

    /// Logs on once with the saved token to learn the public persona name (and the SteamID, only
    /// so logs can mask it). Called after sign-in, or when the name isn't known yet.
    func fetchPersona() async {
        guard signedIn else { return }
        do {
            let s = try await loggedOnSession()
            var name: String?
            for _ in 0..<25 {
                name = await s.personaName
                if name != nil { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            let id = await s.steamID
            await s.disconnect()
            Privacy.register([id == 0 ? nil : String(id)])
            if let name { setPersona(name) }
        } catch {}
    }

    /// Logs on once with the saved token: says whether Steam still accepts it (and refreshes the
    /// public name), the Steam twin of Meta's "Check session".
    func checkSession() async {
        guard signedIn else { return }
        do {
            let s = try await loggedOnSession()
            let name = await s.personaName
            await s.disconnect()
            if let name { setPersona(name) }
            message = L("Sesión de Steam válida ✓", "Steam session is valid ✓")
        } catch { message = Privacy.redact("\(error)") }
    }

    private var deviceName: String { "AVP Game Hub (\(Host.current().localizedName ?? "Mac"))" }

    func startQR() {
        cancel()
        busy = true
        qr = nil
        message = L("Conectando con Steam…", "Connecting to Steam…")
        let session = SteamSession()
        self.session = session
        let name = deviceName
        task = Task {
            do {
                try await session.connect()
                let creds = try await session.authenticateWithQR(deviceName: name) { url in
                    await MainActor.run {
                        self.qr = QRImage.make(url)
                        self.message = L("Escanéalo con la app de Steam del móvil", "Scan it with the Steam mobile app")
                    }
                }
                try self.finish(creds)
            } catch is CancellationError {
            } catch {
                self.message = "\(error)"
            }
            await session.disconnect()
            self.busy = false
            self.qr = nil
        }
    }

    func startPassword(user: String, password: String) {
        cancel()
        guard !user.isEmpty, !password.isEmpty else { return }
        busy = true
        message = L("Conectando con Steam…", "Connecting to Steam…")
        let session = SteamSession()
        self.session = session
        let name = deviceName
        let guardData = (try? store.load()).flatMap { $0?.accountName.lowercased() == user.lowercased() ? $0?.guardData : nil }
        task = Task {
            do {
                try await session.connect()
                let auth = try await session.beginCredentialsAuth(accountName: user, password: password, deviceName: name,
                                                                  guardData: guardData)
                self.auth = auth
                self.guardType = auth.needsCode
                if let t = auth.needsCode {
                    self.message = auth.canApproveOnDevice
                        ? L("Aprueba en la app de Steam o escribe el código (\(t))", "Approve in the Steam app or type the code (\(t))")
                        : L("Escribe el código de Steam Guard (\(t))", "Type the Steam Guard code (\(t))")
                } else if auth.canApproveOnDevice {
                    self.message = L("Aprueba el inicio de sesión en la app de Steam", "Approve the sign-in in the Steam app")
                } else if auth.canApproveByEmail {
                    self.message = L("Aprueba desde el correo que te ha enviado Steam", "Approve from the e-mail Steam sent you")
                }
                let creds = try await session.waitForCredentialsAuth(auth)
                try self.finish(creds)
            } catch is CancellationError {
            } catch {
                self.message = "\(error)"
            }
            await session.disconnect()
            self.busy = false
            self.guardType = nil
            self.auth = nil
        }
    }

    func submitCode(_ code: String) {
        guard let session, let auth, let type = guardType else { return }
        let c = code.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return }
        Task {
            do {
                try await session.submitGuardCode(auth, code: c, type: type)
                self.message = L("Código aceptado, terminando…", "Code accepted, finishing…")
            } catch {
                self.message = L("Código rechazado: ", "Code rejected: ") + "\(error)"
            }
        }
    }

    private func finish(_ creds: SteamCredentials) throws {
        try store.save(creds)
        accountName = creds.accountName
        Privacy.register([creds.accountName])
        message = L("Sesión iniciada en Steam ✓", "Signed in to Steam ✓")
        Task { await fetchPersona() }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if let s = session { Task { await s.disconnect() } }
        session = nil
        busy = false
        qr = nil
        guardType = nil
    }

    func signOut() {
        try? store.clear()
        refresh()
        message = L("Token borrado de este Mac (el visor guarda el suyo)", "Token removed from this Mac (the headset keeps its own)")
    }

    func sendToHeadset() async {
        do {
            guard let creds = try store.load() else { throw HubError(L("No hay sesión de Steam", "Not signed in to Steam")) }
            let t = try settings.deviceTarget()
            message = L("Copiando al visor…", "Copying to the headset…")
            try await DeviceOps.copyToHeadsetDocuments(try JSONEncoder().encode(creds), fileName: "steamdepot-token.json",
                                                       device: t.device, bundle: t.bundle)
            message = L("Token copiado: el hub lo importa al abrir la biblioteca", "Token copied: the hub imports it when its library opens")
        } catch {
            message = "\(error)"
        }
    }

    /// A logged-on session from the saved token (for ownership checks and downloads).
    func loggedOnSession(log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> SteamSession {
        guard let creds = try store.load() else { throw HubError(L("No hay sesión de Steam", "Not signed in to Steam")) }
        let s = SteamSession(log: log)
        try await s.connect()
        try await s.logOn(creds, machineName: "AVP Game Hub")
        return s
    }
}

// MARK: - Meta

/// Meta sign-in: Meta's own ovr-platform-util runs on a pseudo-terminal (MetaStore.MetaLogin);
/// what is typed here goes to that tool and nowhere else, and only the token it prints is kept
/// (login Keychain via /usr/bin/security, the same item the `metastore` CLI uses).
@MainActor @Observable
final class MetaAccount {
    let settings: AppSettings
    let toolSetup: MetaToolSetup
    var signedIn = false
    var userID: String?
    var terminal = ""
    var running = false
    var message = ""
    @ObservationIgnored let tokenStore = SecurityCLITokenStore()

    init(settings: AppSettings) {
        self.settings = settings
        self.toolSetup = MetaToolSetup(settings: settings)
    }

    func refresh() async {
        let store = tokenStore
        let has = await Task.detached { ((try? store.load()) ?? nil) != nil }.value
        signedIn = has
        if !has { userID = nil }
    }

    func token() throws -> String {
        guard let t = try tokenStore.load() else { throw HubError(L("No hay sesión de Meta", "Not signed in to Meta")) }
        return t
    }

    func whoami() async {
        do {
            let t = try token()
            let id = try await MetaClient(token: t).me()
            userID = id
            Privacy.register([id])
            message = L("Sesión de Meta válida ✓", "Meta session is valid ✓")
        } catch { message = Privacy.redact("\(error)") }
    }

    /// The prompt the tool is waiting on now (detected from its output), if recognised.
    var prompt: MetaPrompt?
    /// The tool asked for a code and the Code field should show.
    var awaitingCode = false
    /// The tool seems to ask something the fields don't cover: answer in Details.
    var unexpectedPrompt = false
    /// The last run failed after a code was sent; a new code re-runs the sign-in with the
    /// credentials still held in memory for this attempt.
    var canRetryCode = false
    /// Output since the last answer, only for spotting an unexpected question.
    @ObservationIgnored private var sinceAnswer = ""
    /// Credentials for the current attempt only: in memory, never stored, logged or shown;
    /// dropped on success, cancel, sign-out or a failure that is not a code retry.
    @ObservationIgnored private var held: MetaCredentials?
    /// The running attempt (prompt detection and typing live in HubCore.MetaLoginDriver).
    @ObservationIgnored private var driver: MetaLoginDriver?
    /// Events from an earlier (cancelled) attempt are ignored.
    @ObservationIgnored private var attempt = UUID()

    /// Sign-in from the Email / Password fields: the tool is started and each value is fed in
    /// when the tool prompts for it. Empty fields fall back to typing into the console.
    func startLogin(email: String = "", password: String = "") {
        guard !running else { return }
        let creds = MetaCredentials(email: email, password: password)
        held = !creds.email.isEmpty && !password.isEmpty ? creds : nil
        canRetryCode = false
        launch(code: nil)
    }

    /// A code typed in the Code field: sent now if the tool is running, or — after a rejected
    /// code — the sign-in is re-run with the held credentials and this code goes in when asked.
    func submitCode(_ raw: String) {
        let code = MetaPrompt.normalizedCode(raw)
        guard MetaPrompt.isValidCode(code) else {
            message = L("El código son 6–8 dígitos.", "The code is 6–8 digits.")
            return
        }
        if running, let driver {
            driver.send(code, isCode: true)
            awaitingCode = false
            message = L("Código enviado, comprobando…", "Code sent, checking…")
        } else if canRetryCode {
            canRetryCode = false
            launch(code: code)
        }
    }

    private func launch(code: String?) {
        let tool = MetaTool(url: settings.metaToolURL)
        do { try tool.verify() } catch {
            message = "\(error)"
            forgetCredentials()
            return
        }
        // A previous attempt still running (its own pid only) goes first.
        driver?.cancel()
        terminal = L("ovr-platform-util está firmado por Meta (\(MetaTool.expectedTeam)). Lo que envíes va directo a esa herramienta.\n\n",
                     "ovr-platform-util is signed by Meta (\(MetaTool.expectedTeam)). What you send goes straight to that tool.\n\n")
        message = code == nil ? L("Conectando con Meta…", "Contacting Meta…") : L("Reintentando con el código nuevo…", "Retrying with the new code…")
        running = true
        prompt = nil
        awaitingCode = false
        sinceAnswer = ""
        unexpectedPrompt = false
        var creds = held
        creds?.code = code
        let id = UUID()
        attempt = id
        let d = MetaLoginDriver(credentials: creds) { [weak self] event in
            Task { @MainActor in self?.handle(event, attempt: id) }
        }
        driver = d
        let url = tool.url
        d.start { input, output, onSpawn in
            try MetaLogin.run(tool: url, input: input, output: output, onSpawn: onSpawn)
        }
    }

    private func handle(_ event: MetaLoginDriver.Event, attempt id: UUID) {
        guard id == attempt else { return }
        switch event {
        case .output(let text):
            terminal += Privacy.redact(text, secrets: [held?.email].compactMap { $0 })
            sinceAnswer += text
        case .prompt(let p):
            guard running else { return }
            prompt = p
            if p == .code, held?.code == nil, driver?.codeSent != true {
                awaitingCode = true
                message = L("Meta pide el código de verificación (app de autenticación o e-mail).",
                            "Meta asks for the verification code (authenticator app or e-mail).")
            }
            if p == nil {
                let last = sinceAnswer.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                unexpectedPrompt = last.hasSuffix(":") || last.hasSuffix("?")
                if unexpectedPrompt {
                    message = L("La herramienta pregunta algo inesperado: respóndelo en Detalles.",
                                "The tool asks something unexpected: answer it in Details.")
                }
            }
        case .answered(let p):
            sinceAnswer = ""
            prompt = nil
            unexpectedPrompt = false
            if p == .code {
                awaitingCode = false
                message = L("Código enviado, comprobando…", "Code sent, checking…")
            }
        case .finished(let result, let rawTail):
            let codeSent = driver?.codeSent ?? false
            driver = nil
            running = false
            prompt = nil
            awaitingCode = false
            unexpectedPrompt = false
            let store = tokenStore
            Task {
                let saved: Result<Void, Error> = await Task.detached {
                    result.flatMap { t in Result { try store.save(t) } }
                }.value
                switch saved {
                case .success:
                    self.forgetCredentials()
                    self.message = L("Sesión iniciada. Token en el Llavero de este Mac.", "Signed in. Token stored in this Mac's Keychain.")
                    await self.refresh()
                    await self.whoami()
                case .failure(let e):
                    let tail = Privacy.redact(rawTail, secrets: [self.held?.email].compactMap { $0 })
                    if codeSent, self.held != nil {
                        self.canRetryCode = true
                        self.message = L("Meta rechazó el código o caducó", "Meta rejected the code or it expired")
                            + (tail.isEmpty ? "" : ": \(tail)")
                            + L(". Escribe un código nuevo para reintentar.", ". Enter a new code to retry.")
                    } else {
                        self.forgetCredentials()
                        self.message = tail.isEmpty ? "\(e)" : "\(tail) (\(e))"
                    }
                }
            }
        }
    }

    private func forgetCredentials() {
        held = nil
        canRetryCode = false
    }

    /// One line typed in the Details console, sent to the tool as is (not stored or logged).
    func send(_ line: String) {
        sinceAnswer = ""
        unexpectedPrompt = false
        driver?.send(line)
    }

    func cancelLogin() {
        forgetCredentials()
        attempt = UUID()
        driver?.cancel()
        driver = nil
        running = false
        prompt = nil
        awaitingCode = false
        unexpectedPrompt = false
        message = L("Inicio de sesión cancelado", "Sign-in cancelled")
    }


    func signOut() async {
        forgetCredentials()
        try? tokenStore.clear()
        await refresh()
        message = L("Token borrado de este Mac (el visor guarda el suyo)", "Token removed from this Mac (the headset keeps its own)")
    }

    func sendToHeadset() async {
        do {
            let t = try token()
            let target = try settings.deviceTarget()
            message = L("Copiando al visor…", "Copying to the headset…")
            try await DeviceOps.copyToHeadsetDocuments(try TokenHandoff.encode(token: t), fileName: TokenHandoff.fileName,
                                                       device: target.device, bundle: target.bundle)
            message = L("Token copiado: el hub lo importa al abrir la biblioteca", "Token copied: the hub imports it when its library opens")
        } catch {
            message = "\(error)"
        }
    }
}

// MARK: - View

struct AccountsView: View {
    @Environment(AppModel.self) private var app
    @State private var steamUser = ""
    @State private var steamPassword = ""
    @State private var steamCode = ""
    @State private var metaLine = ""
    @State private var metaSecret = true
    @State private var metaEmail = ""
    @State private var metaPassword = ""
    @State private var metaCode = ""
    @State private var metaDetails = false
    @FocusState private var codeFocused: Bool

    /// Hands the fields to the sign-in and clears them at once (the password is never kept here).
    private func startMetaLogin() {
        let meta = app.meta
        guard !meta.running else { return }
        if metaEmail.isEmpty || metaPassword.isEmpty { metaDetails = true }
        meta.startLogin(email: metaEmail, password: metaPassword)
        metaEmail = ""
        metaPassword = ""
        metaCode = ""
    }

    private func submitMetaCode() {
        guard MetaPrompt.isValidCode(metaCode) else { return }
        app.meta.submitCode(metaCode)
        metaCode = ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: L("Cuentas", "Accounts"),
                             subtitle: L("Inicia sesión en este Mac y envía el token al visor.",
                                         "Sign in on this Mac, then send the token to the headset."))
                steamBox
                metaBox
            }
            .padding(20)
        }
        .task {
            await app.meta.refresh()
            if app.steam.signedIn, app.steam.personaName == nil { await app.steam.fetchPersona() }
        }
    }

    private var steamBox: some View {
        let steam = app.steam
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if steam.signedIn {
                        Badge(text: steam.personaName.map { "Steam: \($0) ✓" } ?? L("Steam ✓ conectado", "Steam ✓ signed in"), color: .green)
                    } else {
                        Badge(text: L("Sin sesión", "Signed out"), color: .secondary)
                    }
                    Spacer()
                    Button(L("Comprobar sesión", "Check session")) { Task { await steam.checkSession() } }
                        .disabled(!steam.signedIn)
                    Button(L("Enviar al visor", "Send to headset")) { Task { await steam.sendToHeadset() } }
                        .disabled(!steam.signedIn)
                    Button(L("Cerrar sesión", "Sign out"), role: .destructive) { steam.signOut() }
                        .disabled(!steam.signedIn)
                }
                if !steam.signedIn || steam.busy {
                Divider()
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("Con código QR", "With a QR code")).font(.headline)
                        Button(steam.busy && steam.qr != nil ? L("Esperando…", "Waiting…") : L("Mostrar QR", "Show QR")) { steam.startQR() }
                            .disabled(steam.busy)
                        if let qr = steam.qr {
                            Image(nsImage: qr).interpolation(.none).resizable().frame(width: 200, height: 200)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("Con contraseña", "With a password")).font(.headline)
                        TextField(L("Usuario de Steam", "Steam account name"), text: $steamUser)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                        SecureField(L("Contraseña", "Password"), text: $steamPassword)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                        Button(L("Iniciar sesión", "Sign in")) {
                            steam.startPassword(user: steamUser, password: steamPassword)
                            steamPassword = ""
                        }
                        .disabled(steam.busy || steamUser.isEmpty || steamPassword.isEmpty)
                        if let t = steam.guardType {
                            HStack {
                                TextField("Steam Guard (\(t.description))", text: $steamCode)
                                    .textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                                Button(L("Enviar código", "Submit code")) { steam.submitCode(steamCode); steamCode = "" }
                            }
                        }
                    }
                }
                }
                HStack {
                    if steam.busy { ProgressView().controlSize(.small) }
                    Text(steam.message).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    if steam.busy { Button(L("Cancelar", "Cancel")) { steam.cancel() } }
                }
            }
            .padding(8)
        } label: {
            Label("Steam", systemImage: "gamecontroller")
        }
    }

    private var metaBox: some View {
        let meta = app.meta
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if meta.signedIn {
                        Badge(text: L("Meta ✓ conectado", "Meta ✓ signed in"), color: .green)
                    } else {
                        Badge(text: L("Sin sesión", "Signed out"), color: .secondary)
                    }
                    Spacer()
                    Button(L("Comprobar sesión", "Check session")) { Task { await meta.whoami() } }.disabled(!meta.signedIn)
                    Button(L("Enviar al visor", "Send to headset")) { Task { await meta.sendToHeadset() } }
                        .disabled(!meta.signedIn)
                    Button(L("Cerrar sesión", "Sign out"), role: .destructive) { Task { await meta.signOut() } }
                        .disabled(!meta.signedIn)
                }
                Text(L("Usa la herramienta oficial de Meta (ovr-platform-util, ruta en Ajustes). El e-mail, la contraseña y el código van solo a ella.",
                       "Uses Meta's own tool (ovr-platform-util, path in Settings). E-mail, password and code go only to it."))
                    .font(.callout).foregroundStyle(.secondary)
                if !meta.signedIn || meta.running || meta.canRetryCode { metaToolBox(meta.toolSetup) }
                if !meta.signedIn && !meta.running && !meta.canRetryCode {
                    VStack(alignment: .leading, spacing: 8) {
                        // No autocorrection / text replacement / completion: the field editor
                        // would otherwise be free to change what reaches Meta.
                        TextField(L("E-mail de Meta", "Meta e-mail"), text: $metaEmail)
                            .textContentType(.username)
                            .autocorrectionDisabled(true)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                        SecureField(L("Contraseña", "Password"), text: $metaPassword)
                            .textContentType(.password)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                            .onSubmit { startMetaLogin() }
                    }
                }
                // Signed in: Check / Send to headset / Sign out above are the controls; the
                // sign-in row only comes back while a login runs or a code can be retried.
                if !meta.signedIn || meta.running || meta.canRetryCode {
                    HStack {
                        Button(meta.running ? L("En curso…", "Running…") : L("Iniciar sesión con Meta", "Sign in with Meta")) { startMetaLogin() }
                            .disabled(meta.running)
                        if meta.running || meta.canRetryCode { Button(L("Cancelar", "Cancel")) { meta.cancelLogin(); metaCode = "" } }
                        if !meta.running && !meta.canRetryCode && (metaEmail.isEmpty || metaPassword.isEmpty) {
                            Text(L("Sin e-mail/contraseña: responde en Detalles.", "Without e-mail/password: answer in Details."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if meta.running || meta.awaitingCode || meta.canRetryCode {
                    HStack {
                        TextField(L("Código (6–8 dígitos)", "Code (6–8 digits)"), text: $metaCode)
                            .textContentType(.oneTimeCode)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                            .focused($codeFocused)
                            .onChange(of: metaCode) { _, v in
                                let d = String(v.filter(\.isNumber).prefix(8))
                                if d != v { metaCode = d }
                            }
                            .onSubmit { submitMetaCode() }
                        Button(meta.canRetryCode ? L("Reintentar con este código", "Retry with this code") : L("Enviar código", "Submit code")) {
                            submitMetaCode()
                        }
                        .disabled(!MetaPrompt.isValidCode(metaCode))
                    }
                    .onAppear { codeFocused = true }
                }
                if meta.running || !meta.terminal.isEmpty {
                    DisclosureGroup(L("Detalles (consola de la herramienta)", "Details (tool console)"), isExpanded: Binding(
                        get: { metaDetails || meta.unexpectedPrompt }, set: { metaDetails = $0 })) {
                        ScrollView {
                            Text(meta.terminal)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(6)
                        }
                        .frame(height: 160)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        HStack {
                            Toggle(L("Ocultar", "Hide"), isOn: $metaSecret).toggleStyle(.checkbox)
                            Group {
                                if metaSecret {
                                    SecureField(L("Respuesta para la herramienta", "Answer for the tool"), text: $metaLine)
                                } else {
                                    TextField(L("Respuesta para la herramienta", "Answer for the tool"), text: $metaLine)
                                        .autocorrectionDisabled(true)
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { meta.send(metaLine); metaLine = "" }
                            Button(L("Enviar", "Send")) { meta.send(metaLine); metaLine = "" }.disabled(!meta.running)
                        }
                    }
                }
                if !meta.message.isEmpty {
                    Text(meta.message).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(8)
            .task { await meta.toolSetup.checkTool() }
        } label: {
            Label("Meta", systemImage: "visionpro")
        }
    }

    /// Getting Meta's ovr-platform-util: open Meta's page, pick the download up, verify, install.
    @ViewBuilder
    private func metaToolBox(_ setup: MetaToolSetup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if setup.toolReady {
                    Badge(text: AppSettings.bundledMetaTool != nil
                          ? L("Herramienta incluida en la app (firmada por Meta)", "Tool bundled in the app (signed by Meta)")
                          : L("Herramienta lista (firmada por Meta)", "Tool ready (signed by Meta)"), color: .green)
                } else {
                    Badge(text: L("Falta la herramienta de Meta", "Meta's tool missing"), color: .orange)
                }
                Spacer()
                if setup.watching || setup.busy { ProgressView().controlSize(.small) }
                Button(L("Descargar herramienta de Meta", "Get Meta's tool")) { setup.getTool() }
                    .disabled(setup.busy)
                Button(L("Buscar en Descargas", "Look in Downloads")) { setup.lookNow() }
                    .disabled(setup.busy)
                if setup.watching { Button(L("Dejar de vigilar", "Stop watching")) { setup.stopWatching() } }
            }
            if !setup.toolReady && setup.note.isEmpty {
                Text(L("Meta solo la da en su web: «Descargar herramienta de Meta» abre la página; descarga la versión de macOS y se recoge sola de Descargas, se verifica la firma de Meta y se instala aquí.",
                       "Meta only hands it out on its site: “Get Meta's tool” opens the page; download the macOS version and it is picked up from Downloads, Meta's signature checked, and installed here."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !setup.note.isEmpty {
                Text(setup.note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if setup.needsRosetta {
                HStack {
                    Text(L("Es solo para Intel y falta Rosetta:", "It is Intel-only and Rosetta is missing:")).font(.callout)
                    Text(MetaToolFiles.rosettaCommand).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Button(L("Copiar", "Copy")) { setup.copyRosettaCommand() }
                    Button(L("Instalar Rosetta (acepta la licencia de Apple)", "Install Rosetta (accepts Apple's licence)")) { setup.installRosetta() }
                        .disabled(setup.rosettaInstalling)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}
