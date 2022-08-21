//
//  XvMusePPG.swift
//  XvMuse
//
//  Created by Jason Snell on 7/25/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation


internal class MusePPGHeartEvent {
    
    public init(amplitude:Double = 0.0, bpm:Double = 0.0, hrv:Double = 0.0) {
        self.amplitude = amplitude
        self.bpm = bpm
        self.hrv = hrv
    }
    public var amplitude:Double
    public var bpm:Double
    public var hrv:Double
}

internal class MusePPG {
    
    //MARK: Init
    
    init(){
        sensors = [MusePPGSensor(id:0), MusePPGSensor(id:1), MusePPGSensor(id:2)]
        _ppgAnalyzer = PPGAnalyzer()
        buffer = []
    }
    
    public var buffer:[Double]
    internal var sensors:[MusePPGSensor]

    fileprivate let _ppgAnalyzer:PPGAnalyzer
    fileprivate var prevAvg:Double = 0.0
    fileprivate var upwardsMomentum:Int = 0
    fileprivate var downwardsMomentum:Int = 0
    fileprivate var beatOn:Bool = false
    
    //MARK: Packet processing
    //basic update each time the PPG sensors send in new data
    
    internal func getHeartEvent(from ppgPacket:MusePPGPacket) -> MusePPGHeartEvent? {
        
        //generate buffer and return
        if let buffer:[Double] = sensors[1].getBuffer(from: ppgPacket) {
            
            //save buffer for direct access via the XvMusePPG object
            self.buffer = buffer
            
            //grab the last few values in the buffer
            let recentValues:[Double] = Array(buffer[(buffer.count-5)...])
            
            //average these last few values to smooth out deep spikes or dips
            let avg:Double = recentValues.reduce(0, +) / Double(recentValues.count)
            
            //if the curr average is more than the prev render's average...
            if (avg > prevAvg) {
                
                upwardsMomentum += 1 //increase the upwards momentum
                downwardsMomentum = 0 //remove the downwards momentum
                
                //if upwards momentum is strong enough...
                if (upwardsMomentum > 2) {
                    
                    //and the beat isn't currently on
                    if (!beatOn) {
                        
                        //beat is on
                        beatOn = true
                        
                        //update the previous value with the current
                        prevAvg = avg
                        
                        //grab the current bpm and hrv with the curr timestamp
                        let ppgAnalysisPacket:PPGAnalysisPacket = _ppgAnalyzer.update(with: ppgPacket.timestamp)
                        
                        //and return a heart event with peak and bpm data
                        return MusePPGHeartEvent(
                            amplitude: recentValues.max()!, //return the highest value from the recent values in buffer
                            bpm: ppgAnalysisPacket.bpm,
                            hrv: ppgAnalysisPacket.hrv
                        )
                    }
                }
                //print(">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>")
                
            } else if (avg < prevAvg) {
                
                //else if the average is less..
                
                upwardsMomentum = 0 //remove the upwards momentum
                downwardsMomentum += 1 //increase the downwards momentum
                
                //if downwards momentum is strong enough (the value of 1 instead of 2 (like above in upwards) performed with better results in testing)
                if (downwardsMomentum > 1) {
                    if (beatOn) { beatOn = false } //if the beat is on, turn it off
                }
                //print("<<")
            }
            
            //update the previous value with the current
            prevAvg = avg
        }
        
        //no heartbeat event this round
        return nil
    }
}
