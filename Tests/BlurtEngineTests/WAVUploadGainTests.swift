import Foundation
import Testing

@testable import BlurtEngine

@Suite("Quiet WAV upload gain")
struct WAVUploadGainTests {
  @Test("quiet speech is raised in the upload body without changing the original")
  func quiet() {
    var source = WAVAudioWriter.header(audioBytes: 6)
    source.append(contentsOf: [0x18, 0xFC, 0x00, 0x00, 0xE8, 0x03])  // -1000, 0, +1000
    let adjusted = WAVUploadGain.adjusted(source)
    #expect(adjusted.count == source.count)
    #expect(adjusted.prefix(44) == source.prefix(44))
    #expect(Array(source.suffix(6)) == [0x18, 0xFC, 0, 0, 0xE8, 0x03])
    #expect(Array(adjusted.suffix(6)) == [0xC0, 0xE0, 0, 0, 0x40, 0x1F])  // -8000, 0, +8000
  }

  @Test("loud, silent, and other-format audio are unchanged")
  func unchanged() {
    var loud = WAVAudioWriter.header(audioBytes: 2)
    loud.append(contentsOf: [0x30, 0x75])  // +30000
    #expect(WAVUploadGain.adjusted(loud) == loud)
    var silent = WAVAudioWriter.header(audioBytes: 2)
    silent.append(contentsOf: [0, 0])
    #expect(WAVUploadGain.adjusted(silent) == silent)
    let ogg = Data("OggS".utf8)
    #expect(WAVUploadGain.adjusted(ogg) == ogg)
  }
}
