//
//  PeakDetector.swift
//  XvMuse
//
//  Created by Jason Snell on 10/19/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

public class PeakDetector {
    
    fileprivate let _analysisWindowSize:Int
    fileprivate let _restWindowMin:Int
    
    fileprivate var _restCount:Int = 0
    
    //anaylsis window size: how many of the recent samples are examined for a peak value
    //rest window min: how many rest signals need to happen before processor starts looking for a peak again
    //positive: look for positive peaks
    //negative: look for negative peaks
    public init(analysisWindowSize:Int, restWindowMin:Int){
        
        self._analysisWindowSize = analysisWindowSize
        self._restWindowMin = restWindowMin
    }
}

public class NegativePeakDetector:PeakDetector {
    
    public func getPeakAmplitude(peaks:[Int], rawSamples:[Double]) -> Double? {
        
        //examine the recent window of time, which is the end of the array
        let recentPeaks:[Int] = Array(
            peaks[
                peaks.count-_analysisWindowSize...peaks.count-1
            ]
        )
    
        //grab the lowest value
        if let peakMin:Int = recentPeaks.min() {
            
            //if a -1 is present and it's not right after a previous -1
            if (peakMin == -1 && _restCount > _restWindowMin) {
                
                //reset _rest
                _restCount = 0
                
                //get peak value
                let recentRawSamples:[Double] = Array(
                    rawSamples[
                        rawSamples.count-_analysisWindowSize...rawSamples.count-1
                    ]
                )
                
                //grab max
                if let rawSampleMin:Double = recentRawSamples.min() {
                    
                    //return amplitude
                    return rawSampleMin
                }
            
            } else {
                
                //increase _rest time
                _restCount += 1
            }
        }
    
        return nil
    }
    
}

public class PositivePeakDetector:PeakDetector {
    
    public func getPeakAmplitude(peaks:[Int], rawSamples:[Double]) -> Double? {
        
        //examine the recent window of time, which is the end of the array
        let recentPeaks:[Int] = Array(
            peaks[
                peaks.count-_analysisWindowSize...peaks.count-1
            ]
        )
    
        //grab the highest value
        if let peakMax:Int = recentPeaks.max() {
            
            //if a 1 is present and it's not right after a previous 1
            if (peakMax == 1 && _restCount > _restWindowMin) {
                
                //reset _rest
                _restCount = 0
                
                //get peak value
                let recentRawSamples:[Double] = Array(
                    rawSamples[
                        rawSamples.count-_analysisWindowSize...rawSamples.count-1
                    ]
                )
                
                //grab max
                if let rawSampleMax:Double = recentRawSamples.max() {
                    
                    //return amplitude
                    return rawSampleMax
                }
            
            } else {
                
                //increase _rest time
                _restCount += 1
            }
        }
    
        return nil
    }
}
