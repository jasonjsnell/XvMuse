//
//  XvMusePPG.swift
//  XvMuse
//
//  Created by Jason Snell on 7/25/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation


public class XvMusePPGHeartEvent {
    
    public init(amplitude:Double = 0, currentBpm:Double = 0, averageBpm:Double = 0) {
        self.amplitude = amplitude
        self.currentBpm = currentBpm
        self.averageBpm = averageBpm
    }
    public var amplitude:Double
    public var currentBpm:Double
    public var averageBpm:Double
}

public class XvMusePPG {
    
    
    //MARK: Init
    
    init(){
        
        sensors = [XvMusePPGSensor(id:0), XvMusePPGSensor(id:1), XvMusePPGSensor(id:2)]
    
        _bpm = BeatsPerMinute()
        
        _npd = NegativePeakDetector(
            analysisWindowSize: 10,
            restWindowMin: 2
        )
        _sp = SignalProcessor(
            bins: sensors[1].sampleCount,
            threshold: threshold,
            lag: 10,
            influence: 0.5
        )
        
    }
    
    //MARK: Sensors
    public var sensors:[XvMusePPGSensor]

    //MARK: Data processors
    fileprivate let _sp:SignalProcessor
    fileprivate let _npd:NegativePeakDetector
    fileprivate let _bpm:BeatsPerMinute
    

    //MARK: Packet processing
    //basic update each time the PPG sensors send in new data
    
    internal func update(with ppgPacket:XvMusePPGPacket) -> XvMusePPGHeartEvent? {
        
        //send samples into the sensors
        
        //if signal packet is returned (doesn't happen until buffer is full)...
        if let signalPacket:PPGSignalPacket = sensors[ppgPacket.sensor].add(packet: ppgPacket) {
            
            //using sensor 1 (middle-range sensor) to calculate heartbeat
            if (ppgPacket.sensor == 1) {
                
                //do peak detection
                if let spPacket:SignalProcessorPacket = _sp.process(stream: signalPacket.samples) {
                    
                    //if a peak (heartbeat) is detected...
                    if let peakAmplitude:Double = _npd.getPeakAmplitude(peaks: spPacket.peaks, rawSamples: spPacket.raw) {
                        
                        //grab the current bpm with the curr timestamp
                        let bpmPacket:PPGBpmPacket = _bpm.update(with: ppgPacket.timestamp)
                     
                        //and return a heart event with peak and bpm data
                        return XvMusePPGHeartEvent(
                            amplitude: peakAmplitude,
                            currentBpm: bpmPacket.current,
                            averageBpm: bpmPacket.average
                        )
                    }
                }
            }
        }
        
        return nil
    }
    
    //MARK: peak detection threshold
    //test to tweak sensor sensitivity
    
    fileprivate var threshold:Double = 3.5 // techno, fast beat
    public func increaseHeartbeatPeakDetectionThreshold() {
        
        _sp.threshold += 0.1
        print("PPG: Peak detection threshold", _sp.threshold)
        
    }
    
    public func decreaseHeartbeatPeakDetectionThreshold() {
        
        _sp.threshold -= 0.1
        print("PPG: Peak detection threshold", _sp.threshold)
    }
    
}
