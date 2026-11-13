#if os(iOS)
#if canImport(UIKit)
import SwiftUI
import CoreImage.CIFilterBuiltins

public struct QRCodeView: View {
    public let content: String
    public let size: CGFloat

    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    public init(content: String, size: CGFloat = 200) {
        self.content = content
        self.size = size
    }

    public var body: some View {
        if let image = generateQRCode(from: content) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .padding(12)
                .background(Color.white)
                .cornerRadius(12)
                .shadow(radius: 2)
                .accessibilityLabel("Enrollment QR code")
                .accessibilityHint("Scan on another device to add it to this relay")
        } else {
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: size, height: size)
        }
    }

    private func generateQRCode(from string: String) -> UIImage? {
        guard let data = string.data(using: .utf8) else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }
        let scale = size / outputImage.extent.size.width
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        if let cgImage = context.createCGImage(transformed, from: transformed.extent) {
            return UIImage(cgImage: cgImage)
        }
        return nil
    }
}
#endif


#endif
