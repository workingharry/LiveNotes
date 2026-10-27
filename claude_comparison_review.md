public struct RetryPolicy: Sendable {
    public var maxAttempts = 5
    public var base: TimeInterval = 2
    public var cap: TimeInterval = 30
    public func delay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let ra = retryAfter { return min(max(ra, 1), 60) }          // 尊重 Retry-After
        let exp = min(pow(2, Double(attempt)), cap)
        return Double.random(in: 0...exp)                               // full jitter
    }
}