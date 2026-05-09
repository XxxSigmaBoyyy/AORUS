import Foundation

// MARK: - AorusCode — Unicode Steganography
//
// Encodes a secret message into zero-width Unicode characters appended
// to any cover text. Other Telegram clients see only the cover text;
// AorusGram recipients automatically decode and display the real message.
//
// Encoding: each byte of the UTF-8 secret is split into two nibbles
// (4 bits each) and mapped to a pair of invisible characters:
//   0x00–0x0F → U+200B (ZWSP) through U+200E / U+2060 / U+FEFF ...
// A magic header (U+2063 U+2064) marks AorusCode messages.

public final class AorusCodeManager {
    public static let shared = AorusCodeManager()
    private init() {}

    public var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "aorusgram_aorus_code_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "aorusgram_aorus_code_enabled") }
    }

    // Invisible characters for nibble encoding (16 values each)
    private let loNibble: [Character] = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}",
        "\u{2061}", "\u{2062}", "\u{2063}", "\u{2064}",
        "\u{206A}", "\u{206B}", "\u{206C}", "\u{206D}",
        "\u{206E}", "\u{206F}", "\u{FEFF}", "\u{FFA0}"
    ]
    private let hiNibble: [Character] = [
        "\u{180B}", "\u{180C}", "\u{180D}", "\u{180E}",
        "\u{180F}", "\u{FE00}", "\u{FE01}", "\u{FE02}",
        "\u{FE03}", "\u{FE04}", "\u{FE05}", "\u{FE06}",
        "\u{FE07}", "\u{FE08}", "\u{FE09}", "\u{FE0A}"
    ]

    // Magic header — marks the start of hidden payload
    private let magicOpen:  String = "\u{2063}\u{2064}"
    private let magicClose: String = "\u{2064}\u{2063}"

    // MARK: - Encode

    /// Wraps `cover` text with a hidden `secret` encoded as invisible Unicode.
    /// Pass empty string for `cover` to send a purely invisible message.
    public func encode(cover: String, secret: String) -> String {
        guard !secret.isEmpty else { return cover }
        let bytes = Array(secret.utf8)
        var hidden = magicOpen
        for byte in bytes {
            let hi = Int(byte >> 4)
            let lo = Int(byte & 0x0F)
            hidden.append(hiNibble[hi])
            hidden.append(loNibble[lo])
        }
        hidden += magicClose
        return cover + hidden
    }

    // MARK: - Decode

    /// Returns the decoded secret if the text contains AorusCode payload, else nil.
    public func decode(_ text: String) -> String? {
        guard let openRange = text.range(of: magicOpen),
              let closeRange = text.range(of: magicClose),
              openRange.upperBound <= closeRange.lowerBound else { return nil }

        let payload = String(text[openRange.upperBound..<closeRange.lowerBound])
        var bytes: [UInt8] = []
        let chars = Array(payload)
        var i = 0
        while i + 1 < chars.count {
            guard let hi = hiNibble.firstIndex(of: chars[i]),
                  let lo = loNibble.firstIndex(of: chars[i + 1]) else { i += 1; continue }
            bytes.append(UInt8(hi << 4 | lo))
            i += 2
        }
        return bytes.isEmpty ? nil : String(bytes: bytes, encoding: .utf8)
    }

    // MARK: - Display helpers

    /// True if the text carries an AorusCode payload.
    public func hasHiddenMessage(_ text: String) -> Bool {
        text.contains(magicOpen) && text.contains(magicClose)
    }

    /// Strips all invisible AorusCode characters from text for display on non-AorusGram clients.
    public func visibleText(_ text: String) -> String {
        guard let openRange = text.range(of: magicOpen) else { return text }
        return String(text[text.startIndex..<openRange.lowerBound])
    }

    /// Returns display pair: (coverText, secretText?) for a received message.
    public func split(_ text: String) -> (visible: String, secret: String?) {
        if hasHiddenMessage(text) {
            return (visibleText(text), decode(text))
        }
        return (text, nil)
    }
}

// MARK: - Notification for UI layer

extension Notification.Name {
    static let aorusCodeMessageReceived = Notification.Name("aorusgram_aorus_code_received")
}
