import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum QRCode {
    /// Render `string` as a QR code PNG (scaled up, crisp pixels) at `path`.
    static func writePNG(_ string: String, to path: String, scale: CGFloat = 12) throws {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw CLIError("CIQRCodeGenerator unavailable") }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let img = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else {
            throw CLIError("QR generation failed")
        }
        // Add a 4-module white quiet zone; many scanners need it.
        let margin = 4 * scale
        let canvas = CGRect(x: 0, y: 0, width: img.extent.width + 2 * margin, height: img.extent.height + 2 * margin)
        let padded = img.transformed(by: CGAffineTransform(translationX: margin, y: margin))
            .composited(over: CIImage(color: .white).cropped(to: canvas))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(padded, from: canvas) else { throw CLIError("QR render failed") }
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CLIError("cannot write \(path)")
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw CLIError("cannot write \(path)") }
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}
