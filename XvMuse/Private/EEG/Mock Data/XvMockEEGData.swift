//
//  MockEEGData.swift
//  XvMuse
//
//  Created by Jason Snell on 4/29/22.
//  Copyright © 2022 Jason Snell. All rights reserved.
//

public class XvMockEEGData {
    
    public static let SET_TIRED:Int = 0
    public static let SET_MEDITATION:Int = 1
    public static let SET_STRESSED:Int = 2
    
    
    //helper classes
    fileprivate let _parser:Parser = Parser() //processes incoming data into useable / readable values
    fileprivate var _fft:FFT = FFT()
    fileprivate let _systemLaunchTime:Double = Date().timeIntervalSince1970
    
    internal init(){
        sensorsData = []
    }
    
    fileprivate var packetIndex:UInt16 = 0
    internal var sensorsData:[[[UInt8]]]
    fileprivate var byteCounters:[Int] = [0,0,0,0]
    
    func getPacket(for sensor:Int) -> XvMuseEEGPacket {
        
        //increase packet index within range of UInt16
        packetIndex += 1
        if (packetIndex >= UInt16.max) { packetIndex = 0 }
        
        //grab timestamp
        let timestamp:Double = Date().timeIntervalSince1970 - _systemLaunchTime
        
       return XvMuseEEGPacket(
            packetIndex: packetIndex,
            sensor: sensor,
            timestamp: timestamp,
            samples: _parser.getEEGSamples(
                from: _getMockBytes(for: sensor)
            )
        )
    }
    
    fileprivate func _getMockBytes(for sensor:Int) -> [UInt8] {
        
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
