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
        print("✅ Notification attachment format regressions passed")
    }
}
