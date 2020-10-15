//
//  XvMusePPG.swift
//  XvMuse
//
//  Created by Jason Snell on 7/25/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation


public class XvMusePPGHeartEvent {
    
    public init(type:Int = -1, amplitude:Double = 0) {
        self.type = type //default is no event
        self.amplitude = amplitude //default zero
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
    
    
    //MARK: Init
    public var sensors:[XvMusePPGSensor]
    
    init(){
        sensors = [XvMusePPGSensor(id:0), XvMusePPGSensor(id:1), XvMusePPGSensor(id:2)]
        history = XvMuseEEGHistory()
    }
    
    //MARK: data processors
    fileprivate let _hba:HeartbeatAnalyzer = HeartbeatAnalyzer()
    fileprivate let _bpm:BeatsPerMinute = BeatsPerMinute()
    
    
    public var history:XvMuseEEGHistory
    
    //MARK: Packet processing
    //basic update each time the PPG sensors send in new data
    fileprivate var _currPacketIndex:UInt16 = 0
    fileprivate var _currFrequencySpectrums:[[Double]] = []
    
    internal func update(with ppgPacket:XvMusePPGPacket) -> PPGResult? {
        
        //send samples into the sensors
        
        //if frequency spectrum is returned (doesn't happen until buffer is full)...
        if let _frequencySpectrum:[Double] = sensors[ppgPacket.sensor].add(packet: ppgPacket) {
            
            //new packet index
            if (ppgPacket.packetIndex != _currPacketIndex) {
                
                //have a loaded pack of spectrums
                if (_currFrequencySpectrums.count == 3) {
                    
                    //combine them
                    if let _combinedFrequencySpectrums:[Double] = Number._getMaxByIndex(
                        arrays: _currFrequencySpectrums
                    ) {
                        
                        let slice1:Int = Int(_combinedFrequencySpectrums[5])
                        let slice2:Int = Int(_combinedFrequencySpectrums[6])
                        print(slice1, slice2)
                        if (slice1 == 0 && slice2 == 0) {
                            print("------------------------ rest")
                        } else if (slice2 == 0) {
                            print("------semirest")
                        }
                        
                        /*
                        //grab the heartbeat slice from spectrum
                        let slices:[Double] = [
                            _combinedFrequencySpectrums[6], _combinedFrequencySpectrums[8]
                        ]
                        
                        
                        if let heartEvent:XvMusePPGHeartEvent = _hba.getHeartEvent(from: slice) {
                            
                            //have bpm detected by time between resting event
                            if heartEvent.type == XvMuseConstants.PPG_RESTING {
                                
                                let bpmPacket:XvMusePPGBpmPacket = _bpm.update(with: ppgPacket.timestamp)
                                return PPGResult(heartEvent: heartEvent, bpmPacket: bpmPacket)
                            }
                            
                            //else send back a heart event with no bpm packet
                            return PPGResult(heartEvent: heartEvent, bpmPacket: nil)
                        }*/
                    }
                }
                
                //first packet or incomplete packet
                _currFrequencySpectrums = []
                
                //update the curr index
                _currPacketIndex = ppgPacket.packetIndex
                
            }
            
            //same packet index
            //keep adding to array
            _currFrequencySpectrums.append(_frequencySpectrum)
            
        }
        
        return nil
    }
    
    //MARK: Noise floor
    //test to tweak sensor sensitivity
    public func raiseNoiseFloor() -> Double {
        
        var db:Double = 0
        
        for sensor in sensors {
            db = sensor.raiseNoiseFloor()
        }
        
        return db
    }
    
    public func lowerNoiseFloor() -> Double {
        
        var db:Double = 0
        
        for sensor in sensors {
            db = sensor.lowerNoiseFloor()
        }
        return db
    }
    
}
