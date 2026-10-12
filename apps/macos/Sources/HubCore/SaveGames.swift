import Foundation
@_exported import SaveKit

// The Mac side of save games: devicectl JSON parsing and commands. The save table (SaveTable),
// the backup format (SaveManifest) and the Mac backup store (SaveBackupStore) live in SaveKit
// (packages/SaveKit) so the headset hub shares them; see docs/2026-10-12-save-games.md.

// MARK: - devicectl JSON

public enum DeviceJSON {
    /// `devicectl device info files --json-output` → container-relative files. nil when the
    /// result carries an error or no file list (e.g. the subdirectory does not exist).
    public static func files(_ data: Data, subdirectory: String) -> [RemoteFile]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["error"] == nil,
              let result = root["result"] as? [String: Any],
              let files = result["files"] as? [[String: Any]] else { return nil }
        let base = subdirectory.hasSuffix("/") ? String(subdirectory.dropLast()) : subdirectory
        return files.compactMap { f in
            guard let rel = (f["relativePath"] as? String) ?? (f["name"] as? String), !rel.isEmpty else { return nil }
            let meta = f["metadata"] as? [String: Any] ?? [:]
            let res = f["resources"] as? [String: Any] ?? [:]
            let size = (meta["size"] as? NSNumber)?.int64Value ?? 0
            return RemoteFile(path: base.isEmpty ? rel : base + "/" + rel, size: size,
                              isDirectory: res["isDirectory"] as? Bool ?? false,
                              isSymbolicLink: res["isSymbolicLink"] as? Bool ?? false)
        }
    }

    /// `devicectl device info apps --bundle-id X --json-output` → the app's bundle URL, if installed.
    public static func appURL(_ data: Data, bundle: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let apps = result["apps"] as? [[String: Any]] else { return nil }
        return apps.first { $0["bundleIdentifier"] as? String == bundle }?["url"] as? String
    }

    /// `devicectl device info processes --json-output` → executable URLs. nil if unreadable.
    public static func processExecutables(_ data: Data) -> [String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let procs = result["runningProcesses"] as? [[String: Any]] else { return nil }
        return procs.compactMap { $0["executable"] as? String }
    }

    /// Some process runs out of the app bundle at `appURL`.
    public static func isRunning(appURL: String, executables: [String]) -> Bool {
        let base = appURL.hasSuffix("/") ? appURL : appURL + "/"
        return executables.contains { $0.hasPrefix(base) }
    }
}

public extension DeviceCtl {
    static func appInfoArgs(device: String, bundle: String, jsonOutput: String) -> [String] {
        ["device", "info", "apps", "--device", device, "--bundle-id", bundle, "--json-output", jsonOutput]
    }
    static func processesArgs(device: String, jsonOutput: String) -> [String] {
        ["device", "info", "processes", "--device", device, "--json-output", jsonOutput]
    }
}
