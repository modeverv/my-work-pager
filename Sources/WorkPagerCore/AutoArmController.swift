import Foundation

public struct AutoArmController {
    public private(set) var overridden = false
    public private(set) var presence: Bool?
    public private(set) var since: TimeInterval?
    public init() {}
    public mutating func override() { overridden = true }
    public mutating func resume() { overridden = false; reset() }
    public mutating func reset() { presence = nil; since = nil }
    public func stableDuration(at now: TimeInterval) -> TimeInterval { max(0, now - (since ?? now)) }
    public mutating func observe(present: Bool, at now: TimeInterval, armDelay: Double, disarmDelay: Double) -> Bool? {
        if presence != present { presence = present; since = now }
        guard !overridden, stableDuration(at: now) >= (present ? disarmDelay : armDelay) else { return nil }
        return !present
    }
}

public struct AlertGate {
    private var last: TimeInterval?
    public init() {}
    public mutating func accept(armed: Bool, score: Double, threshold: Double, now: TimeInterval, cooldown: Double) -> Bool {
        guard armed, score.isFinite, score >= threshold,
              last == nil || now - last! >= cooldown else { return false }
        last = now
        return true
    }
}
