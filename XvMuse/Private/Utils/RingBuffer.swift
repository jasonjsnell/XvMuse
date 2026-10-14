//
//  MusePPGBuffer.swift
//  XvMuse
//
//  Created by Jason Snell on 2/19/26.
//  Copyright © 2026 Jason Snell. All rights reserved.
//

// Simple fixed-capacity ring buffer for Double samples.
// Stores items in insertion order and provides O(1) append without shifting.
//Internal: used only by the FFT buffers inside this framework.
internal struct RingBuffer<Element> {
    private var storage: [Element]
    private var head: Int = 0          // next write position
    private(set) var count: Int = 0
    let capacity: Int

    init(capacity: Int, defaultValue: Element) {
        self.capacity = max(1, capacity)
        self.storage = Array(repeating: defaultValue, count: self.capacity)
    }
    
    init(capacity: Int) where Element: ExpressibleByIntegerLiteral {
        self.capacity = max(1, capacity)
        self.storage = Array(repeating: 0, count: self.capacity)
    }

    mutating func append(_ value: Element) {
        storage[head] = value
        head = (head + 1) % capacity
        if count < capacity { count += 1 }
    }

    // Returns all elements in chronological (oldest -> newest) order.
    func toArray() -> [Element] {
        guard count > 0 else { return [] }
        if count < capacity {
            return Array(storage[0..<count])
        }
        // When full, oldest element is at `head`.
        return Array(storage[head..<capacity]) + Array(storage[0..<head])
    }

    // Returns the last `n` elements in chronological order.
    func last(_ n: Int) -> [Element] {
        let arr = toArray()
        guard n < arr.count else { return arr }
        return Array(arr[(arr.count - n)..<arr.count])
    }

    // Newest element, nil when empty. O(1), the same value toArray().last gives (13 Oct 2026).
    var last: Element? {
        guard count > 0 else { return nil }
        return storage[(head - 1 + capacity) % capacity]
    }

    // Oldest element, nil when empty. O(1), the same value toArray().first gives (13 Oct 2026).
    var first: Element? {
        guard count > 0 else { return nil }
        return count < capacity ? storage[0] : storage[head]
    }

    // Writes every element, oldest first, into `out`: the same order toArray() returns, with no
    // intermediate arrays. `out` must have room for `count` elements. The destination is treated
    // as uninitialised memory (EpochGenerator passes the closure buffer of
    // Array(unsafeUninitializedCapacity:)), so each slot is initialised rather than assigned.
    // For a trivial Element such as Double the write is the same either way (13 Oct 2026).
    func copyChronological(into out: UnsafeMutableBufferPointer<Element>) {
        guard count > 0, let base = out.baseAddress else { return }
        precondition(out.count >= count, "RingBuffer.copyChronological: destination too small")
        if count < capacity {
            for i in 0..<count { (base + i).initialize(to: storage[i]) }
            return
        }
        // When full, oldest element is at `head`.
        var written = 0
        for i in head..<capacity { (base + written).initialize(to: storage[i]); written += 1 }
        for i in 0..<head { (base + written).initialize(to: storage[i]); written += 1 }
    }
}
