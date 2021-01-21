//
//  BeatsPerMinute.swift
//  XvMuse
//
//  Created by Jason Snell on 7/27/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

struct PPGBpmPacket {
    var current:Double
    var average:Double
    
    init(current:Double, average:Double) {
        self.current = current
        self.average = average
    }
}
class BeatsPerMinute {
    
    fileprivate var prevTimestamp:Double = 0
    fileprivate var bpms:[Double] = []
    fileprivate let BPM_HISTORY_LENGTH:Int = 100

    internal func update(with timestamp:Double) -> PPGBpmPacket {
        
        //get the length of the beat by looking at the diff between the current time and the last time this func ran
        let beatLength:Double = timestamp - prevTimestamp
        
        //calc bpm
        let currBpm:Double = 60 / beatLength
        
        /*if let lastBpm:Double = bpms.last {
            if (currBpm < lastBpm * 0.75) {
                currBpm = lastBpm
            }
        }*/
        
        //add to array and keep array the correct length
        bpms.append(currBpm)
        if (bpms.count > BPM_HISTORY_LENGTH){ bpms.removeFirst() }
        
        // average the array
        let averageBpm:Double = bpms.reduce(0, +) / Double(bpms.count)
        
        //update timestamp
        prevTimestamp = timestamp
        
        return PPGBpmPacket(current: currBpm, average: averageBpm)
    
    }
    
}
