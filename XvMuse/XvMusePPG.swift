//
//  XvMusePPG.swift
//  XvMuse
//
//  Created by Jason Snell on 7/25/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation


public class XvMusePPGHeartEvent {
    
    public init(type:Int = 0, amplitude:Double = 0) {
        self.type = type
        self.amplitude = amplitude
    }
    public var type:Int
    public var amplitude:Double
}

public struct XvMusePPGBpmPacket {
    public var current:Double
    public var average:Double
}

internal struct PPGResult {
    public var heartEvent:XvMusePPGHeartEvent
    public var bpmPacket:XvMusePPGBpmPacket?
}

public class XvMusePPG {
    
    public func add() -> Float {
        return sensors[1].add()
    }
    public func reduce() -> Float {
        return sensors[1].reduce()
    }
    
    public var sensors:[XvMusePPGSensor]
    
    init(){
        sensors = [XvMusePPGSensor(id:0), XvMusePPGSensor(id:1), XvMusePPGSensor(id:2)]
    }
    
    //basic update each time the PPG sensors send in new data
    internal func update(with ppgPacket:XvMusePPGPacket) -> PPGResult? {
        
        //send samples into the sensors
        return sensors[ppgPacket.sensor].add(packet: ppgPacket)
        
    }
    
}
