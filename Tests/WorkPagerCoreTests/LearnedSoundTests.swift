import XCTest
import AVFoundation
@testable import WorkPagerCore

/// Opt-in regression using a locally learned reference; no audio fixture is committed.
final class LearnedSoundTests: XCTestCase {
    func testLocalLearnedTemplateAgainstSystemSounds() throws {
        guard let path = ProcessInfo.processInfo.environment["WORKPAGER_REFERENCE"] else { throw XCTSkip("Set WORKPAGER_REFERENCE to run the local learned-audio regression") }
        let template = try JSONDecoder().decode(SoundTemplate.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertTrue(template.isValid)
        let gain = SignalMatcher.score(reference: template.samples, candidate: template.samples.map { $0 * 0.1 })
        XCTAssertGreaterThan(gain, 0.99)
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/System/Library/Sounds"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "aiff" }
        XCTAssertGreaterThan(files.count, 5)
        for url in files {
            let file = try AVAudioFile(forReading: url)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let pcm = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            var resampler = MonoResampler()
            let converted = resampler.process(pcm, rate: file.processingFormat.sampleRate)
            let result = SignalMatcher.score(reference: template.samples, candidate: converted)
            print("Negative fixture \(url.lastPathComponent): \(String(format: "%.4f", result))")
            XCTAssertLessThan(result, 0.90, url.lastPathComponent)
        }
    }
}
