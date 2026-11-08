import Foundation

/// The strip's one decode, shared by its cards' jobs on the engine's queue
/// (`EngineHost`), and given back by this service.
final class StripSource: @unchecked Sendable {
    static let givenBack = "the strip's picture was given back before this card"
    private let lock = NSLock()
    private var word: String?
    private var held: AnyObject?
    private var heldBytes = 0
    private var epoch = 0
    var generation: Int { lock.lock(); defer { lock.unlock() }; return epoch }
    private var ready: (@Sendable () -> Void)?
    func whenReady(_ callback: @escaping @Sendable () -> Void) {
        lock.lock(); ready = callback; lock.unlock()
    }

    /// The decode, if it is of `word`.
    func take(_ word: String) -> AnyObject? {
        lock.lock(); defer { lock.unlock() }
        return self.word == word ? held : nil
    }
    @discardableResult
    func keep(_ decode: AnyObject, for word: String, bytes: Int, expectedGeneration: Int) -> Bool {
        lock.lock()
        guard expectedGeneration == epoch else { lock.unlock(); return false }
        self.word = word; held = decode; heldBytes = bytes
        let callback = ready
        lock.unlock()
        callback?()
        return true
    }
    func holds(_ word: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return held != nil && self.word == word
    }
    var bytes: Int { lock.lock(); defer { lock.unlock() }; return held == nil ? 0 : heldBytes }
    func drop() {
        lock.lock(); defer { lock.unlock() }
        word = nil; held = nil; heldBytes = 0; epoch &+= 1
    }
}
