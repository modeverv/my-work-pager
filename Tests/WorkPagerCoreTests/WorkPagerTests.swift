import XCTest
@testable import WorkPagerCore

final class WorkPagerTests: XCTestCase {
    func sound(frequency: Double = 930, count: Int = 6000) -> [Float] {
        (0..<count).map { i in
            let t = Double(i) / 12000
            return Float(sin(2 * .pi * frequency * t + 180 * t * t) * exp(-4 * t) * min(1, t * 100))
        }
    }
    func testCorrelationGainPolarityAndLag() {
        let reference = sound()
        let candidate = [Float](repeating: 0, count: 347) + reference.map { $0 * -0.17 } + [Float](repeating: 0, count: 483)
        XCTAssertGreaterThan(SignalMatcher.score(reference: reference, candidate: candidate), 0.98)
    }
    func testCorrelationRejectsUnrelatedSoundAndSilence() {
        XCTAssertLessThan(SignalMatcher.score(reference: sound(), candidate: sound(frequency: 2300)), 0.3)
        XCTAssertEqual(SignalMatcher.score(reference: sound(), candidate: [Float](repeating: 0, count: 6000)), 0)
        XCTAssertEqual(SignalMatcher.score(reference: [], candidate: sound()), 0)
    }
    func testNoisyCandidate() {
        var seed: UInt64 = 5
        let input = sound().map { value -> Float in
            seed = seed &* 6364136223846793005 &+ 1
            return value * 0.5 + Float(Double(seed >> 33) / Double(UInt32.max) - 0.25) * 0.04
        }
        XCTAssertGreaterThan(SignalMatcher.score(reference: sound(), candidate: input), 0.95)
    }
    func testStreamingGateAcrossBuffers() {
        var gate = EventExtractor()
        let input = [Float](repeating: 0, count: 2400) + sound() + [Float](repeating: 0, count: 4000)
        var events: [[Float]] = []
        for offset in stride(from: 0, to: input.count, by: 512) { events += gate.process(Array(input[offset..<min(offset + 512, input.count)])) }
        XCTAssertEqual(events.count, 1)
        XCTAssertGreaterThan(SignalMatcher.score(reference: sound(), candidate: events[0]), 0.98)
    }
    func testSilenceNeverCreatesEvent() {
        var gate = EventExtractor()
        XCTAssertTrue(gate.process([Float](repeating: 0, count: 120000)).isEmpty)
    }
    func testResamplerBufferBoundaryInvariant() {
        let input = (0..<44100).map { Float(sin(Double($0) * 0.12)) }
        var full = MonoResampler(), streaming = MonoResampler()
        let expected = full.process(input, rate: 44100)
        var actual: [Float] = []
        for offset in stride(from: 0, to: input.count, by: 511) { actual += streaming.process(Array(input[offset..<min(offset + 511, input.count)]), rate: 44100) }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.count, 12000, accuracy: 1)
    }
    func testPresenceHysteresisAndInterruptedAbsence() {
        var auto = AutoArmController()
        XCTAssertNil(auto.observe(present: false, at: 0, armDelay: 30, disarmDelay: 5))
        XCTAssertNil(auto.observe(present: false, at: 12, armDelay: 30, disarmDelay: 5))
        XCTAssertNil(auto.observe(present: true, at: 13, armDelay: 30, disarmDelay: 5))
        XCTAssertNil(auto.observe(present: false, at: 14, armDelay: 30, disarmDelay: 5))
        XCTAssertNil(auto.observe(present: false, at: 43, armDelay: 30, disarmDelay: 5))
        XCTAssertEqual(auto.observe(present: false, at: 44, armDelay: 30, disarmDelay: 5), true)
        XCTAssertNil(auto.observe(present: true, at: 45, armDelay: 30, disarmDelay: 5))
        XCTAssertNil(auto.observe(present: true, at: 47, armDelay: 30, disarmDelay: 5))
        XCTAssertEqual(auto.observe(present: true, at: 50, armDelay: 30, disarmDelay: 5), false)
    }
    func testOverrideAndResumeRestartWindow() {
        var auto = AutoArmController()
        _ = auto.observe(present: false, at: 0, armDelay: 30, disarmDelay: 5)
        auto.override()
        XCTAssertNil(auto.observe(present: false, at: 60, armDelay: 30, disarmDelay: 5))
        auto.resume()
        XCTAssertNil(auto.observe(present: false, at: 61, armDelay: 30, disarmDelay: 5))
        XCTAssertNil(auto.observe(present: false, at: 90, armDelay: 30, disarmDelay: 5))
        XCTAssertEqual(auto.observe(present: false, at: 91, armDelay: 30, disarmDelay: 5), true)
    }
    func testDisarmAndCooldown() {
        var gate = AlertGate()
        XCTAssertFalse(gate.accept(armed: false, score: 1, threshold: 0.9, now: 0, cooldown: 30))
        XCTAssertFalse(gate.accept(armed: true, score: 0.8, threshold: 0.9, now: 1, cooldown: 30))
        XCTAssertTrue(gate.accept(armed: true, score: 0.96, threshold: 0.9, now: 2, cooldown: 30))
        XCTAssertFalse(gate.accept(armed: true, score: 0.96, threshold: 0.9, now: 31, cooldown: 30))
        XCTAssertTrue(gate.accept(armed: true, score: 0.96, threshold: 0.9, now: 32, cooldown: 30))
        XCTAssertFalse(gate.accept(armed: true, score: .nan, threshold: 0.9, now: 90, cooldown: 30))
    }
    func testNotificationDataBoundary() throws {
        let request = try NtfyRequest.make(server: "https://ntfy.sh", topic: "work-pager-test")
        XCTAssertEqual(request.url?.absoluteString, "https://ntfy.sh/work-pager-test")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.httpBody, Data("仕事PCを確認".utf8))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Title"), "Work Pager")
        XCTAssertThrowsError(try NtfyRequest.make(server: "http://ntfy.sh", topic: "x"))
        XCTAssertThrowsError(try NtfyRequest.make(server: "https://ntfy.sh", topic: "x/y"))
        XCTAssertThrowsError(try NtfyRequest.make(server: "https://ntfy.sh?audio=sensitive", topic: "x"))
        XCTAssertThrowsError(try NtfyRequest.make(server: "https://ntfy.sh", topic: ""))
    }
    func testTemplatePersistenceAndValidation() throws {
        let template = SoundTemplate(samples: sound())
        let restored = try JSONDecoder().decode(SoundTemplate.self, from: JSONEncoder().encode(template))
        XCTAssertEqual(restored.samples, template.samples)
        XCTAssertTrue(restored.isValid)
        XCTAssertFalse(SoundTemplate(samples: []).isValid)
        XCTAssertFalse(SoundTemplate(samples: [.nan]).isValid)
    }
}
