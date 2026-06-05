import Foundation
import UIKit

// AorusGram local badge system.
//
// Everything here is local to the client — nothing is sent to Telegram servers.
// Badges are derived purely from a hardcoded peer-id table, so every AorusGram
// user sees them while official Telegram shows nothing extra.
//
// Three kinds:
//   - verified  → handled natively: TelegramCore's `isVerified` is patched to
//                 return true for these channels/chats, so the genuine Telegram
//                 checkmark is shown (NOT rendered here).
//   - dev       → a hollow rounded-rect "DEV" tag (blue outline + blue text).
//   - meme      → a custom easter-egg cat icon for one friend-admin.
//
// `verified` IDs are intentionally NOT in the kind table below: they ride the
// native Telegram verified badge instead of a custom image.

public enum AorusBadgeKind: Equatable {
    case dev
    case meme
}

public enum AorusBadge {
    // Channels/chats that should show the NATIVE Telegram verified checkmark.
    // (Consumed by the TelegramCore isVerified patch, mirrored here for reference.)
    public static let verifiedPeerRawIds: Set<Int64> = [3956524111, 3710166840]

    // Users that get a custom local badge.
    private static let devUserRawIds: Set<Int64> = [6297603868, 6712335037]
    private static let memeUserRawIds: Set<Int64> = [8123825459]

    public static func kind(forPeerRawId id: Int64) -> AorusBadgeKind? {
        if memeUserRawIds.contains(id) { return .meme }
        if devUserRawIds.contains(id) { return .dev }
        return nil
    }

    // Toast text shown when the badge is tapped.
    public static func toastText(forPeerRawId id: Int64, peerName: String) -> String? {
        guard let kind = kind(forPeerRawId: id) else { return nil }
        switch kind {
        case .dev:
            return "Разработчик AorusGram"
        case .meme:
            return "\(peerName) является жопой AorusGram"
        }
    }

    // Badge image sized to `height` points (square box; DEV is wider than tall).
    // Rendered at screen scale. Returns nil if the peer has no custom badge.
    public static func image(forPeerRawId id: Int64, height: CGFloat, accent: UIColor) -> UIImage? {
        guard let kind = kind(forPeerRawId: id) else { return nil }
        switch kind {
        case .meme:
            return AorusBadgeAssets.cat
        case .dev:
            return devImage(height: height, accent: accent)
        }
    }

    // Hollow "DEV" tag: rounded-rect border (no fill) + "DEV" text, both in the
    // light-blue accent. Matches .nightAccent.
    private static func devImage(height: CGFloat, accent: UIColor) -> UIImage? {
        let h = max(12.0, height)
        let fontSize = floor(h * 0.62)
        let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        let text = "DEV" as NSString
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: accent]
        let textSize = text.size(withAttributes: textAttrs)
        let hInset = floor(h * 0.26)
        let lineWidth = max(1.0, floor(h * 0.09))
        let width = ceil(textSize.width + hInset * 2.0)
        let size = CGSize(width: width, height: h)

        let renderer = UIGraphicsImageRenderer(size: size, format: {
            let f = UIGraphicsImageRendererFormat.preferred()
            f.opaque = false
            return f
        }())
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: lineWidth / 2.0, dy: lineWidth / 2.0)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: h * 0.28)
            cg.setStrokeColor(accent.cgColor)
            cg.setLineWidth(lineWidth)
            path.stroke()
            let textOrigin = CGPoint(x: (size.width - textSize.width) / 2.0,
                                     y: (size.height - textSize.height) / 2.0)
            text.draw(at: textOrigin, withAttributes: textAttrs)
        }
    }
}
