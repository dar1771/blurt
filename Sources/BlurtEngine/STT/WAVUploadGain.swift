import Foundation

/// Raises a quiet captured WAV for the Universal-2 upload. The recording kept
/// in history stays untouched; only the request body is adjusted. Other audio
/// formats and WAV layouts are passed through unchanged.
enum WAVUploadGain {
  static func adjusted(_ audio: Data) -> Data {
    guard audio.count >= 46,
      audio[0..<4].elementsEqual("RIFF".utf8),
      audio[8..<12].elementsEqual("WAVE".utf8),
      audio[12..<16].elementsEqual("fmt ".utf8),
      read32(audio, at: 16) == 16,
      read16(audio, at: 20) == 1,
      read16(audio, at: 22) == 1,
      read32(audio, at: 24) == 16_000,
      read16(audio, at: 34) == 16,
      audio[36..<40].elementsEqual("data".utf8),
      let payloadBytes = read32(audio, at: 40),
      payloadBytes > 0, payloadBytes.isMultiple(of: 2),
      audio.count == 44 + Int(payloadBytes)
    else { return audio }

    let peak = audio.withUnsafeBytes { raw -> Int in
      let bytes = raw.bindMemory(to: UInt8.self)
      var result = 0
      for offset in stride(from: 44, to: bytes.count, by: 2) {
        let bits = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        result = max(result, abs(Int(Int16(bitPattern: bits))))
      }
      return result
    }
    // A zero signal has no speech to recover. Never attenuate a healthy clip,
    // and leave headroom even if the loudest sample is near full scale.
    guard peak > 0 else { return audio }
    let gain = min(8, Double(28_000) / Double(peak))
    guard gain > 1 else { return audio }

    var adjusted = audio
    adjusted.withUnsafeMutableBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      for offset in stride(from: 44, to: bytes.count, by: 2) {
        let bits = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        let sample = Int16(bitPattern: bits)
        let scaled = Int((Double(sample) * gain).rounded())
        let clipped = Int16(clamping: scaled)
        let value = UInt16(bitPattern: clipped)
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
      }
    }
    return adjusted
  }

  private static func read16(_ bytes: Data, at offset: Int) -> UInt16? {
    guard bytes.count >= offset + 2 else { return nil }
    return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
  }

  private static func read32(_ bytes: Data, at offset: Int) -> UInt32? {
    guard bytes.count >= offset + 4 else { return nil }
    return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
      | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
  }
}
