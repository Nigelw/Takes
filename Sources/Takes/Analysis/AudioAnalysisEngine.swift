import AVFoundation
import Foundation

/// Decodes an audio file and runs every analysis accumulator over it in a
/// single streaming pass, then interprets the metrics into verdicts.
///
/// Pure and UI-independent so the benchmark CLI can drive it against the
/// test corpus (`scripts/make-analysis-corpus.sh`).
enum AudioAnalysisEngine {
    enum AnalysisError: LocalizedError {
        case emptyFile

        var errorDescription: String? {
            switch self {
            case .emptyFile: return "The file contains no audio."
            }
        }
    }

    /// Frames decoded per read; keeps memory flat regardless of file length.
    private static let chunkFrameCount: AVAudioFrameCount = 1 << 16

    static func analyze(fileAt url: URL, includeSpectrogram: Bool = true) throws -> AudioAnalysisReport {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let totalFrames = Int(file.length)
        guard totalFrames > 0, channelCount > 0 else { throw AnalysisError.emptyFile }

        let durationSeconds = Double(totalFrames) / sampleRate
        let fileInfo = fileInfo(for: url, file: file, durationSeconds: durationSeconds)

        let loudnessMeter = LoudnessMeter(sampleRate: sampleRate, channelCount: channelCount)
        let welch = WelchSpectrumAccumulator(sampleRate: sampleRate)
        let quietFrames = QuietFrameCollector(sampleRate: sampleRate)
        // Stereo analyzers see at most two channels; surround content is
        // rare in Takes and the front pair carries the evidence they need.
        let analyzedChannelCount = min(channelCount, 2)
        let analogSource = AnalogSourceAnalyzer(sampleRate: sampleRate, channelCount: analyzedChannelCount)
        let lossyArtifacts = LossyArtifactAnalyzer(sampleRate: sampleRate, channelCount: analyzedChannelCount)
        let spectrogram = includeSpectrogram
            ? SpectrogramAccumulator(sampleRate: sampleRate, expectedFrameCount: totalFrames)
            : nil

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrameCount) else {
            throw AnalysisError.emptyFile
        }

        var monoMix = [Float]()
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunkFrameCount)
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0, let channelData = buffer.floatChannelData else { break }

            let channels = (0 ..< channelCount).map {
                UnsafeBufferPointer(start: channelData[$0], count: frameCount)
            }
            loudnessMeter.process(channels: channels)

            // Mono mix (average of channels) feeds the spectral accumulators.
            monoMix.removeAll(keepingCapacity: true)
            monoMix.append(contentsOf: channels[0])
            if channelCount > 1 {
                for channel in channels.dropFirst() {
                    for index in 0 ..< frameCount { monoMix[index] += channel[index] }
                }
                let scale = 1 / Float(channelCount)
                for index in 0 ..< frameCount { monoMix[index] *= scale }
            }

            welch.process(monoSamples: monoMix)
            quietFrames.process(monoSamples: monoMix)
            spectrogram?.process(monoSamples: monoMix)

            let channelArrays = channels.prefix(analyzedChannelCount).map(Array.init)
            analogSource.process(channels: channelArrays)
            lossyArtifacts.process(channels: channelArrays)
        }

        let loudnessResult = loudnessMeter.finalize()
        let spectrum = welch.finalize()
        let noiseFloor = quietFrames.finalize()
        let tonalBalance = SpectrumMetrics.tonalBalance(from: spectrum)
        let bandwidth = SpectrumMetrics.bandwidth(from: spectrum, sampleRate: sampleRate)
        let analogSourceMetrics = analogSource.finalize()
        let lossyArtifactMetrics = lossyArtifacts.finalize()
        // Bitstream inspection failing (I/O aside) just means "not an MP3";
        // provenance evidence is additive, never required.
        let mp3Stream = try? MP3BitstreamInspector.inspect(fileAt: url)

        let loudness = LoudnessMetrics(
            integratedLUFS: loudnessResult.integratedLUFS,
            samplePeakDBFS: loudnessResult.samplePeakDBFS,
            crestFactorDB: loudnessResult.samplePeakDBFS - loudnessResult.overallRMSDBFS,
            clippedSampleRunCount: loudnessResult.clippedRunCount
        )

        return AudioAnalysisReport(
            fileInfo: fileInfo,
            loudness: loudness,
            tonalBalance: tonalBalance,
            noiseFloor: noiseFloor,
            bandwidth: bandwidth,
            analogSource: analogSourceMetrics,
            lossyArtifacts: lossyArtifactMetrics,
            mp3Stream: mp3Stream ?? nil,
            averageSpectrum: spectrum,
            spectrogram: spectrogram?.finalize(durationSeconds: durationSeconds),
            conclusions: SourceInference.conclusions(
                fileInfo: fileInfo,
                loudness: loudness,
                noiseFloor: noiseFloor,
                bandwidth: bandwidth,
                analogSource: analogSourceMetrics,
                lossyArtifacts: lossyArtifactMetrics,
                mp3Stream: mp3Stream ?? nil
            ),
            verdicts: AnalysisVerdictBuilder.verdicts(
                fileInfo: fileInfo,
                loudness: loudness,
                tonalBalance: tonalBalance,
                noiseFloor: noiseFloor,
                bandwidth: bandwidth
            )
        )
    }

    // MARK: File info

    private static func fileInfo(for url: URL, file: AVAudioFile, durationSeconds: Double) -> AnalyzedFileInfo {
        let settings = file.fileFormat.settings
        let formatID = (settings[AVFormatIDKey] as? NSNumber).map { AudioFormatID($0.uint32Value) }
        let bitDepth = (settings[AVLinearPCMBitDepthKey] as? NSNumber)?.intValue
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let dataRateKbps = durationSeconds > 0 ? Double(fileSize) * 8 / durationSeconds / 1_000 : 0

        return AnalyzedFileInfo(
            url: url,
            fileName: url.lastPathComponent,
            codecDescription: codecDescription(formatID: formatID, url: url),
            sampleRateHz: file.fileFormat.sampleRate,
            channelCount: Int(file.fileFormat.channelCount),
            bitDepth: bitDepth == 0 ? nil : bitDepth,
            durationSeconds: durationSeconds,
            dataRateKbps: dataRateKbps,
            isLosslessCodec: formatID.map(isLossless) ?? false
        )
    }

    private static func isLossless(_ formatID: AudioFormatID) -> Bool {
        switch formatID {
        case kAudioFormatLinearPCM, kAudioFormatFLAC, kAudioFormatAppleLossless:
            return true
        default:
            return false
        }
    }

    private static func codecDescription(formatID: AudioFormatID?, url: URL) -> String {
        guard let formatID else { return url.pathExtension.uppercased() }
        switch formatID {
        case kAudioFormatLinearPCM: return "PCM (\(url.pathExtension.uppercased()))"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatAppleLossless: return "Apple Lossless"
        case kAudioFormatMPEG4AAC: return "AAC"
        case kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: return "HE-AAC"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatMPEGLayer2: return "MP2"
        case kAudioFormatOpus: return "Opus"
        case kAudioFormatAC3: return "AC-3"
        default:
            // Render the FourCC (e.g. "aac ") for formats not special-cased.
            let bytes = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((formatID >> $0) & 0xFF))) }
            return String(bytes).trimmingCharacters(in: .whitespaces).uppercased()
        }
    }
}
