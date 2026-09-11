import Foundation
import Accelerate

public struct SoundTemplate: Codable {
    public let sampleRate: Double
    public let samples: [Float]
    public init(samples: [Float], sampleRate: Double = 12000) { self.samples = samples; self.sampleRate = sampleRate }
    public var isValid: Bool {
        sampleRate == 12000 && samples.count >= 600 && samples.count <= 48000 && samples.allSatisfy(\.isFinite) && SignalMatcher.rms(samples) > 0.0001
    }
}

public enum SignalMatcher {
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(samples, 1, &value, vDSP_Length(samples.count))
        return value
    }
    public static func trim(_ samples: [Float]) -> [Float] {
        guard let peak = samples.map({ abs($0) }).max(), peak > 0.001 else { return [] }
        let gate = max(0.001, peak * 0.025)
        guard let start = samples.firstIndex(where: { abs($0) >= gate }),
              let end = samples.lastIndex(where: { abs($0) >= gate }) else { return [] }
        return Array(samples[max(0, start - 120)...min(samples.count - 1, end + 240)])
    }
    /// Normalized correlation with lag search. Polarity and gain are immaterial.
    public static func score(reference: [Float], candidate: [Float]) -> Double {
        guard reference.count >= 600, candidate.count >= 600 else { return 0 }
        let ref = trim(reference), input = trim(candidate)
        guard ref.count >= 600, input.count >= Int(Double(ref.count) * 0.8), input.count <= ref.count * 2 else { return 0 }
        let pad = 600
        let padded = [Float](repeating: 0, count: pad) + input + [Float](repeating: 0, count: ref.count + pad)
        let count = min(input.count + pad, 2 * pad + abs(input.count - ref.count) + 1)
        var correlation = [Float](repeating: 0, count: count)
        vDSP_conv(padded, 1, ref, 1, &correlation, 1, vDSP_Length(count), vDSP_Length(ref.count))
        var refEnergy: Float = 0
        vDSP_svesq(ref, 1, &refEnergy, vDSP_Length(ref.count))
        var prefix = [Double](repeating: 0, count: padded.count + 1)
        for i in padded.indices { prefix[i + 1] = prefix[i] + Double(padded[i]) * Double(padded[i]) }
        var best = 0.0
        for i in correlation.indices {
            let energy = prefix[i + ref.count] - prefix[i]
            guard energy > 1e-10, refEnergy > 1e-10 else { continue }
            best = max(best, abs(Double(correlation[i])) / sqrt(Double(refEnergy) * energy))
        }
        return min(1, best)
    }
}

/// Streaming low-pass / linear resampler, retains phase across HAL buffers.
public struct MonoResampler {
    private var previous: Float = 0
    private var filtered: Float = 0
    private var position = 0.0
    public init() {}
    public mutating func process(_ samples: [Float], rate: Double) -> [Float] {
        guard rate > 0 else { return [] }
        let step = rate / 12000
        let alpha = Float(1 - exp(-2 * Double.pi * 4500 / rate))
        var output: [Float] = []
        output.reserveCapacity(Int(Double(samples.count) / step) + 2)
        for sample in samples {
            filtered += alpha * (sample - filtered)
            while position < 1 {
                output.append(previous + Float(position) * (filtered - previous))
                position += step
            }
            position -= 1
            previous = filtered
        }
        return output
    }
}

/// Energy gate with 100 ms pre-roll and 220 ms trailing silence; hard limit 4 s.
public struct EventExtractor {
    private var pre: [Float] = []
    private var event: [Float] = []
    private var quiet = 0
    public init() {}
    public mutating func process(_ samples: [Float]) -> [[Float]] {
        var completed: [[Float]] = []
        let block = 120
        for offset in stride(from: 0, to: samples.count, by: block) {
            let part = Array(samples[offset..<min(offset + block, samples.count)])
            let active = SignalMatcher.rms(part) > 0.003
            if event.isEmpty {
                if active { event = pre; event.append(contentsOf: part); quiet = 0 }
                else { pre.append(contentsOf: part); if pre.count > 1200 { pre.removeFirst(pre.count - 1200) } }
            } else {
                event.append(contentsOf: part)
                quiet = active ? 0 : quiet + part.count
                if quiet >= 2640 || event.count >= 48000 {
                    let clipped = SignalMatcher.trim(event)
                    if clipped.count >= 600 { completed.append(clipped) }
                    event.removeAll(keepingCapacity: true); pre.removeAll(keepingCapacity: true); quiet = 0
                }
            }
        }
        return completed
    }
}
