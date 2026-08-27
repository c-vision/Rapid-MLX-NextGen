import Foundation

/// A tiny lock-protected mutable box so `@Sendable` test closures (the seams
/// require `@Sendable`) can safely capture and mutate shared state in Swift 6
/// strict-concurrency mode.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) {
        _value = value
    }

    /// Read or mutate the boxed value under the lock.
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&_value)
    }

    var value: Value {
        withLock { $0 }
    }
}
