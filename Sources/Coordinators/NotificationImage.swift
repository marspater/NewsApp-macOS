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

/// The dissolving photo crop of the app-drawn banner (#589, #906, #920).
extension NotificationService {
    /// The centred crop of `image` at `aspect` (width over height), at most `maxWidth` px wide, sharp and opaque at its
    /// trailing edge and dissolving toward its leading edge, where the banner's text sits.
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
        // The trailing edge stays sharp and opaque, at the banner's side. Toward
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
