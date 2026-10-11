import AppKit
import CoreImage
import HubCore
import SwiftUI

/// Small headset operations shared by several screens.
enum DeviceOps {
    static func devices() async -> [DeviceInfo] {
        let json = FileManager.default.temporaryDirectory.appendingPathComponent("avpgamehub-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: json) }
        _ = await ProcessRunner.capture(.devicectl(DeviceCtl.listDevicesArgs(jsonOutput: json.path)), timeout: 30)
        guard let data = try? Data(contentsOf: json) else { return [] }
        return DeviceCtl.parseDevices(data)
    }

    /// Copies `data` into the hub's container as Documents/<fileName> (one-time import files: the
    /// hub moves tokens into its Keychain and deletes the file). The temporary copy on this Mac is
    /// private (0700 dir, 0600 file) and removed right after.
    static func copyToHeadsetDocuments(_ data: Data, fileName: String, device: String, bundle: String) async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("avpgamehub-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent(fileName)
        fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try data.write(to: file)
        let r = await ProcessRunner.capture(.devicectl(DeviceCtl.copyToArgs(device: device, bundle: bundle,
                                                                            source: file.path, destination: "Documents/\(fileName)")),
                                            timeout: 120)
        guard r.status == 0 else {
            throw HubError("devicectl \(r.status): " + (r.output.split(separator: "\n").suffix(3).joined(separator: " ")))
        }
    }
}

enum QRImage {
    /// A crisp QR code with a white quiet zone.
    static func make(_ string: String, scale: CGFloat = 8) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let img = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        let margin = 4 * scale
        let canvas = CGRect(x: 0, y: 0, width: img.extent.width + 2 * margin, height: img.extent.height + 2 * margin)
        let padded = img.transformed(by: CGAffineTransform(translationX: margin, y: margin))
            .composited(over: CIImage(color: .white).cropped(to: canvas))
        guard let cg = CIContext().createCGImage(padded, from: canvas) else { return nil }
        return NSImage(cgImage: cg, size: canvas.size)
    }
}

enum CheckState {
    case ok, warn, fail, checking, info

    var icon: some View {
        Group {
            switch self {
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .fail: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .checking: ProgressView().controlSize(.small)
            case .info: Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
        }
        .frame(width: 18)
    }
}

struct Badge: View {
    let text: String
    var color: Color = .accentColor
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// A screen title with an optional subtitle.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.bold())
                if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing()
        }
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = { EmptyView() }
    }
}

func formatBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .binary)
}
