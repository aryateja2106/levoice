import AVFoundation

final class AudioRecorder {
    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: (() -> Void)?

    private let engine = AVAudioEngine()
    private let bufferLock = NSLock()

    /// The accumulated audio samples captured during recording.
    /// Accessible for reading within the module (internal) so tests can inspect it.
    var audioBuffer: [Float] = []

    /// Target format for WhisperKit: 16 kHz, mono, Float32.
    private lazy var targetFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    }()

    /// Pre-warm the audio engine so the first recording starts faster.
    func prewarm() {
        _ = engine.inputNode // Force node initialization
        engine.prepare()
    }

    static func serializeAudioBuffer(_ samples: [Float]) throws -> Data {
        samples.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    static func serializePlayableArchiveAudioBuffer(_ samples: [Float]) throws -> Data {
        let sampleRate = UInt32(16_000)
        let channelCount = UInt16(1)
        let bitsPerSample = UInt16(16)
        let bytesPerSample = Int(bitsPerSample / 8)
        let dataSize = samples.count * bytesPerSample
        let byteRate = sampleRate * UInt32(channelCount) * UInt32(bitsPerSample) / 8
        let blockAlign = channelCount * bitsPerSample / 8
        let riffChunkSize = UInt32(36 + dataSize)

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(contentsOf: riffChunkSize.littleEndianBytes)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(contentsOf: UInt32(16).littleEndianBytes)
        data.append(contentsOf: UInt16(1).littleEndianBytes)
        data.append(contentsOf: channelCount.littleEndianBytes)
        data.append(contentsOf: sampleRate.littleEndianBytes)
        data.append(contentsOf: byteRate.littleEndianBytes)
        data.append(contentsOf: blockAlign.littleEndianBytes)
        data.append(contentsOf: bitsPerSample.littleEndianBytes)
        data.append("data".data(using: .ascii)!)
        data.append(contentsOf: UInt32(dataSize).littleEndianBytes)

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let scaled = Int16((clamped * Float(Int16.max)).rounded())
            data.append(contentsOf: scaled.littleEndianBytes)
        }

        return data
    }

    static func deserializeAudioBuffer(from data: Data) throws -> [Float] {
        let stride = MemoryLayout<Float>.stride
        guard data.count.isMultiple(of: stride) else {
            throw AudioRecorderPersistenceError.invalidSerializedAudioData
        }

        return data.withUnsafeBytes { rawBuffer in
            let floatBuffer = rawBuffer.bindMemory(to: Float.self)
            return Array(floatBuffer)
        }
    }

    static func deserializeArchivedAudioBuffer(from data: Data) throws -> [Float] {
        if data.starts(with: Data("RIFF".utf8)) {
            return try deserializeWAVAudioBuffer(from: data)
        }

        return try deserializeAudioBuffer(from: data)
    }

    /// Clears the in-memory audio buffer.
    func resetBuffer() {
        bufferLock.lock()
        audioBuffer = []
        bufferLock.unlock()
    }

    /// Starts capturing audio from the default input device.
    /// Audio is converted to 16 kHz mono Float32 and appended to `audioBuffer`.
    func startRecording() throws {
        resetBuffer()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        print("AudioRecorder: input device format = \(inputFormat), sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)")

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputAvailable
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.converterCreationFailed
        }

        // Choose a buffer size that gives roughly 100ms of audio at the input sample rate.
        let bufferSize: AVAudioFrameCount = AVAudioFrameCount(inputFormat.sampleRate * 0.1)

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] pcmBuffer, _ in
            guard let self = self else { return }
            self.convert(buffer: pcmBuffer, using: converter)
        }

        try engine.start()
        onRecordingStarted?()
    }

    /// Stops capturing audio and returns the recorded buffer.
    /// Waits briefly to flush any remaining audio in the engine's buffer.
    func stopRecording() async -> [Float] {
        // Wait 200ms to let the last audio buffers flush through
        try? await Task.sleep(nanoseconds: 200_000_000)

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        onRecordingStopped?()

        bufferLock.lock()
        let result = audioBuffer
        bufferLock.unlock()
        print("AudioRecorder: stopped, buffer has \(result.count) samples (\(Double(result.count) / 16000.0)s of audio)")
        if !result.isEmpty {
            let maxAmplitude = result.map { abs($0) }.max() ?? 0
            print("AudioRecorder: max amplitude = \(maxAmplitude)")
        }
        return result
    }

    // MARK: - Private

    private func convert(buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) {
        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * (targetFormat.sampleRate / buffer.format.sampleRate)
        ) + 1 // +1 to avoid rounding down to zero

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            return
        }

        var error: NSError?
        var allConsumed = false

        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if allConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            allConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            print("AudioRecorder: conversion error – \(error.localizedDescription)")
            return
        }

        guard let channelData = convertedBuffer.floatChannelData, convertedBuffer.frameLength > 0 else {
            return
        }

        let frames = Array(UnsafeBufferPointer(start: channelData[0], count: Int(convertedBuffer.frameLength)))

        bufferLock.lock()
        audioBuffer.append(contentsOf: frames)
        bufferLock.unlock()
    }
}

// MARK: - Errors

private extension AudioRecorder {
    static func deserializeWAVAudioBuffer(from data: Data) throws -> [Float] {
        guard data.count >= 44,
              data.starts(with: Data("RIFF".utf8)),
              data.dropFirst(8).starts(with: Data("WAVE".utf8)) else {
            throw AudioRecorderPersistenceError.invalidSerializedAudioData
        }

        var offset = 12
        var audioFormat: UInt16?
        var bitsPerSample: UInt16?
        var channelCount: UInt16?
        var sampleData = Data()

        while offset + 8 <= data.count {
            let chunkIDData = data[offset..<(offset + 4)]
            let chunkSize = UInt32(littleEndian: data[(offset + 4)..<(offset + 8)].withUnsafeBytes { $0.load(as: UInt32.self) })
            offset += 8

            guard offset + Int(chunkSize) <= data.count else {
                throw AudioRecorderPersistenceError.invalidSerializedAudioData
            }

            let chunkData = data[offset..<(offset + Int(chunkSize))]
            let chunkID = String(decoding: chunkIDData, as: UTF8.self)

            if chunkID == "fmt " {
                guard chunkData.count >= 16 else {
                    throw AudioRecorderPersistenceError.invalidSerializedAudioData
                }

                audioFormat = UInt16(littleEndian: chunkData[chunkData.startIndex..<(chunkData.startIndex + 2)].withUnsafeBytes { $0.load(as: UInt16.self) })
                channelCount = UInt16(littleEndian: chunkData[(chunkData.startIndex + 2)..<(chunkData.startIndex + 4)].withUnsafeBytes { $0.load(as: UInt16.self) })
                bitsPerSample = UInt16(littleEndian: chunkData[(chunkData.startIndex + 14)..<(chunkData.startIndex + 16)].withUnsafeBytes { $0.load(as: UInt16.self) })
            } else if chunkID == "data" {
                sampleData = Data(chunkData)
            }

            offset += Int(chunkSize)
            if chunkSize.isMultiple(of: 2) == false {
                offset += 1
            }
        }

        guard audioFormat == 1,
              channelCount == 1,
              bitsPerSample == 16,
              sampleData.count.isMultiple(of: 2) else {
            throw AudioRecorderPersistenceError.invalidSerializedAudioData
        }

        return sampleData.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            return int16Buffer.map { Float($0) / Float(Int16.max) }
        }
    }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}

enum AudioRecorderError: Error, LocalizedError {
    case noInputAvailable
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
        case .noInputAvailable:
            return "No audio input device available."
        case .converterCreationFailed:
            return "Failed to create audio format converter."
        }
    }
}

enum AudioRecorderPersistenceError: Error {
    case invalidSerializedAudioData
}
