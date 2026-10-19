import Foundation
import os

final class PendingFrameBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<JointFrame?>(initialState: nil)

    func set(_ frame: JointFrame) {
        lock.withLock { $0 = frame }
    }

    func take() -> JointFrame? {
        lock.withLock {
            let cur = $0
            $0 = nil
            return cur
        }
    }

    func clear() {
        lock.withLock { $0 = nil }
    }
}
