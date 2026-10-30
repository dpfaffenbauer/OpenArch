import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

public enum QRCode {
    /// A QR code of |text|, sharp at |scale| pixels per module; nil when the
    /// text is too long for one (about 2300 bytes).
    public static func image(for text: String, scale: CGFloat = 12) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else {
            return nil
        }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
