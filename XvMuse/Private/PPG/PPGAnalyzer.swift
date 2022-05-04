//
//  BeatsPerMinute.swift
//  XvMuse
//
//  Created by Jason Snell on 7/27/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

struct PPGAnalysisPacket {
    var bpm:Double
    var hrv:Double
    
    init(bpm:Double, hrv:Double) {
        self.bpm = bpm
        self.hrv = hrv
    }
}
class PPGAnalyzer {
    
    fileprivate var prevTimestamp:Double = 0
    fileprivate var bpms:[Double] = []
    fileprivate var beatLengths:[Double] = []
    fileprivate let BPM_HISTORY_LENGTH_MAX:Int = 100
    fileprivate let HRV_HISTORY_LENGTH_MAX:Int = 50

    internal func update(with timestamp:Double) -> PPGAnalysisPacket {
        
        //get the length of the beat by looking at the diff between the current time and the last time this func ran
        let beatLength:Double = timestamp - prevTimestamp
        
        //MARK: HRV
        //using SDANN to calculate milliseconds
        //SDANN = standard deviation of the average normal-to-normal
        
        //record beatLengths into an array
        beatLengths.append(beatLength)
        
        //init var
        var hrv:Double = 0.0
        
        //only calculate HRV once the a significant history has been filled
        if (beatLengths.count > HRV_HISTORY_LENGTH_MAX) {
            beatLengths.removeFirst()
            hrv = Number.getStandardDeviation(ofArray: beatLengths) * 1000
        }
        
        //MARK: BPM
        let currBpm:Double = 60 / beatLength
        
        //add to array and keep array the correct length
        bpms.append(currBpm)
        if (bpms.count > BPM_HISTORY_LENGTH_MAX){ bpms.removeFirst() }
        
        // average the array
        let averageBpm:Double = bpms.reduce(0, +) / Double(bpms.count)
        
        //update timestamp
        prevTimestamp = timestamp
        
        return PPGAnalysisPacket(bpm: averageBpm, hrv: hrv)
    
    }
    
}
