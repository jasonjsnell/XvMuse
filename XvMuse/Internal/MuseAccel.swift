//
//  MuseAccel.swift
//  XvMuse
//
//  Created by Jason Snell on 2/21/26.
//  Copyright © 2026 Jason Snell. All rights reserved.
//

import Foundation

struct MuseAccelPacket{
    var x:Double
    var y:Double
    var z:Double
    var movement:Double
    
    init(x:Double, y:Double, z:Double) {
        self.x = x
        self.y = y
        self.z = z
        movement = 0;
    }
}

internal class MuseAccel {
    
    private var xBuf = RingBuffer<Double>(capacity: 32)
    private var yBuf = RingBuffer<Double>(capacity: 32)
    private var zBuf = RingBuffer<Double>(capacity: 32)
    
    private let fullRange: Double = 0.6 // range mapped to movement = 1.0
    private let noiseFloor: Double = 0.02 // range below this maps to 0.0
    
    init() {}
    
    private func range(of buffer: RingBuffer<Double>) -> Double {
        let arr = buffer.toArray()
        guard let minV = arr.min(), let maxV = arr.max() else { return 0 }
        return maxV - minV
    }
    
    internal func update(withAccelPacket: MuseAccelPacket) -> MuseAccelPacket {
        
        xBuf.append(withAccelPacket.x)
        yBuf.append(withAccelPacket.y)
        zBuf.append(withAccelPacket.z)
        
        let rx = range(of: xBuf)
        let ry = range(of: yBuf)
        let rz = range(of: zBuf)
        
        let r = sqrt(rx*rx + ry*ry + rz*rz)
        
        let norm = max(0, (r - noiseFloor) / max(1e-9, (fullRange - noiseFloor)))
        let clampedNorm = min(1.0, max(0.0, norm))
        
        var packet = withAccelPacket
        packet.movement = clampedNorm
        
        return packet
    }
    
}
