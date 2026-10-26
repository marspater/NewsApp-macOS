import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum NotificationAttachmentTests {
    static func run() {
        // Valid 1x1 WebP: accepted by ImageIO, rejected when attached directly as .webp (UNErrorDomain 101).
        let webp = Data(base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA")!
        do {
            let attachment = try NotificationService.makeImageAttachment(data: webp)
            precondition(attachment.type == UTType.png.identifier, "Unsupported WebP must become a supported PNG")
            let png = try Data(contentsOf: attachment.url)
            let source = CGImageSourceCreateWithData(png as CFData, nil)
            precondition(source != nil, "The framework-owned attachment must remain readable")
            precondition(
                CGImageSourceGetType(source!) as String? == UTType.png.identifier, "Attachment bytes must be PNG")
            let second = try NotificationService.makeImageAttachment(data: png)
            precondition(second.type == UTType.png.identifier, "Existing PNG images remain supported")
        } catch { fatalError("Notification image conversion failed: \(error)") }
        do {
            _ = try NotificationService.makeImageAttachment(data: Data("not an image".utf8))
            fatalError("Malformed images must not become notification attachments")
        } catch {}

        // The tall fading crop (#589): a 1200 × 1200 source becomes a 600 × 900 portrait PNG with alpha,
        // opaque on the leading side and transparent at the trailing edge; the same input renders the same bytes,
        // and a small source keeps its own size.
        func png(width: Int, height: Int) -> Data {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(srgbRed: 0.9, green: 0.3, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
            let image = context.makeImage()!
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            precondition(CGImageDestinationFinalize(destination))
            return data as Data
        }
        func alpha(_ image: CGImage, x: Int, y: Int) -> UInt8 {
            let data = image.dataProvider!.data! as Data
            let bytesPerPixel = image.bitsPerPixel / 8
            let offset = y * image.bytesPerRow + x * bytesPerPixel
            let alphaFirst = [.premultipliedFirst, .first].contains(image.alphaInfo)
            return data[offset + (alphaFirst ? 0 : bytesPerPixel - 1)]
        }
        do {
            let landscape = png(width: 1200, height: 1200)
            let tall = try NotificationService.makeImageAttachment(data: landscape)
            let bytes = try Data(contentsOf: tall.url)
            precondition(bytes.count <= 10_000_000, "Attachment stays within the notification size limit")
            let source = CGImageSourceCreateWithData(bytes as CFData, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            precondition(
                image.width == 600 && image.height == 900,
                "Tall crop is 600 × 900, got \(image.width) × \(image.height)")
            precondition(
                image.alphaInfo != .none && image.alphaInfo != .noneSkipLast && image.alphaInfo != .noneSkipFirst,
                "Crop carries alpha")
            precondition(alpha(image, x: 20, y: 450) == 255, "Leading side is opaque")
            precondition(alpha(image, x: 598, y: 450) < 16, "Trailing edge fades to transparent")
            let again = try Data(contentsOf: try NotificationService.makeImageAttachment(data: landscape).url)
            precondition(again == bytes, "The same source renders the same bytes")
            let small = try NotificationService.makeImageAttachment(data: png(width: 200, height: 200))
            let smallSource = CGImageSourceCreateWithData(try Data(contentsOf: small.url) as CFData, nil)!
            let smallImage = CGImageSourceCreateImageAtIndex(smallSource, 0, nil)!
            precondition(smallImage.width == 200 && smallImage.height == 200, "Small sources keep their size")
        } catch { fatalError("Notification image crop failed: \(error)") }
        print("✅ Notification attachment format regressions passed")
    }
}
