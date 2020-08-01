//
//  HeartbeatMonitor.swift
//  XvMuse
//
//  Created by Jason Snell on 7/27/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

class HeartbeatAnalyzer {
    
    fileprivate var rest:Bool = false
    fileprivate var S1:Bool = false
    fileprivate var S2:Bool = false
    
    fileprivate let RECENT_MAX:Int = 16
    fileprivate var recentS1:[Double] = []
    fileprivate var recentS2:[Double] = []
    
    
    
    internal func getHeartEvent(from slice:[Double]) -> XvMusePPGHeartEvent? {
        
        //slice needs to be 2 in length
        //bins 0 is atrioventricular
        //bins 1 is semilunar
        
        if (slice.count == 2){
            
            let S1Value:Double = slice[0]
            let S2Value:Double = slice[1]
            let sum = S1Value + S2Value
            
            if (sum == 0 && !rest) {
                
                //entire wave has come down and rested to zero
                rest = true
                S1 = false
                S2 = false
                
                return XvMusePPGHeartEvent(
                    type: XvMuseConstants.PPG_RESTING,
                    amplitude: 0
                )
            
            } else if (S1Value > S2Value && !S1) {
                
                //lower frequency part of wave is dominant
                //this is the dominant LUB sound, atrioventricular
                rest = false
                S1 = true
                S2 = false
                
                //add to array
                recentS1.append(S1Value)
                if (recentS1.count > RECENT_MAX) { recentS1.removeFirst() }
                
                //get normalized value
                let normalizedS1:Double = normalize(value: S1Value, in: recentS1)
                
                
                               
                return XvMusePPGHeartEvent(
                    type: XvMuseConstants.PPG_S1_EVENT,
                    amplitude: normalizedS1
                )
                
            } else if (S2Value > S1Value && !S2) {
                
                //higher frequency part of the wave is dominant
                //this is the dominant DUB sound, semilunar
                rest = false
                S1 = false
                S2 = true
                
                //add to array
                recentS2.append(S2Value)
                if (recentS2.count > RECENT_MAX) { recentS2.removeFirst() }
                
                //get normalized value
                let normalizedS2:Double = normalize(value: S2Value, in: recentS2)
                
                return XvMusePPGHeartEvent(
                    type: XvMuseConstants.PPG_S2_EVENT,
                    amplitude: normalizedS2
                )
            }
            
        } else {
            print("PPG: Error: Frequency spectrum slice is incorrect length")
            return nil
        }
        
        return nil
    }
    
    //MARK: Subs
    fileprivate func normalize(value:Double, in array:[Double]) -> Double {
        
        var normalizedValue = value
        
        if let max:Double = array.max() {
            normalizedValue = value / max
        }
        
        return normalizedValue
    }
}
