//
//  HeartbeatMonitor.swift
//  XvMuse
//
//  Created by Jason Snell on 7/27/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

class HeartbeatAnalyzer {
    
    fileprivate var rest:Int = 0
    fileprivate var S1:Bool = false
    fileprivate var S2:Bool = false
    
    fileprivate let RECENT_MAX:Int = 16
    fileprivate var recentS1:[Double] = []
    fileprivate var recentS2:[Double] = []
    
    fileprivate let analysisWindow:Int = 10
    fileprivate let restWindowMin:Int = 2
    
    internal func getHeartbeatAmplitude(peaks:[Int], values:[Double]) -> Double? {
        
        //examine the recent window of time, which is the end of the array
        let recentPeaks:[Int] = Array(
            peaks[
                peaks.count-analysisWindow...peaks.count-1
            ]
        )
        
        //grab the lowest value
        if let peakMin:Int = recentPeaks.min() {
            
            //if a -1 is present and it's not right after a previous -1
            if (peakMin == -1 && rest > restWindowMin) {
                
                //reset rest
                rest = 0
                
                //get peak value
                let recentValues:[Double] = Array(
                    values[
                        values.count-analysisWindow...values.count-1
                    ]
                )
                
                //grab max
                if let valueMax:Double = recentValues.max() {
                    
                    //return amplitude
                    return valueMax
                }
            
            } else {
                
                //increase rest time
                rest += 1
            }
        }
    
        return nil
    }
}
