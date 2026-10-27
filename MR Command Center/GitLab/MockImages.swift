import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A generated PNG for image files in mock mode: a soft gradient card, so previews have
/// something real to decode and measure.
nonisolated enum MockImages {
    static let size = (width: 480, height: 300)

    static func png(width: Int, height: Int) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        let colors = [CGColor(red: 0.98, green: 0.82, blue: 0.62, alpha: 1), CGColor(red: 0.55, green: 0.42, blue: 0.85, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
        context.fillEllipse(in: CGRect(x: width / 2 - 50, y: height / 2 - 50, width: 100, height: 100))
        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
