//
//  MusePPGBuffer.swift
//  XvMuse
//
//  Created by Jason Snell on 2/19/26.
//  Copyright © 2026 Jason Snell. All rights reserved.
//

// Simple fixed-capacity ring buffer for Double samples.
// Stores items in insertion order and provides O(1) append without shifting.
internal struct RingBuffer {
    private var storage: [Double]
    private var head: Int = 0          // next write position
    private(set) var count: Int = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.storage = Array(repeating: 0.0, count: self.capacity)
    }

    mutating func append(_ value: Double) {
        storage[head] = value
        head = (head + 1) % capacity
        if count < capacity { count += 1 }
    }

    // Returns all elements in chronological (oldest -> newest) order.
    func toArray() -> [Double] {
        guard count > 0 else { return [] }
        if count < capacity {
            return Array(storage[0..<count])
        }
        // When full, oldest element is at `head`.
        return Array(storage[head..<capacity]) + Array(storage[0..<head])
    }

    // Returns the last `n` elements in chronological order.
    func last(_ n: Int) -> [Double] {
        let arr = toArray()
        guard n < arr.count else { return arr }
        return Array(arr[(arr.count - n)..<arr.count])
    }
}
