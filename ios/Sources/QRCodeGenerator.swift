//
//  QRCodeGenerator.swift
//  YTAudioPlayer
//
//  QR code generation utility
//

import UIKit
import CoreImage.CIFilterBuiltins

class QRCodeGenerator {

    /// Generates a QR code image from a string
    static func generate(from string: String, size: CGFloat = 250) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()

        guard let data = string.data(using: .utf8) else {
            return nil
        }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")  // High error correction

        guard let outputImage = filter.outputImage else {
            return nil
        }

        // Scale up the image
        let scaleX = size / outputImage.extent.size.width
        let scaleY = size / outputImage.extent.size.height
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}
