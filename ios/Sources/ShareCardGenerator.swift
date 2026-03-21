//
//  ShareCardGenerator.swift
//  YTAudioPlayer
//
//  Generates shareable image cards for tracks
//

import UIKit

class ShareCardGenerator {

    /// Generates a shareable card image for a track asynchronously
    /// This avoids blocking the main thread with network requests and heavy image processing
    static func generateCard(for track: Track) async -> UIImage? {
        return await Task.detached(priority: .userInitiated) {
            let size = CGSize(width: 1080, height: 1920)  // Instagram story size
            UIGraphicsBeginImageContextWithOptions(size, false, 0)

            guard let context = UIGraphicsGetCurrentContext() else {
                return nil
            }

            // Draw gradient background
            let gradientColors = [
                UIColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 1.0).cgColor,
                UIColor(red: 0.2, green: 0.1, blue: 0.3, alpha: 1.0).cgColor
            ]
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: gradientColors as CFArray,
                locations: [0, 1]
            )
            context.drawLinearGradient(
                gradient!,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )

            // Try to load and draw artwork asynchronously
            if let artworkURL = track.artworkURL,
               let artworkData = try? Data(contentsOf: artworkURL),
               let artwork = UIImage(data: artworkData) {

                // Draw blurred artwork background
                let blurRadius: CGFloat = 30
                let blurredArtwork = artwork.blurred(radius: blurRadius)
                blurredArtwork?.draw(in: CGRect(x: 0, y: 0, width: size.width, height: size.height))

                // Draw dark overlay
                UIColor.black.withAlphaComponent(0.4).setFill()
                context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))

                // Draw main artwork
                let artworkSize: CGFloat = 600
                let artworkRect = CGRect(
                    x: (size.width - artworkSize) / 2,
                    y: 400,
                    width: artworkSize,
                    height: artworkSize
                )

                // Shadow
                context.setShadow(offset: CGSize(width: 0, height: 20), blur: 40, color: UIColor.black.cgColor)
                artwork.draw(in: artworkRect)
                context.setShadow(offset: .zero, blur: 0, color: nil)

                // Rounded corners for artwork
                context.addPath(UIBezierPath(roundedRect: artworkRect, cornerRadius: 20).cgPath)
                context.clip()
                artwork.draw(in: artworkRect)
                context.resetClip()
            }

            // Draw text
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 64, weight: .bold),
                .foregroundColor: UIColor.white
            ]

            let artistAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 40, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.8)
            ]

            let appAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 28, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.6)
            ]

            // Title
            let titleRect = CGRect(x: 60, y: 1100, width: size.width - 120, height: 100)
            let titleText = track.title as NSString
            titleText.draw(in: titleRect, withAttributes: titleAttributes)

            // Artist
            let artistRect = CGRect(x: 60, y: 1220, width: size.width - 120, height: 60)
            let artistText = track.displayArtist as NSString
            artistText.draw(in: artistRect, withAttributes: artistAttributes)

            // App branding
            let appRect = CGRect(x: 60, y: size.height - 120, width: size.width - 120, height: 40)
            let appText = "Shared from YTAudio" as NSString
            appText.draw(in: appRect, withAttributes: appAttributes)

            // Draw logo/icon
            let iconRect = CGRect(x: size.width - 140, y: size.height - 130, width: 60, height: 60)
            if let icon = UIImage(systemName: "play.circle.fill")?.withTintColor(.white) {
                icon.draw(in: iconRect)
            }

            let image = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()

            return image
        }.value
    }
}

// MARK: - UIImage Extensions

private extension UIImage {
    func blurred(radius: CGFloat) -> UIImage? {
        let context = CIContext(options: nil)
        guard let currentFilter = CIFilter(name: "CIGaussianBlur") else { return nil }

        let beginImage = CIImage(image: self)
        currentFilter.setValue(beginImage, forKey: kCIInputImageKey)
        currentFilter.setValue(radius, forKey: kCIInputRadiusKey)

        guard let output = currentFilter.outputImage,
              let cgimg = context.createCGImage(output, from: output.extent) else {
            return nil
        }

        return UIImage(cgImage: cgimg)
    }
}
