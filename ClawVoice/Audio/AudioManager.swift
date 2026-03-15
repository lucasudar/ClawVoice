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

    /// Cached on main thread via RouteChange notification — safe to read from any thread
    private(set) var headphonesConnected = false

    private var chunkHandler: AudioChunkHandler?
    private let sendQueue      = DispatchQueue(label: "clawvoice.audio.send", qos: .userInitiated)
    private var accumulated    = Data()
    private var flushTimer:    DispatchSourceTimer?  // periodic flush so silence reaches Gemini VAD


    // MARK: - Public API

    /// Start capturing mic audio. Calls `onChunk` with ~100ms PCM Int16 16kHz chunks.
    // MARK: - Route helpers (main-thread safe headphone detection)

    private func updateHeadphonesState() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        headphonesConnected = outputs.contains {
            $0.portType == .headphones || $0.portType == .bluetoothA2DP ||
            $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        updateHeadphonesState()
        let session = AVAudioSession.sharedInstance()
        try? session.overrideOutputAudioPort(headphonesConnected ? .none : .speaker)
    }

    /// Called by AVAudioEngine when BT or other route changes force engine reconfiguration.
    /// Per Apple docs: stop engine, remove tap, reconnect nodes, reinstall tap, restart.
    @objc private func handleEngineConfigurationChange(_ notification: Notification) {
        guard isCapturing else { return }
        print("⚠️ [Audio] Engine reconfigured — full restart")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCapturing else { return }
            // 1. Stop everything cleanly
            self.playerNode.stop()
            self.audioEngine.stop()
            self.audioEngine.inputNode.removeTap(onBus: 0)
            self.tapConverter = nil  // force rebuild with new format
            self.tapConverterSourceRate = 0

            // 2. Reconnect player with output format
            self.audioEngine.disconnectNodeOutput(self.playerNode)
            let playerFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: self.outputSampleRate,
                                             channels: self.channels,
                                             interleaved: false)!
            self.audioEngine.connect(self.playerNode, to: self.audioEngine.mainMixerNode, format: playerFormat)

            // 3. Reinstall tap (nil format — engine picks actual hw format after stop/restart)
            self.installTap()

            // 4. Restart engine
            do {
                self.audioEngine.prepare()
                try self.audioEngine.start()
                if !self.isUserPaused { self.playerNode.play() }
                print("✅ [Audio] Engine restarted after BT reconfigure")
            } catch {
                print("❌ [Audio] Engine restart after reconfigure failed: \(error)")
            }
        }
    }

    // Cached converter — rebuilt when hardware format changes (e.g. BT route switch)
    private var tapConverter: AVAudioConverter?
    private var tapConverterSourceRate: Double = 0

    /// Get actual hardware input format from AVAudioSession (always current, not cached by engine)
    private func hardwareInputFormat() -> AVAudioFormat? {
        let session = AVAudioSession.sharedInstance()
        let rate = session.sampleRate
        let ch = UInt32(max(1, session.inputNumberOfChannels))
        guard rate > 0 else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: ch, interleaved: false)
    }

    private func installTap() {
        let inputNode = audioEngine.inputNode
        // Use AVAudioSession for the ACTUAL current hw format (never cached).
        // inputNode.outputFormat(forBus:0) and nil both return the engine's internal cached format
        // which doesn't update until engine is fully re-initialized — causing format mismatch with BT HFP.
        guard let hwFormat = hardwareInputFormat() else {
            print("⚠️ [Audio] hardwareInputFormat returned nil, skipping tap")
            return
        }
        print("🎙 [Audio] Installing tap: \(Int(hwFormat.sampleRate))Hz ch=\(hwFormat.channelCount)")

        let resampleFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: inputSampleRate,
                                           channels: channels,
                                           interleaved: false)!

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self, !self.isMuted, !self.isUserPaused else { return }

            let bufferRate = buffer.format.sampleRate
            let pcmData: Data
            if bufferRate == self.inputSampleRate && buffer.format.channelCount == self.channels {
                pcmData = self.float32ToInt16Data(buffer)
            } else {
                if self.tapConverter == nil || self.tapConverterSourceRate != bufferRate {
                    self.tapConverter = AVAudioConverter(from: buffer.format, to: resampleFormat)
                    self.tapConverterSourceRate = bufferRate
                }
                guard let converter = self.tapConverter,
                      let resampled = self.convert(buffer, using: converter, to: resampleFormat) else { return }
                pcmData = self.float32ToInt16Data(resampled)
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

    // MARK: - Capture

    func startCapture(onChunk: @escaping AudioChunkHandler) throws {
        guard !isCapturing else { return }
        // Defensive cleanup: remove any stale tap (e.g. if previous startCapture threw after tap install)
        audioEngine.inputNode.removeTap(onBus: 0)
        isUserPaused = false  // always start fresh — stale pause flag causes silent audio drop after reconnect
        chunkHandler = onChunk
        accumulated  = Data()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .voiceChat,
                                options: [.allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers])
        try session.setPreferredSampleRate(inputSampleRate)
        try session.setPreferredIOBufferDuration(0.064)
        try session.setActive(true)
        // Cache headphones state and subscribe to route + engine changes
        updateHeadphonesState()
        NotificationCenter.default.addObserver(self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil)
        NotificationCenter.default.addObserver(self,
            selector: #selector(handleEngineConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: audioEngine)

        // Use speaker if no headphones connected (.voiceChat defaults to earpiece)
        try session.overrideOutputAudioPort(headphonesConnected ? .none : .speaker)

        // Connect player to main mixer using Float32 @ 24kHz
        let playerFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: outputSampleRate,
                                         channels: channels,
                                         interleaved: false)!
        // Attach only if not already attached (re-attach after detach in stopCapture)
        if audioEngine.attachedNodes.contains(playerNode) == false {
            audioEngine.attach(playerNode)
        }
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playerFormat)

        // Install tap using shared helper (handles BT format + resampling).
        // With BT HFP, format may not be ready yet (sampleRate=0) — installTap guards this.
        // AVAudioEngineConfigurationChange fires when BT SCO connects and we reinstall then.
        installTap()

        audioEngine.prepare()
        try audioEngine.start()

        // BT HFP deferred tap retry: SCO channel may not be ready at connect time.
        // After 300ms, reinstall tap with the now-settled BT format (safe no-op if already correct).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isCapturing else { return }
            self.audioEngine.inputNode.removeTap(onBus: 0)
            self.installTap()
        }
        playerNode.play()
        isCapturing = true
        startFlushTimer()
    }

    func stopCapture() {
        guard isCapturing else { return }
        stopFlushTimer()
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: audioEngine)
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

    /// User-initiated pause: pause AI audio (buffers preserved) and halt mic sending.
    /// playerNode.pause() keeps scheduled buffers so resume continues from the same point.
    func pauseCapture() {
        isUserPaused = true
        playerNode.pause()  // preserve scheduled buffers — resume continues from here
    }

    /// User-initiated resume: clear pause flag — audio continues from pause point.
    func resumeCapture() {
        isUserPaused = false
        playerNode.play()  // continue playing buffered AI audio
    }

    /// Gemini-initiated interruption: DROP all buffered audio immediately.
    /// Different from pauseCapture() — this is not a resume-able pause.
    func clearPlayback() {
        playerNode.stop()   // cancels all scheduled buffers
        playerNode.play()   // re-arm for next AI response
    }



    /// Schedule a chunk of PCM Int16 24kHz audio for gapless playback.
    func playAudio(_ data: Data) {
        guard isCapturing, !data.isEmpty else { return }
        // Note: don't guard on isUserPaused — still schedule buffers while paused.
        // playerNode.pause() holds them; playerNode.play() on resume continues from here.

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
        // Only auto-play if not user-paused (paused = buffering for later resume)
        if !isUserPaused && !playerNode.isPlaying { playerNode.play() }
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
