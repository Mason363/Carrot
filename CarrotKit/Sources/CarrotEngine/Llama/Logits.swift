import Accelerate
import Foundation

/// Fast numerics over a logit vector.
struct Logits {
    let pointer: UnsafeMutablePointer<Float>
    let count: Int

    /// Index and value of the largest logit.
    func argmax() -> (index: Int32, value: Float) {
        var value: Float = 0
        var index: vDSP_Length = 0
        vDSP_maxvi(pointer, 1, &value, &index, vDSP_Length(count))
        return (Int32(index), value)
    }

    /// log Σ exp(logits) over the full vocabulary.
    func logSumExp(scratch: inout [Float]) -> Float {
        let (_, maxValue) = argmax()
        if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
        var negMax = -maxValue
        var n = Int32(count)
        var sum: Float = 0
        scratch.withUnsafeMutableBufferPointer { buf in
            vDSP_vsadd(pointer, 1, &negMax, buf.baseAddress!, 1, vDSP_Length(count))
            vvexpf(buf.baseAddress!, buf.baseAddress!, &n)
            vDSP_sve(buf.baseAddress!, 1, &sum, vDSP_Length(count))
        }
        return maxValue + log(sum)
    }

    /// log Σ exp over a subset of tokens.
    func logSumExp(of tokens: [Int32]) -> Float {
        var maxValue = -Float.infinity
        for t in tokens { maxValue = max(maxValue, pointer[Int(t)]) }
        guard maxValue.isFinite else { return -.infinity }
        var sum: Float = 0
        for t in tokens { sum += exp(pointer[Int(t)] - maxValue) }
        return maxValue + log(sum)
    }

    subscript(_ token: Int32) -> Float {
        get { pointer[Int(token)] }
        nonmutating set { pointer[Int(token)] = newValue }
    }
}

/// "Don't Repeat Yourself" penalty (after the DRY sampler by p-e-w): penalises tokens that would
/// extend a verbatim repeat of earlier text. Long repeats are penalised exponentially, so the
/// model stops parroting the user's own sentences while short, natural repeats (names, "of the")
/// are untouched.
struct RepetitionGuard {
    var multiplier: Float = 0.8
    var base: Float = 1.75
    var allowedLength = 2
    var maxMatch = 48

    /// Returns `token → penalty` for the next position given the token history.
    func penalties(history: [Int32], breakers: (Int32) -> Bool) -> [Int32: Float] {
        let n = history.count
        guard n >= 2 else { return [:] }
        var result: [Int32: Float] = [:]
        let last = history[n - 1]
        if breakers(last) { return [:] }
        history.withUnsafeBufferPointer { h in
            // For every earlier occurrence of the last token, measure how far the match extends backwards.
            var k = n - 2
            while k >= 0 {
                if h[k] == last {
                    var length = 1
                    while length < maxMatch, k - length >= 0, h[k - length] == h[n - 1 - length],
                          !breakers(h[k - length]) {
                        length += 1
                    }
                    if length >= allowedLength {
                        let next = h[k + 1]
                        let penalty = multiplier * pow(base, Float(length - allowedLength))
                        if penalty > (result[next] ?? 0) { result[next] = penalty }
                    }
                }
                k -= 1
            }
        }
        return result
    }
}
