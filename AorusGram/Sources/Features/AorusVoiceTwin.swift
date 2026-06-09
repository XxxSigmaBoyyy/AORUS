import Foundation
import AVFoundation
import AudioToolbox

// MARK: - AorusVoiceTwin
//
// Real-time, in-place voice transform applied to OUTGOING voice messages.
// The recorder hands us captured PCM (Int16, mono, 48 kHz) one buffer at a time
// (see the patch on ManagedAudioRecorder.processAndDisposeAudioBuffer). We mutate
// the samples in place BEFORE they are encoded to Opus, so no re-encoding is
// needed and quality is preserved.
//
// Lives in the AorusGram core module (which the main TelegramUI module links
// against). It is configured purely through flat UserDefaults keys written by
// the AorusGramUI settings screen, so the two modules stay decoupled.
//
// Pitch shifting uses a same-length granular (two-tap crossfading delay-line)
// shifter — it never changes the sample count, so the recorder's packet
// accounting is untouched. "Robot" adds ring modulation. Output is soft-limited.
// The algorithm was validated offline (frequency tracking + no NaN/overflow)
// before porting here.

public final class AorusVoiceTwin {
    public static let shared = AorusVoiceTwin()
    private init() {}

    private static let ringSize = 8192
    private static let grain: Float = 1024.0

    private var ring = [Float](repeating: 0, count: AorusVoiceTwin.ringSize)
    private var writeIndex = 0
    private var phase: Float = 0
    private var ringModPhase: Float = 0

    private let sampleRate: Float = 48000

    public var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "aorusgram_voice_twin_enabled")
    }

    // Resolve the active preset to (pitch ratio, ring-mod frequency in Hz).
    private func params() -> (ratio: Float, ringHz: Float) {
        let preset = UserDefaults.standard.string(forKey: "aorusgram_voice_twin_preset") ?? "anonymous"
        var semis: Float = -5.0   // anonymous (deep, masked) by default
        var ringHz: Float = 0
        switch preset {
        case "male":   semis = -3.0
        case "female": semis = 3.5
        case "robot":  semis = 0.0; ringHz = 110.0
        case "high":   semis = 7.0
        default:       break
        }
        return (powf(2.0, semis / 12.0), ringHz)
    }

    // Process one captured buffer in place. Called on the recorder's queue.
    public func processBuffer(_ buffer: AudioBuffer) {
        guard isEnabled, let raw = buffer.mData else { return }
        let count = Int(buffer.mDataByteSize) / 2
        guard count > 0 else { return }
        let p = raw.assumingMemoryBound(to: Int16.self)

        let (ratio, ringHz) = params()
        let dphase: Float = 1.0 - ratio
        let half = AorusVoiceTwin.grain * 0.5
        let n = AorusVoiceTwin.ringSize
        let ringStep: Float = ringHz > 0 ? (2.0 * Float.pi * ringHz / sampleRate) : 0

        for i in 0 ..< count {
            let x = Float(p[i]) / 32768.0
            ring[writeIndex] = x

            var y: Float
            if ratio == 1.0 {
                y = x
            } else {
                let p1 = phase
                var p2 = phase + half
                if p2 >= AorusVoiceTwin.grain { p2 -= AorusVoiceTwin.grain }
                let r1 = readRing(Float(writeIndex) - p1, n)
                let r2 = readRing(Float(writeIndex) - p2, n)
                var w1 = abs(half - p1) / half
                if w1 < 0 { w1 = 0 }
                if w1 > 1 { w1 = 1 }
                y = r1 * w1 + r2 * (1.0 - w1)
            }

            if ringStep > 0 {
                y *= cosf(ringModPhase)
                ringModPhase += ringStep
                if ringModPhase > 2.0 * Float.pi { ringModPhase -= 2.0 * Float.pi }
            }

            // Advance shifter state.
            writeIndex += 1
            if writeIndex >= n { writeIndex = 0 }
            phase += dphase
            while phase >= AorusVoiceTwin.grain { phase -= AorusVoiceTwin.grain }
            while phase < 0 { phase += AorusVoiceTwin.grain }

            // Soft clip and write back.
            if y > 1.0 { y = 1.0 }
            if y < -1.0 { y = -1.0 }
            p[i] = Int16(y * 32767.0)
        }
    }

    // Linearly-interpolated read from the ring buffer at a (possibly negative) position.
    private func readRing(_ pos: Float, _ n: Int) -> Float {
        var fp = pos
        let nf = Float(n)
        while fp < 0 { fp += nf }
        while fp >= nf { fp -= nf }
        let i0 = Int(fp)
        let frac = fp - Float(i0)
        let i1 = (i0 + 1) % n
        return ring[i0] * (1.0 - frac) + ring[i1] * frac
    }
}
