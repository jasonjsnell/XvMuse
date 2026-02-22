//
//  TestEEGData.swift
//  XvMuse
//
//  Created by Jason Snell on 4/29/22.
//  Copyright © 2022 Jason Snell. All rights reserved.
//

class TestEEGData {
    
    public static let SET_TIRED:Int = 0
    public static let SET_MEDITATION:Int = 1
    public static let SET_STRESSED:Int = 2
    
    
    //helper classes
    private let _parser:ParserLegacy = ParserLegacy() //processes incoming data into useable / readable values
    private var _fft:FFTManager = FFTManager()
    private let _systemLaunchTime:Double = Date().timeIntervalSince1970
    
    private var name:String
    internal init(name:String){
        self.name = name
        sensorsData = []
    }
    internal func getName() -> String {
        return self.name
    }
    
    private var packetIndex:UInt16 = 0
    internal var sensorsData:[[[UInt8]]]
    private var byteCounters:[Int] = [0,0,0,0]
    
    func getPacket(for sensor:Int) -> MuseEEGPacket {
        
        //increase packet index within range of UInt16
        packetIndex += 1
        if (packetIndex >= UInt16.max) { packetIndex = 0 }
        
        //grab timestamp
        let timestamp:Double = Date().timeIntervalSince1970 - _systemLaunchTime
        
       return MuseEEGPacket(
            packetIndex: packetIndex,
            sensor: sensor,
            timestamp: timestamp,
            samples: _parser.getEEGSamples(
                from: _getTestBytes(for: sensor)
            )
        )
    }
    
    private func _getTestBytes(for sensor:Int) -> [UInt8] {
        
        //increase count
        byteCounters[sensor] += 1
        
        //if more than the length of byte array
        if (byteCounters[sensor] >= sensorsData[sensor].count){
            //move to beginning of array
            byteCounters[sensor] = 0
        }
        //return data
        return sensorsData[sensor][byteCounters[sensor]]
    }
    
    
}
