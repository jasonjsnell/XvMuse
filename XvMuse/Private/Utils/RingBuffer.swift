//
//  MusePPGBuffer.swift
//  XvMuse
//
//  Created by Jason Snell on 2/19/26.
//  Copyright © 2026 Jason Snell. All rights reserved.
//

// Simple fixed-capacity ring buffer for Double samples.
// Stores items in insertion order and provides O(1) append without shifting.
public struct RingBuffer<Element> {
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
}
