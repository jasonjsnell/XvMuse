//
//  MockPPGData.swift
//  XvMuse
//
//  Created by Jason Snell on 4/29/22.
//  Copyright © 2022 Jason Snell. All rights reserved.
//

import Foundation

class MockPPGData {
    
    //helper classes
    fileprivate let _parser:Parser = Parser() //processes incoming data into useable / readable values
    fileprivate let _systemLaunchTime:Double = Date().timeIntervalSince1970
    
    fileprivate var packetIndex:UInt16 = 0
    fileprivate var byteCounter:Int = 0
    
    internal init(){
        SENSOR_1_DATA = []
    }
    
    func getPacket() -> XvMusePPGPacket {
        
        //increase packet index within range of UInt16
        packetIndex += 1
        if (packetIndex >= UInt16.max) { packetIndex = 0 }
        
        //grab timestamp
        let timestamp:Double = Date().timeIntervalSince1970 - _systemLaunchTime
        
        return XvMusePPGPacket(
            packetIndex: packetIndex,
            sensor: 1,
            timestamp: timestamp,
            samples: _parser.getPPGSamples(from: _getMockBytes()))
    }
    
    fileprivate func _getMockBytes() -> [UInt8] {
        
        //increase count
        byteCounter += 1
        
        //if more than the length of byte array
        if (byteCounter >= SENSOR_1_DATA.count){
            //move to beginning of array
            byteCounter = 0
        }
        //return data
        return SENSOR_1_DATA[byteCounter]
    }
    
    internal var SENSOR_1_DATA:[[UInt8]]
}

