import AppKit
import HubCore
import MetaStore
import Observation

/// "Get Meta's tool": opens Meta's page in the browser (the user downloads there, on Meta's
/// terms — this app never fetches or ships the tool), then watches ~/Downloads and the
/// configured downloads folder for ovr-platform-util or a zip holding it. A found file is
/// unpacked if needed, its signature checked (Meta, team HXH6UQBHD4 — anything else is refused),
/// copied into this app's data folder, un-quarantined, made executable, checked again and set
/// as settings.metaToolPath. If it is Intel-only and Rosetta is missing, that is said, with the
/// install command; Rosetta is installed only when the user clicks.
@MainActor @Observable
final class MetaToolSetup {
    let settings: AppSettings
    var watching = false
    var busy = false
    var note = ""
    var needsRosetta = false
    var rosettaInstalling = false
    @ObservationIgnored private var watch: Task<Void, Never>?
    /// Files already tried and refused (path + mtime), so the watch loop doesn't repeat itself.
    @ObservationIgnored private var refused = Set<String>()

    nonisolated static var installedURL: URL {
        AppSettings.supportDir.appendingPathComponent("tools/\(MetaToolFiles.toolName)")
    }

    init(settings: AppSettings) {
        self.settings = settings
        refreshRosetta()
    }

    /// Whether the tool sign-in would run verifies as Meta's (updated by checkTool()).
    var toolReady = false

    func checkTool() async {
        let url = settings.metaToolURL
        toolReady = await Task.detached { (try? MetaTool(url: url).verify()) != nil }.value
        refreshRosetta()
    }

    func refreshRosetta() {
        let url = settings.metaToolURL
        needsRosetta = FileManager.default.fileExists(atPath: url.path)
            && MetaToolFiles.needsRosetta(url) && !MetaToolFiles.rosettaInstalled
    }

    private var folders: [URL] {
        var f = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)]
        let configured = settings.expanded(settings.downloadsPath)
        if configured.standardizedFileURL != f[0].standardizedFileURL { f.append(configured) }
        return f
    }

    /// Opens Meta's page and watches the downloads folders for up to 15 minutes.
    func getTool() {
        NSWorkspace.shared.open(MetaToolFiles.downloadPage)
        note = L("Descarga la versión de macOS en la página de Meta. Se recogerá sola de Descargas en cuanto esté.",
                 "Download the macOS version on Meta's page. It will be picked up from Downloads as soon as it lands.")
        refused.removeAll()
        watch?.cancel()
        watching = true
        watch = Task { [weak self] in
            for _ in 0..<450 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                if await self.adoptFromDownloads(quiet: true) { break }
            }
            guard let self, !Task.isCancelled else { return }
            if self.watching {
                self.watching = false
                self.note = L("Dejé de vigilar Descargas (15 min). Pulsa «Buscar en Descargas» cuando lo tengas.",
                              "Stopped watching Downloads (15 min). Press “Look in Downloads” once you have it.")
            }
        }
    }

    func stopWatching() {
        watch?.cancel()
        watch = nil
        watching = false
    }

    /// Looks once, now, and says what was found.
    func lookNow() {
        refused.removeAll()
        Task { await adoptFromDownloads(quiet: false) }
    }

    @discardableResult
    private func adoptFromDownloads(quiet: Bool) async -> Bool {
        guard !busy else { return false }
        let folders = folders
        let all = await Task.detached { MetaToolFiles.candidates(in: folders) }.value
        let fresh = all.filter { !refused.contains(Self.key($0)) }
        guard !fresh.isEmpty else {
            if !quiet {
                note = all.isEmpty
                    ? L("Aún no hay ningún «ovr-platform-util» (ni zip) en \(folders.map(\.path).joined(separator: " ni ")). Si macOS pidió permiso para Descargas, acéptalo.",
                        "No “ovr-platform-util” (or zip) in \(folders.map(\.path).joined(separator: " or ")) yet. If macOS asked for access to Downloads, allow it.")
                    : L("Los ficheros encontrados ya se rechazaron (ver arriba).", "The files found were already refused (see above).")
            }
            return false
        }
        busy = true
        defer { busy = false }
        note = L("Comprobando \(fresh[0].lastPathComponent)…", "Checking \(fresh[0].lastPathComponent)…")
        var problems: [String] = []
        for file in fresh {
            let result = await Task.detached { Result { try MetaToolSetup.install(from: file) } }.value
            switch result {
            case .success(let tool):
                finish(installed: tool)
                return true
            case .failure(let e):
                refused.insert(Self.key(file))
                problems.append("\(file.lastPathComponent): \(e)")
            }
        }
        note = L("No se instaló nada. ", "Nothing installed. ") + problems.joined(separator: "\n")
        return false
    }

    private func finish(installed tool: URL) {
        stopWatching()
        settings.metaToolPath = tool.path
        toolReady = true
        refreshRosetta()
        note = needsRosetta
            ? L("Herramienta de Meta instalada y verificada (\(MetaTool.expectedTeam)). Es solo para Intel: falta Rosetta (abajo).",
                "Meta's tool installed and verified (\(MetaTool.expectedTeam)). It is Intel-only: Rosetta is missing (below).")
            : L("Herramienta de Meta instalada y verificada (\(MetaTool.expectedTeam)) en \(tool.path). Ya puedes iniciar sesión.",
                "Meta's tool installed and verified (\(MetaTool.expectedTeam)) at \(tool.path). You can sign in now.")
    }

    /// Unpacks (if zip), checks Meta's signature on the source, then installs a private copy:
    /// quarantine removed, 0755, signature + executability checked again on the copy.
    nonisolated static func install(from source: URL, to destination: URL = installedURL) throws -> URL {
        let fm = FileManager.default
        var tool = source
        var scratch: URL?
        defer { if let scratch { try? fm.removeItem(at: scratch) } }
        if MetaToolFiles.isZip(source) {
            let dir = fm.temporaryDirectory.appendingPathComponent("avpgamehub-metatool-\(UUID().uuidString)", isDirectory: true)
            scratch = dir
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard run("/usr/bin/ditto", ["-x", "-k", source.path, dir.path]) == 0 else {
                throw HubError(L("no se pudo descomprimir", "could not unzip"))
            }
            guard let inner = MetaToolFiles.toolInside(dir) else {
                throw HubError(L("el zip no contiene «\(MetaToolFiles.toolName)»", "the zip has no “\(MetaToolFiles.toolName)” in it"))
            }
            tool = inner
        }
        // Refuse before anything is copied or made executable.
        try MetaTool(url: tool).verifySignature()

        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fresh = destination.appendingPathExtension("new")
        try? fm.removeItem(at: fresh)
        try fm.copyItem(at: tool, to: fresh)
        _ = run("/usr/bin/xattr", ["-d", "com.apple.quarantine", fresh.path])   // absent is fine
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fresh.path)
        do {
            try MetaTool(url: fresh).verify()
        } catch {
            try? fm.removeItem(at: fresh)
            throw error
        }
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: fresh, to: destination)
        return destination
    }

    nonisolated private static func run(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    private static func key(_ url: URL) -> String {
        let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.path)#\(m)"
    }

    // MARK: Rosetta

    func copyRosettaCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MetaToolFiles.rosettaCommand, forType: .string)
        note = L("Comando copiado. Pégalo en Terminal.", "Command copied. Paste it into Terminal.")
    }

    /// Runs Apple's own Rosetta install (no admin password). Only on the user's click; clicking
    /// accepts Apple's Rosetta licence, as the button says.
    func installRosetta() {
        guard !rosettaInstalling else { return }
        rosettaInstalling = true
        note = L("macOS está instalando Rosetta…", "macOS is installing Rosetta…")
        Task {
            let r = await ProcessRunner.capture(ShellCommand("/usr/sbin/softwareupdate", ["--install-rosetta", "--agree-to-license"]),
                                                timeout: 900)
            rosettaInstalling = false
            refreshRosetta()
            let last = r.output.split(separator: "\n").last.map(String.init) ?? ""
            note = (r.status == 0 && MetaToolFiles.rosettaInstalled)
                ? L("Rosetta instalado. Ya puedes iniciar sesión en Meta.", "Rosetta is installed. You can sign in to Meta now.")
                : L("No se pudo instalar Rosetta (\(last)). En Terminal: \(MetaToolFiles.rosettaCommand)",
                    "Rosetta could not be installed (\(last)). In Terminal: \(MetaToolFiles.rosettaCommand)")
        }
    }
}
