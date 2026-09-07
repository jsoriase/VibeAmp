import AVFoundation
import MediaToolbox
import AudioToolbox
import Foundation

// MARK: - Realtime EQ via MTAudioProcessingTap
//
// Why a tap instead of AVAudioUnitEQ?
// AVPlayer decodes remote streams itself and offers no node graph to insert an
// AVAudioUnitEQ into. The supported native hook for DSP on an AVPlayer source
// is an MTAudioProcessingTap attached through AVAudioMix: the tap receives
// decoded PCM after the player, processes it in place, and hands it back.
// That keeps streaming/seeking/buffering in AVPlayer (stable) while the EQ is
// genuine DSP — 10 RBJ peaking biquads + preamp applied per sample — not a
// decorative slider bank.
//
// Threading: process() runs on a realtime audio thread. It must not allocate,
// lock unboundedly, or touch Swift concurrency. Coefficient updates from the
// main actor take a short NSLock, swap precomputed coefficients, and return.

typealias EQStateTuple = (x1: Double, x2: Double, y1: Double, y2: Double)

private func zeroState(channels: Int) -> [EQStateTuple] {
    Array(repeating: (x1: 0, x2: 0, y1: 0, y2: 0), count: max(1, channels))
}

final class EQTapContext {
    let lock = NSLock()
    var sampleRate: Double = 44100
    var channelCount: Int = 2
    var preamp: Double = 1.0
    var bands: [EqualizerDSP.Biquad] = Array(repeating: EqualizerDSP.Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0), count: 10)
    // state[band][channel]
    var state: [[EQStateTuple]] = Array(repeating: zeroState(channels: 8), count: 10)
    /// True when the tap delivers 32-bit float non-interleaved PCM (the only
    /// format we process). Any other format falls through unprocessed so we
    /// never reinterpret foreign sample layouts as floats.
    var canProcess: Bool = true

    func update(preampDB: Double, bandGainsDB: [Double], sampleRate: Double?) {
        let rate = sampleRate ?? self.sampleRate
        let coeffs = EqualizerDSP.coefficients(sampleRate: rate, preampDB: preampDB, bandGainsDB: bandGainsDB)
        lock.lock()
        self.sampleRate = rate
        self.preamp = coeffs.preamp
        self.bands = coeffs.bands
        let channels = max(channelCount, 1)
        state = Array(repeating: zeroState(channels: channels), count: 10)
        lock.unlock()
    }
}

// MARK: - C callbacks (signatures must match MediaToolbox typedefs)

private func tapInit(
    _ tap: MTAudioProcessingTap,
    _ clientInfo: UnsafeMutableRawPointer?,
    _ tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    guard let clientInfo else {
        tapStorageOut.pointee = nil
        return
    }
    // Retain the context for the lifetime of the tap; released in finalize.
    let retained = Unmanaged<EQTapContext>.fromOpaque(clientInfo).retain()
    tapStorageOut.pointee = retained.toOpaque()
}

private func tapFinalize(_ tap: MTAudioProcessingTap) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    // Storage may be null if init failed; guard by checking against nil via optional wrap.
    let optionalStorage: UnsafeMutableRawPointer? = storage
    if let optionalStorage {
        Unmanaged<EQTapContext>.fromOpaque(optionalStorage).release()
    }
}

private func tapPrepare(
    _ tap: MTAudioProcessingTap,
    _ maxFrames: CMItemCount,
    _ processingFormat: UnsafePointer<AudioStreamBasicDescription>
) {
    let format = processingFormat.pointee
    let storage = MTAudioProcessingTapGetStorage(tap)
    let context: EQTapContext = Unmanaged.fromOpaque(storage).takeUnretainedValue()
    let channels = max(1, Int(format.mChannelsPerFrame))
    // Process only 32-bit float (native tap PCM). Anything else passes through.
    let isFloat = (format.mFormatID == kAudioFormatLinearPCM) &&
        (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
        (format.mBitsPerChannel == 32)
    context.lock.lock()
    context.sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44100
    context.channelCount = channels
    context.canProcess = isFloat
    context.state = Array(repeating: zeroState(channels: channels), count: 10)
    context.lock.unlock()
}

private func tapUnprepare(_ tap: MTAudioProcessingTap) {
    // No-op: state is torn down with the context.
}

private func tapProcess(
    _ tap: MTAudioProcessingTap,
    _ numberFrames: CMItemCount,
    _ flags: MTAudioProcessingTapFlags,
    _ bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    _ numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    var framesOut: CMItemCount = 0
    let status = MTAudioProcessingTapGetSourceAudio(
        tap, numberFrames, bufferListInOut, flagsOut, nil, &framesOut
    )
    guard status == noErr else {
        numberFramesOut.pointee = 0
        return
    }
    numberFramesOut.pointee = framesOut
    guard framesOut > 0 else { return }
    let storage = MTAudioProcessingTapGetStorage(tap)
    let context: EQTapContext = Unmanaged.fromOpaque(storage).takeUnretainedValue()

    context.lock.lock()
    let preamp = context.preamp
    let bands = context.bands
    let channels = context.channelCount
    let canProcess = context.canProcess
    context.lock.unlock()

    // Passthrough when the format is not Float32 or the curve is flat.
    if !canProcess { return }
    let isFlat = preamp == 1.0 && bands.allSatisfy { $0.b0 == 1 && $0.b1 == 0 && $0.b2 == 0 && $0.a1 == 0 && $0.a2 == 0 }
    if isFlat { return }

    let ablPointer = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    let frameCount = Int(framesOut)

    context.lock.lock()
    var localState = context.state
    context.lock.unlock()

    if localState.count != bands.count {
        localState = Array(repeating: zeroState(channels: max(channels, 1)), count: bands.count)
    }

    for (channelIndex, buffer) in ablPointer.enumerated() {
        guard channelIndex < max(channels, 1) else { break }
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        for frame in 0..<frameCount {
            var y = Double(data[frame]) * preamp
            for b in 0..<bands.count {
                let c = bands[b]
                var s: EQStateTuple = (x1: 0, x2: 0, y1: 0, y2: 0)
                if b < localState.count, channelIndex < localState[b].count {
                    s = localState[b][channelIndex]
                }
                let out = c.b0 * y + c.b1 * s.x1 + c.b2 * s.x2 - c.a1 * s.y1 - c.a2 * s.y2
                s.x2 = s.x1
                s.x1 = y
                s.y2 = s.y1
                s.y1 = out
                if b < localState.count, channelIndex < localState[b].count {
                    localState[b][channelIndex] = s
                }
                y = out
            }
            if !y.isFinite { y = 0 }
            if y > 1.2 { y = 1.2 } else if y < -1.2 { y = -1.2 }
            data[frame] = Float(y)
        }
    }

    context.lock.lock()
    if context.state.count == localState.count {
        context.state = localState
    }
    context.lock.unlock()
}

// MARK: - Tap factory

enum EqualizerTap {
    /// Creates an AVAudioMix that applies the given EQ curve.
    /// Returns nil if tap creation fails — callers must fall back to
    /// unprocessed playback in that case.
    static func audioMix(
        audioTrackID: CMPersistentTrackID,
        preampDB: Double,
        bandGainsDB: [Double],
        contextOut: inout EQTapContext?
    ) -> AVAudioMix? {
        let context = EQTapContext()
        context.update(preampDB: preampDB, bandGainsDB: bandGainsDB, sampleRate: nil)
        contextOut = context

        let clientInfo = Unmanaged.passUnretained(context).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: clientInfo,
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )
        var tap: MTAudioProcessingTap?
        // Extra retain balanced by tapFinalize.
        _ = Unmanaged.passRetained(context)
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )
        guard status == noErr, let tap else {
            Unmanaged<EQTapContext>.fromOpaque(clientInfo).release()
            contextOut = nil
            return nil
        }

        let params = AVMutableAudioMixInputParameters()
        params.audioTapProcessor = tap
        // A valid audio track ID is required for the tap to receive samples.
        // Callers resolve this from the AVAsset's audio tracks; Invalid is kept
        // only as a last-resort fallback (playback works, EQ may not apply).
        params.trackID = audioTrackID
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix.copy() as? AVAudioMix
    }
}
