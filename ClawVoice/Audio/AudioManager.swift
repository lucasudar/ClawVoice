import AVFoundation
import Foundation

/// Handles microphone capture (PCM Int16 16kHz chunks) and speaker playback (PCM Int16 24kHz → Float32).
final class AudioManager {

    // MARK: - Types

    typealias AudioChunkHandler = (Data) -> Void

    // MARK: - Constants

    private let inputSampleRate:  Double = 16000
    private let outputSampleRate: Double = 24000
    private let channels: UInt32 = 1
    // Accumulate ~100ms of audio before sending to Gemini (reduces API call frequency)
    private let minSendBytes = 3200  // 100ms @ 16kHz mono Int16 = 1600 frames × 2 bytes

    // MARK: - Properties

    private let audioEngine    = AVAudioEngine()
    private let playerNode     = AVAudioPlayerNode()
    private var isCapturing    = false
    private var isMuted        = false  // mute mic while model is speaking (echo prevention)
    private(set) var isUserPaused = false  // user-initiated pause — skip sending but keep engine running

    /// true when any headphones (wired or BT) are connected — enables interruption of model speech
    var isHeadphonesConnected: Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains { route in
            route.portType == .headphones ||
            route.portType == .bluetoothA2DP ||
            route.portType == .bluetoothHFP ||
            route.portType == .bluetoothLE
        }
    }

    private var chunkHandler: AudioChunkHandler?
    private let sendQueue      = DispatchQueue(label: "clawvoice.audio.send", qos: .userInitiated)
    private var accumulated    = Data()
    private var flushTimer:    DispatchSourceTimer?  // periodic flush so silence reaches Gemini VAD

    // MARK: - Public API

    /// Start capturing mic audio. Calls `onChunk` with ~100ms PCM Int16 16kHz chunks.
    func startCapture(onChunk: @escaping AudioChunkHandler) throws {
        guard !isCapturing else { return }
        chunkHandler = onChunk
        accumulated  = Data()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .voiceChat,
                                options: [.allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers])
        try session.setPreferredSampleRate(inputSampleRate)
        try session.setPreferredIOBufferDuration(0.064)
        try session.setActive(true)
        // Route to headphones if connected, speaker only as fallback
        try session.overrideOutputAudioPort(.none)

        // Connect player to main mixer using Float32 @ 24kHz
        let playerFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: outputSampleRate,
                                         channels: channels,
                                         interleaved: false)!
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playerFormat)

        // Tap in native hardware format (Float32), then convert manually
        let inputNode       = audioEngine.inputNode
        let nativeFormat    = inputNode.outputFormat(forBus: 0)
        let needsResample   = nativeFormat.sampleRate != inputSampleRate || nativeFormat.channelCount != channels

        let resampleFormat  = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: inputSampleRate,
                                             channels: channels,
                                             interleaved: false)!
        let converter       = needsResample ? AVAudioConverter(from: nativeFormat, to: resampleFormat) : nil

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self, !self.isMuted, !self.isUserPaused else { return }

            let pcmData: Data
            if let converter {
                guard let resampled = self.convert(buffer, using: converter, to: resampleFormat) else { return }
                pcmData = self.float32ToInt16Data(resampled)
            } else {
                pcmData = self.float32ToInt16Data(buffer)
            }

            self.sendQueue.async {
                self.accumulated.append(pcmData)
                if self.accumulated.count >= self.minSendBytes {
                    let chunk = self.accumulated
                    self.accumulated = Data()
                    self.chunkHandler?(chunk)
                }
            }
        }

        try audioEngine.start()
        playerNode.play()
        isCapturing = true
        startFlushTimer()
    }

    func stopCapture() {
        guard isCapturing else { return }
        stopFlushTimer()
        audioEngine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        audioEngine.stop()
        audioEngine.detach(playerNode)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isCapturing = false
    }

    // MARK: - Flush Timer

    private func startFlushTimer() {
        stopFlushTimer()
        let timer = DispatchSource.makeTimerSource(queue: sendQueue)
        // Flush every 50ms so Gemini VAD always receives audio (including silence)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self, !self.isMuted, !self.accumulated.isEmpty else { return }
            let chunk = self.accumulated
            self.accumulated = Data()
            self.chunkHandler?(chunk)
        }
        timer.resume()
        flushTimer = timer
    }

    private func stopFlushTimer() {
        flushTimer?.cancel()
        flushTimer = nil
    }

    /// Echo suppression: mute mic while Gemini speaks. Engine keeps running for playback.
    func setMuted(_ muted: Bool) {
        isMuted = muted
        // Just set the flag — flush timer and tap stay active
        // Engine must keep running so playerNode can play Gemini's audio
    }

    /// User-initiated pause: set flag only — engine keeps running so VAD stays calibrated.
    /// Orange dot stays on (acceptable: stopping engine breaks Gemini VAD after resume).
    func pauseCapture() {
        isUserPaused = true
    }

    /// User-initiated resume: clear pause flag — audio immediately flows to Gemini again.
    func resumeCapture() {
        isUserPaused = false
    }

    private func reinstallTap() {
        let inputNode    = audioEngine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        let resampleFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: inputSampleRate,
                                           channels: channels,
                                           interleaved: false)!
        let needsResample = nativeFormat.sampleRate != inputSampleRate || nativeFormat.channelCount != channels
        let converter = needsResample ? AVAudioConverter(from: nativeFormat, to: resampleFormat) : nil

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self, !self.isMuted, !self.isUserPaused else { return }
            let pcmData: Data
            if let converter {
                guard let resampled = self.convert(buffer, using: converter, to: resampleFormat) else { return }
                pcmData = self.float32ToInt16Data(resampled)
            } else {
                pcmData = self.float32ToInt16Data(buffer)
            }
            self.sendQueue.async {
                self.accumulated.append(pcmData)
                if self.accumulated.count >= self.minSendBytes {
                    let chunk = self.accumulated
                    self.accumulated = Data()
                    self.chunkHandler?(chunk)
                }
            }
        }
    }

    /// Schedule a chunk of PCM Int16 24kHz audio for gapless playback.
    func playAudio(_ data: Data) {
        guard isCapturing, !data.isEmpty else { return }

        let playerFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: outputSampleRate,
                                          channels: channels,
                                          interleaved: false)!
        let frameCount = UInt32(data.count) / 2  // Int16 = 2 bytes per frame
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: frameCount)
        else { return }

        buffer.frameLength = frameCount
        guard let floatPtr = buffer.floatChannelData else { return }

        // Convert Int16 → Float32 (normalize to [-1, 1])
        data.withUnsafeBytes { raw in
            guard let int16Ptr = raw.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<Int(frameCount) {
                floatPtr[0][i] = Float(int16Ptr[i]) / Float(Int16.max)
            }
        }

        playerNode.scheduleBuffer(buffer)
        if !playerNode.isPlaying { playerNode.play() }
    }

    // MARK: - Private helpers

    private func convert(_ buffer: AVAudioPCMBuffer,
                         using converter: AVAudioConverter,
                         to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var error: NSError?
        var filled = false
        converter.convert(to: out, error: &error) { _, status in
            if !filled {
                filled = true
                status.pointee = .haveData
                return buffer
            }
            status.pointee = .noDataNow
            return nil
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    private func float32ToInt16Data(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let floatPtr = buffer.floatChannelData else { return Data() }
        let frameCount = Int(buffer.frameLength)
        var result = Data(count: frameCount * 2)
        result.withUnsafeMutableBytes { raw in
            guard let int16Ptr = raw.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<frameCount {
                let clamped = max(-1.0, min(1.0, floatPtr[0][i]))
                int16Ptr[i] = Int16(clamped * Float(Int16.max))
            }
        }
        return result
    }
}
