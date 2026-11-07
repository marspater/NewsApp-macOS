// Copyright 2026 Mars Pater
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import NewsCore
import UniformTypeIdentifiers
import UserNotifications

/// The notification image: the attachment PNG the system thumbnail shows and the dissolving crop the app-drawn banner
/// shares (#589, #906, #920).
extension NotificationService {
    /// Notification attachments do not support every format the protected reader can decode (notably WebP/AVIF).
    /// The attachment is the tall fading crop of `notificationImage`, or the decoded image when the source is small.
    /// Every failure is an `ImageLoadFailure` naming its stage with `contentType` and the byte count (#1010).
    static func makeImageAttachment(data: Data, contentType: String? = nil) throws -> UNNotificationAttachment {
        func failure(_ stage: ImageLoadFailure.Stage, _ error: Error? = nil) -> ImageLoadFailure {
            ImageLoadFailure(
                stage: stage, contentType: contentType, bytes: data.count, underlying: error.map { $0 as NSError })
        }
        let decoded: CGImage
        do { decoded = try SecureHTTPClient.decodeReaderImage(data) } catch { throw failure(.decode, error) }
        let image = notificationImage(decoded) ?? decoded
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)
        else { throw failure(.encode) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw failure(.encode) }
        guard encoded.length <= Self.attachmentLimit else { throw failure(.size) }
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        do {
            try (encoded as Data).write(to: fileURL)
            // The notification framework takes ownership after successful attachment creation.
            return try UNNotificationAttachment(identifier: UUID().uuidString, url: fileURL, options: nil)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw failure(.attach, error)
        }
    }

    /// Short side a source needs for the tall crop; smaller images stay as they are.
    static let notificationImageMinimumSide = 300
    /// Rendered width of the tall crop; the height is 1.5 times it.
    static let notificationImageWidth = 600

    /// A portrait crop (2:3) of the image, at most 600 × 900, sharp at its trailing edge, that blurs progressively and
    /// fades to transparent toward its leading edge, the banner's text (#589). macOS has no custom banner layout, so the effect is baked into the PNG the system
    /// places as the thumbnail. Rendered on the CPU, so the same input gives the same bytes. nil when the source's
    /// short side is under 300 px, when the square the system shows is the better choice.
    static func notificationImage(_ image: CGImage) -> CGImage? {
        guard min(image.width, image.height) >= notificationImageMinimumSide else { return nil }
        return dissolvingCrop(image, aspect: 2.0 / 3.0, maxWidth: notificationImageWidth)
    }

    /// The centred crop of `image` at `aspect` (width over height), at most `maxWidth` px wide, sharp and opaque at its
    /// trailing edge and dissolving toward its leading edge. The system thumbnail and the app-drawn banner share it.
    static func dissolvingCrop(_ image: CGImage, aspect: Double, maxWidth: Int) -> CGImage? {
        let width = Double(image.width)
        let height = Double(image.height)
        var cropWidth = width
        var cropHeight = height
        if cropWidth / cropHeight > aspect { cropWidth = cropHeight * aspect } else { cropHeight = cropWidth / aspect }
        let crop = CGRect(
            x: (width - cropWidth) / 2, y: (height - cropHeight) / 2, width: cropWidth, height: cropHeight
        ).integral
        guard let cropped = image.cropping(to: crop) else { return nil }
        let scale = min(1, Double(maxWidth) / Double(cropped.width))
        let source = CIImage(cgImage: cropped).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = source.extent.integral
        // The trailing edge stays sharp and opaque, where the system pins the thumbnail to the banner's side. Toward
        // the text the blur rises from nothing at 60% of the width to full at the leading edge; the fade starts at 45%.
        func ramp(over span: Double) -> CIImage? {
            let gradient = CIFilter.linearGradient()
            gradient.point0 = CGPoint(x: extent.minX + extent.width * span, y: extent.midY)
            gradient.point1 = CGPoint(x: extent.minX, y: extent.midY)
            gradient.color0 = .black
            gradient.color1 = .white
            return gradient.outputImage?.cropped(to: extent)
        }
        let blur = CIFilter.maskedVariableBlur()
        // Clamped so the blur samples edge pixels, not transparency, along the top and bottom.
        blur.inputImage = source.clampedToExtent()
        blur.mask = ramp(over: 0.6)
        blur.radius = 18
        let fade = CIFilter.blendWithMask()
        fade.inputImage = CIImage(color: .clear).cropped(to: extent)
        fade.backgroundImage = blur.outputImage?.cropped(to: extent)
        fade.maskImage = ramp(over: 0.45)
        guard let output = fade.outputImage?.cropped(to: extent) else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
        return context.createCGImage(
            output, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
