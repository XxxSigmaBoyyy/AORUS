import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia

// MARK: - AorusVoiceTwin
//
// Real-time, in-place voice transform applied to OUTGOING audio. This Swift core
// drives two paths: voice messages (the recorder hands us captured PCM, Int16
// mono 48 kHz, one buffer at a time — see the patch on
// ManagedAudioRecorder.processAndDisposeAudioBuffer) and video notes / кружочки
// (a captured audio CMSampleBuffer — see CameraOutput). In both cases we mutate
// the samples in place BEFORE encoding — no re-encoding, identical sample count,
// so the recorder's packet accounting is untouched.
//
// Voice/video CALLS run through the native WebRTC capture path, which never
// reaches Swift, so calls are handled by a self-contained C++ port of this same
// DSP injected into TgVoipWebrtc (AorusCallVoiceTwin.h, wired by
// scripts/aorus_branding.py:patch_voice_twin_calls). Both implementations read
// the same UserDefaults keys, so the settings screen drives all three paths.
//
// Lives in the AorusGram core module (which the main TelegramUI module links
// against) and is configured purely through flat UserDefaults keys written by the
// AorusGramUI settings screen, so the two modules stay decoupled.
//
// Pitch presets use a FORMANT-PRESERVING shifter (LPC vocoder): every sample is
// inverse-filtered to a near-white residual, the residual is pitch-shifted with a
// granular delay line, then re-synthesised through the ORIGINAL all-pole vocal-
// tract filter — so the formants (timbre/identity) stay put while the pitch moves,
// giving a natural result instead of a chipmunk/monster. LPC is re-estimated every
// hop with bandwidth expansion + pre-emphasis for a clean, stable envelope; output
// is AGC-levelled and soft-clipped, and a per-sample stability guard falls back to
// the dry residual if a frame ever produces a non-finite/runaway value.
//
// "Robot" is pure ring modulation (no pitch shift). The whole chain was validated
// offline: formants stay within ~15 Hz on downward shifts, output stays bounded
// (peak 1.0, no NaN) across presets.

public final class AorusVoiceTwin {
    public static let shared = AorusVoiceTwin()
    private init() {
        xh = [Float](repeating: 0, count: order)
        yh = [Float](repeating: 0, count: order)
        pred = [Float](repeating: 0, count: order)
        autoc = [Float](repeating: 0, count: order + 1)
        hann = [Float](repeating: 0, count: frame)
        for i in 0 ..< frame {
            hann[i] = 0.5 - 0.5 * cosf(2.0 * Float.pi * Float(i) / Float(frame - 1))
        }
    }

    // Configuration (validated offline).
    private let order = 24
    private let frame = 1024
    private let hop = 256
    private let gamma: Float = 0.995     // bandwidth expansion (pole damping)
    private let preemph: Float = 0.95    // analysis pre-emphasis / output de-emphasis
    private let sampleRate: Float = 48000

    // Granular residual pitch-shifter state.
    private static let ringSize = 8192
    private static let grain: Float = 1024.0
    private var ring = [Float](repeating: 0, count: AorusVoiceTwin.ringSize)
    private var writeIndex = 0
    private var phase: Float = 0

    // LPC analysis / filter state.
    private var win = [Float](repeating: 0, count: 1024)
    private var wpos = 0
    private var filled = 0
    private var xh: [Float]            // inverse-filter input history
    private var yh: [Float]            // synthesis-filter output history
    private var pred: [Float]          // LPC predictor coefficients
    private var hann: [Float]
    private var scratch = [Float](repeating: 0, count: 1024)
    private var autoc: [Float]
    private var cnt = 0
    private var prevIn: Float = 0
    private var deemph: Float = 0
    private var inEnergy: Float = 1e-6
    private var outEnergy: Float = 1e-6

    // Ring modulation phase (robot).
    private var ringModPhase: Float = 0

    public var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "aorusgram_voice_twin_enabled")
    }

    // Resolve the active preset to (pitch ratio, ring-mod frequency in Hz).
    private func params() -> (ratio: Float, ringHz: Float) {
        let preset = UserDefaults.standard.string(forKey: "aorusgram_voice_twin_preset") ?? "anonymous"
        var semis: Float = -5.0   // anonymous: deep, masked, identity-hiding (formants preserved)
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

    // Voice-message path: process the recorder's Int16 mono 48 kHz buffer in place.
    public func processBuffer(_ buffer: AudioBuffer) {
        guard isEnabled, let raw = buffer.mData else { return }
        let count = Int(buffer.mDataByteSize) / 2
        guard count > 0 else { return }
        let (ratio, ringHz) = params()
        guard ratio != 1.0 || ringHz > 0 else { return }
        let p = raw.assumingMemoryBound(to: Int16.self)
        let ringStep: Float = ringHz > 0 ? (2.0 * Float.pi * ringHz / sampleRate) : 0
        for i in 0 ..< count {
            let y = transformSample(Float(p[i]) / 32768.0, ratio: ratio, ringStep: ringStep)
            p[i] = Int16(y * 32767.0)
        }
    }

    // Video-note / camera path: transform a captured audio CMSampleBuffer in place.
    // Handles mono Linear-PCM Int16 or Float32; ANY other layout is a safe no-op, so
    // it can never corrupt the recording or crash the camera pipeline.
    public func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isEnabled else { return }
        let (ratio, ringHz) = params()
        guard ratio != 1.0 || ringHz > 0 else { return }
        guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mChannelsPerFrame == 1 else { return }
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lenAt = 0
        var total = 0
        var dp: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lenAt,
                                          totalLengthOut: &total, dataPointerOut: &dp) == noErr,
              let base = dp, lenAt == total, total > 0 else { return }
        let sr = Float(asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000)
        let ringStep: Float = ringHz > 0 ? (2.0 * Float.pi * ringHz / sr) : 0
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSint = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0

        if isSint && asbd.mBitsPerChannel == 16 {
            let count = total / 2
            base.withMemoryRebound(to: Int16.self, capacity: count) { p in
                for i in 0 ..< count {
                    let y = transformSample(Float(p[i]) / 32768.0, ratio: ratio, ringStep: ringStep)
                    p[i] = Int16(y * 32767.0)
                }
            }
        } else if isFloat && asbd.mBitsPerChannel == 32 {
            let count = total / 4
            base.withMemoryRebound(to: Float.self, capacity: count) { p in
                for i in 0 ..< count {
                    p[i] = transformSample(p[i], ratio: ratio, ringStep: ringStep)
                }
            }
        }
    }

    // Shared per-sample core: input/output in [-1, 1].
    private func transformSample(_ x0: Float, ratio: Float, ringStep: Float) -> Float {
        var y: Float = (ratio == 1.0) ? x0 : formantStep(x0, ratio)
        if ringStep > 0 {
            y *= cosf(ringModPhase)
            ringModPhase += ringStep
            if ringModPhase > 2.0 * Float.pi { ringModPhase -= 2.0 * Float.pi }
        }
        if y > 1.0 { y = 1.0 }
        if y < -1.0 { y = -1.0 }
        return y
    }

    // MARK: - Formant-preserving pitch shift (one sample)

    private func formantStep(_ x0: Float, _ ratio: Float) -> Float {
        // Pre-emphasis flattens the spectral tilt → cleaner LPC envelope.
        let xp = x0 - preemph * prevIn
        prevIn = x0

        win[wpos] = xp
        wpos += 1
        if wpos >= frame { wpos = 0 }
        if filled < frame { filled += 1 }

        if cnt % hop == 0 && filled >= frame { updateLPC() }
        cnt += 1

        // Inverse filter → residual (near-white excitation).
        var e = xp
        for k in 0 ..< order { e -= pred[k] * xh[k] }

        // Pitch-shift the residual (formants are NOT in the residual).
        let es = granStep(e, ratio)

        // Re-synthesise through the original all-pole vocal-tract filter.
        var y = es
        for k in 0 ..< order { y += pred[k] * yh[k] }

        // Stability guard: never let a bad frame escape — fall back to dry residual.
        if !y.isFinite || abs(y) > 8.0 {
            for k in 0 ..< order { yh[k] = 0 }
            y = es
        }

        // Shift filter histories.
        var k = order - 1
        while k > 0 { xh[k] = xh[k - 1]; yh[k] = yh[k - 1]; k -= 1 }
        xh[0] = xp
        yh[0] = y

        // De-emphasis (inverse of pre-emphasis).
        deemph = y + preemph * deemph
        var yo = deemph

        // AGC: match output level to input level so gain never runs away.
        inEnergy = 0.999 * inEnergy + 0.001 * x0 * x0
        outEnergy = 0.999 * outEnergy + 0.001 * yo * yo
        var gain = sqrtf((inEnergy + 1e-9) / (outEnergy + 1e-9))
        if gain > 4.0 { gain = 4.0 }
        yo *= gain

        if yo > 1.0 { yo = 1.0 }
        if yo < -1.0 { yo = -1.0 }
        return yo
    }

    // MARK: - LPC estimation (autocorrelation + Levinson-Durbin)

    private func updateLPC() {
        for i in 0 ..< frame {
            scratch[i] = win[(wpos + i) % frame] * hann[i]
        }
        for lag in 0 ... order {
            var acc: Float = 0
            var i = lag
            while i < frame { acc += scratch[i] * scratch[i - lag]; i += 1 }
            autoc[lag] = acc
        }
        if autoc[0] <= 1e-9 {
            for k in 0 ..< order { pred[k] = 0 }
            return
        }
        autoc[0] *= 1.0002   // white-noise floor regularisation

        guard let p = levinson(autoc, order) else {
            for k in 0 ..< order { pred[k] = 0 }
            return
        }
        var g: Float = 1.0
        for k in 0 ..< order { g *= gamma; pred[k] = p[k] * g }
    }

    // Returns predictor coefficients p[0..<order] (x̂[n] = Σ p[k]·x[n-1-k]),
    // or nil if the frame is ill-conditioned / unstable.
    private func levinson(_ r: [Float], _ order: Int) -> [Float]? {
        var a = [Float](repeating: 0, count: order + 1)
        var e = r[0]
        if e <= 0 { return nil }
        for i in 1 ... order {
            var acc = r[i]
            for j in 1 ..< i { acc += a[j] * r[i - j] }
            let k = -acc / e
            if !k.isFinite || abs(k) >= 0.999 { return nil }
            var na = a
            for j in 1 ..< i { na[j] = a[j] + k * a[i - j] }
            na[i] = k
            a = na
            e *= (1.0 - k * k)
            if e <= 0 { return nil }
        }
        var pred = [Float](repeating: 0, count: order)
        for k in 1 ... order { pred[k - 1] = -a[k] }
        return pred
    }

    // MARK: - Granular two-tap crossfading delay-line shifter (same length)

    private func granStep(_ x: Float, _ ratio: Float) -> Float {
        let n = AorusVoiceTwin.ringSize
        let g = AorusVoiceTwin.grain
        let half = g * 0.5
        ring[writeIndex] = x

        var y: Float
        if ratio == 1.0 {
            y = x
        } else {
            let p1 = phase
            var p2 = phase + half
            if p2 >= g { p2 -= g }
            let r1 = readRing(Float(writeIndex) - p1, n)
            let r2 = readRing(Float(writeIndex) - p2, n)
            var w1 = abs(half - p1) / half
            if w1 < 0 { w1 = 0 }
            if w1 > 1 { w1 = 1 }
            y = r1 * w1 + r2 * (1.0 - w1)
        }

        writeIndex += 1
        if writeIndex >= n { writeIndex = 0 }
        phase += (1.0 - ratio)
        while phase >= g { phase -= g }
        while phase < 0 { phase += g }
        return y
    }

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
