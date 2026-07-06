import Foundation

/// Reads provenance facts straight out of an MPEG audio bitstream without
/// decoding it: Xing/Info and LAME headers (encoder version, declared
/// lowpass), CBR/VBR, per-frame stereo modes. The most direct evidence
/// available while a file is still an MP3 — a missing LAME tag on a
/// high-bitrate file, or intensity-stereo frames, point at early encoders.
enum MP3BitstreamInspector {
    /// Frames to walk; enough to characterize mode usage and bitrate
    /// distribution without reading whole albums.
    private static let maxFramesInspected = 4_000
    private static let maxBytesRead = 4 << 20

    /// Returns `nil` when the file is not an MPEG audio stream (this is not
    /// an error — most inputs are other formats). Throws only on I/O
    /// failure. MP3 data inside other containers is out of scope.
    static func inspect(fileAt url: URL) throws -> MP3StreamInfo? {
        // Cheap gate: only try for extensions that plausibly hold MPEG audio.
        guard ["mp3", "mp2", "mpga", "bit"].contains(url.pathExtension.lowercased()) else {
            return nil
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: maxBytesRead), data.count > 128 else {
            return nil
        }
        return parse(data: data)
    }

    static func parse(data: Data) -> MP3StreamInfo? {
        let bytes = [UInt8](data)
        var offset = id3v2Size(bytes)

        var frames: [FrameHeader] = []
        var hasXingOrInfo = false
        var hasLameTag = false
        var encoderInfo: String?
        var declaredLowpassHz: Double?
        var intensityFrames = 0
        var jointFrames = 0

        while offset + 4 <= bytes.count, frames.count < maxFramesInspected {
            guard let header = FrameHeader(bytes: bytes, at: offset) else {
                // Resync: a single junk byte shouldn't abort the walk, but
                // give up quickly if this doesn't look like MPEG data at all.
                if frames.isEmpty {
                    offset += 1
                    if offset > 64 << 10 { return nil }
                    continue
                }
                break
            }

            // The first frame may carry the Xing/Info (+LAME) tag inside its
            // payload, after the side info.
            if frames.isEmpty {
                let tagOffset = offset + 4 + header.sideInfoSize
                if tagOffset + 4 <= bytes.count {
                    let magic = String(bytes: bytes[tagOffset ..< tagOffset + 4], encoding: .isoLatin1)
                    if magic == "Xing" || magic == "Info" {
                        hasXingOrInfo = true
                        let lame = parseLameTag(bytes: bytes, xingOffset: tagOffset)
                        hasLameTag = lame.present
                        encoderInfo = lame.encoder
                        declaredLowpassHz = lame.lowpassHz
                    }
                }
            }

            if header.isJointStereo {
                jointFrames += 1
                if header.usesIntensityStereo { intensityFrames += 1 }
            }
            frames.append(header)
            offset += header.frameLength
        }

        // A real MPEG stream yields a run of consistent frames; a handful of
        // accidental syncs in binary data does not.
        guard frames.count >= 8 else { return nil }

        let bitrates = frames.map(\.bitrateKbps)
        let meanBitrate = bitrates.reduce(0, +) / Double(bitrates.count)
        let isVBR = Set(bitrates.map { Int($0) }).count > 1

        // Music frames only for the mode statistics: the Xing frame itself
        // is a silent placeholder.
        let musicFrameCount = max(frames.count - (hasXingOrInfo ? 1 : 0), 1)

        return MP3StreamInfo(
            encoderInfo: encoderInfo,
            hasXingOrInfoHeader: hasXingOrInfo,
            hasLameTag: hasLameTag,
            bitrateMode: isVBR ? .vbr : .cbr,
            meanBitrateKbps: meanBitrate,
            declaredLowpassHz: declaredLowpassHz,
            usesIntensityStereo: intensityFrames > 0,
            jointStereoFrameFraction: Double(jointFrames) / Double(musicFrameCount),
            frameCount: frames.count
        )
    }

    // MARK: - Frame header

    private struct FrameHeader {
        let bitrateKbps: Double
        let sampleRate: Int
        let frameLength: Int
        let sideInfoSize: Int
        let isJointStereo: Bool
        let usesIntensityStereo: Bool

        /// MPEG-1/2 Layer III (and II) header tables. Returns nil unless the
        /// four bytes at `offset` form a valid, self-consistent header.
        init?(bytes: [UInt8], at offset: Int) {
            guard offset + 4 <= bytes.count,
                  bytes[offset] == 0xFF, bytes[offset + 1] & 0xE0 == 0xE0 else { return nil }

            let versionBits = (bytes[offset + 1] >> 3) & 0x3
            let layerBits = (bytes[offset + 1] >> 1) & 0x3
            // 00 = MPEG-2.5, 10 = MPEG-2, 11 = MPEG-1; 01 reserved.
            guard versionBits != 1, layerBits != 0 else { return nil }
            let isMPEG1 = versionBits == 3
            let isLayer3 = layerBits == 1

            let bitrateIndex = Int(bytes[offset + 2] >> 4)
            let sampleRateIndex = Int((bytes[offset + 2] >> 2) & 0x3)
            guard bitrateIndex != 0, bitrateIndex != 15, sampleRateIndex != 3 else { return nil }

            let mpeg1L3: [Double] = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
            let mpeg1L2: [Double] = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
            let mpeg2L3: [Double] = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
            let table = isMPEG1 ? (isLayer3 ? mpeg1L3 : mpeg1L2) : mpeg2L3
            let bitrate = table[bitrateIndex]

            let ratesMPEG1 = [44_100, 48_000, 32_000]
            let rate = ratesMPEG1[sampleRateIndex] / (isMPEG1 ? 1 : versionBits == 2 ? 2 : 4)

            let padding = Int((bytes[offset + 2] >> 1) & 0x1)
            let samplesPerFrame = isLayer3 ? (isMPEG1 ? 1_152 : 576) : 1_152
            let length = samplesPerFrame / 8 * Int(bitrate * 1_000) / rate + padding
            guard length > 4 else { return nil }

            let channelMode = (bytes[offset + 3] >> 6) & 0x3
            let modeExtension = (bytes[offset + 3] >> 4) & 0x3
            let isMono = channelMode == 3

            bitrateKbps = bitrate
            sampleRate = rate
            frameLength = length
            isJointStereo = channelMode == 1
            // Mode extension bit 0 = intensity stereo on (Layer III).
            usesIntensityStereo = channelMode == 1 && (modeExtension & 0x1) == 1
            sideInfoSize = isMPEG1 ? (isMono ? 17 : 32) : (isMono ? 9 : 17)
        }
    }

    // MARK: - Tags

    private static func id3v2Size(_ bytes: [UInt8]) -> Int {
        guard bytes.count > 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else { return 0 }
        // Syncsafe 28-bit size, excluding the 10-byte header itself.
        let size = (Int(bytes[6]) << 21) | (Int(bytes[7]) << 14) | (Int(bytes[8]) << 7) | Int(bytes[9])
        return 10 + size
    }

    /// The LAME extension tag begins 0x78 bytes after the "Xing"/"Info"
    /// magic: a 9-byte encoder string, then packed fields; the lowpass byte
    /// (offset +10 from the string start) stores lowpass/100 Hz.
    private static func parseLameTag(
        bytes: [UInt8], xingOffset: Int
    ) -> (present: Bool, encoder: String?, lowpassHz: Double?) {
        let encoderOffset = xingOffset + 0x78
        guard encoderOffset + 12 <= bytes.count else { return (false, nil, nil) }

        let encoderBytes = bytes[encoderOffset ..< encoderOffset + 9]
        let encoder = String(bytes: encoderBytes, encoding: .isoLatin1)?
            .trimmingCharacters(in: .whitespaces.union(.controlCharacters))
        guard let encoder, !encoder.isEmpty,
              encoder.range(of: "^[A-Za-z][A-Za-z0-9 ._-]*$", options: .regularExpression) != nil
        else {
            return (false, nil, nil)
        }

        // Only LAME-family tags define the packed fields after the string.
        let isLameFamily = encoder.hasPrefix("LAME") || encoder.hasPrefix("Lavf") || encoder.hasPrefix("Lavc")
        let lowpassByte = bytes[encoderOffset + 10]
        let lowpass = isLameFamily && lowpassByte > 0 ? Double(lowpassByte) * 100 : nil
        return (isLameFamily, encoder, lowpass)
    }
}
