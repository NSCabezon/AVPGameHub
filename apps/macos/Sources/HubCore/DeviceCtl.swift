import Foundation

public struct DeviceInfo: Identifiable, Hashable, Sendable {
    public var id: String          // devicectl identifier
    public var name: String
    public var platform: String
    public var reality: String     // "physical" | "virtual"
    public var tunnelState: String // "connected", "disconnected", "unavailable"…
    public var model: String

    public var isVisionPro: Bool { platform == "visionOS" && reality == "physical" }
    public var isConnected: Bool { tunnelState == "connected" }
}

/// Argument lists for `xcrun devicectl …` (run with ShellCommand.devicectl).
public enum DeviceCtl {
    public static func listDevicesArgs(jsonOutput: String) -> [String] {
        ["list", "devices", "--json-output", jsonOutput]
    }

    /// Devices from `devicectl list devices --json-output` (result.devices[]).
    public static func parseDevices(_ data: Data) -> [DeviceInfo] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]] else { return [] }
        return devices.compactMap { d in
            guard let id = d["identifier"] as? String else { return nil }
            let hw = d["hardwareProperties"] as? [String: Any] ?? [:]
            let conn = d["connectionProperties"] as? [String: Any] ?? [:]
            let props = d["deviceProperties"] as? [String: Any] ?? [:]
            return DeviceInfo(id: id,
                              name: props["name"] as? String ?? hw["marketingName"] as? String ?? id,
                              platform: hw["platform"] as? String ?? "",
                              reality: hw["reality"] as? String ?? "",
                              tunnelState: conn["tunnelState"] as? String ?? "",
                              model: hw["marketingName"] as? String ?? hw["productType"] as? String ?? "")
        }
    }

    /// The device a run should use: the configured one if listed, else the first physical Vision
    /// Pro (connected first) — the same rule as build_run_vpro.sh's find_device.
    public static func pick(_ devices: [DeviceInfo], preferred: String?) -> DeviceInfo? {
        if let p = preferred, !p.isEmpty, let d = devices.first(where: { $0.id == p }) { return d }
        return devices.filter(\.isVisionPro).sorted { $0.isConnected && !$1.isConnected }.first
    }

    /// Environment for the app as devicectl's --environment-variables JSON (sorted keys).
    public static func environmentJSON(_ env: [String: String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: env, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Launch the app; with `console`, devicectl stays attached and streams the app's stdout/stderr
    /// (stopping devicectl then quits the app: signals are forwarded).
    public static func launchArgs(device: String, bundle: String, environment: [String: String], console: Bool) -> [String] {
        var a = ["device", "process", "launch", "--device", device, "--terminate-existing"]
        if console { a.append("--console") }
        if !environment.isEmpty { a += ["--environment-variables", environmentJSON(environment)] }
        a.append(bundle)
        return a
    }

    public static func copyToArgs(device: String, bundle: String, source: String, destination: String) -> [String] {
        ["device", "copy", "to", "--device", device, "--domain-type", "appDataContainer",
         "--domain-identifier", bundle, "--source", source, "--destination", destination]
    }

    public static func copyFromArgs(device: String, bundle: String, source: String, destination: String) -> [String] {
        ["device", "copy", "from", "--device", device, "--domain-type", "appDataContainer",
         "--domain-identifier", bundle, "--source", source, "--destination", destination]
    }

    public static func listFilesArgs(device: String, bundle: String, subdirectory: String, jsonOutput: String) -> [String] {
        ["device", "info", "files", "--device", device, "--domain-type", "appDataContainer",
         "--domain-identifier", bundle, "--subdirectory", subdirectory, "--json-output", jsonOutput]
    }

    /// Where the hub keeps its session stats inside its data container.
    public static let sessionsSubdirectory = "Library/Application Support/sessions"
}
