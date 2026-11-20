//
//  QRCodeView.swift
//  SSSBLaundry
//

import CoreImage.CIFilterBuiltins
import SwiftUI

/// A link as a QR code, for handing it to someone standing next to you.
///
/// Always dark modules on white, in light and dark mode alike: camera apps read
/// inverted codes unreliably, and the white square doubles as the quiet zone.
struct QRCodeView: View {
    let url: URL

    var body: some View {
        Group {
            if let image = Self.image(for: url) {
                // One pixel per module, scaled up without smoothing so every
                // module edge stays sharp at any size.
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            }
        }
        .padding(12)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement()
        .accessibilityLabel("QR code of the invite link")
    }

    private static let context = CIContext()

    private static func image(for url: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent)
    }
}

#Preview {
    QRCodeView(url: InviteLink.url(objectId: "1234-5678-901"))
        .frame(width: 200)
}
