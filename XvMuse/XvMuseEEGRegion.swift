//
//  XvMuseEEGRegion.swift
//  XvMuse
//
//  Created by Jason Snell on 7/11/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

/*
                   HEAD
left-side < < < < <   > > > > > > right-side
 
       TP9     AF7     AF8    TP10  < XvMuseEEGSensor
        ^       ^       ^       ^
       side   front   front   side  < XvMuseEEGRegions
*/

import Foundation

public class XvMuseEEGRegion {
    
    /*
     examples:
     eeg.front.decibels
     eeg.sides.magnitudes
     
     returns full PSDS
     */
    
    // front sensors will be 1 and 2
    // side  sensors will be 0 and 3
    // left  sensors will be 0 and 1
    // right sensors will be 2 and 3
    
    fileprivate var sensors:[XvMuseEEGSensor]
    init(with sensors:[XvMuseEEGSensor]) {
        self.sensors = sensors
        
        //pass the sensors into each wave value object
        delta.assign(sensors: sensors)
        theta.assign(sensors: sensors)
        alpha.assign(sensors: sensors)
        beta.assign(sensors: sensors)
        gamma.assign(sensors: sensors)
        
        waves = [delta, theta, alpha, beta, gamma]
    }
    
    public var magnitudes: [Double] {
        
        get {
        
            //grab magnitude arrays from the two sensors
            //average each index value of each array,
            //and output an array of averaged values for all the sensors combined
            if let sensorAveragedMagnitudes:[Double] = Number.getAverageByIndex(arrays: sensors.map { $0.magnitudes }) {
                
                return sensorAveragedMagnitudes
            } else {
                
                print("XvMuseEEGRegion: Error: Unable to calculate averaged magnitudes of region sensors")
                return []
            }
        }
    }
    
    public var decibels: [Double] {
        
        get {
        
            //same as magnitudes above
            if let sensorAveragedDecibels:[Double] = Number.getAverageByIndex(arrays: sensors.map { $0.decibels }) {
                
                return sensorAveragedDecibels
            } else {
                
                print("XvMuseEEGRegion: Error: Unable to calculate averaged decibels of region sensors")
                return []
            }
        }
    }
    
    //MARK: Waves
    public var waves:[XvMuseEEGValue]
    public var delta:XvMuseEEGValue = XvMuseEEGValue(waveID: 0)
    public var theta:XvMuseEEGValue = XvMuseEEGValue(waveID: 1)
    public var alpha:XvMuseEEGValue = XvMuseEEGValue(waveID: 2)
    public var beta: XvMuseEEGValue = XvMuseEEGValue(waveID: 3)
    public var gamma:XvMuseEEGValue = XvMuseEEGValue(waveID: 4)
    
    
    //MARK: Accessing custom frequency ranges
    
    fileprivate let _fm:FrequencyManager = FrequencyManager.sharedInstance
    
    
    //MARK: Get bin slices
    
    public func getDecibelSlice(fromBinRange:[Int]) -> [Double] {
        
        return _fm.getSlice(bins: fromBinRange, spectrum: decibels)
    }
    
    public func getMagnitudeSlice(fromBinRange:[Int]) -> [Double] {
        
        return _fm.getSlice(bins: fromBinRange, spectrum: magnitudes)
    }
    
    //MARK: Get spectrum slices
    public func getDecibelSlice(fromFrequencyRange:[Double]) -> [Double] {
        
        return _fm.getSlice(frequencyRange: fromFrequencyRange, spectrum: decibels)
    }
    
    public func getMagnitudeSlice(fromFrequencyRange:[Double]) -> [Double] {
        
        return _fm.getSlice(frequencyRange: fromFrequencyRange, spectrum: magnitudes)
    }
    
    
    //MARK: Get wave value via frequency range
    public func getDecibel(fromFrequencyRange:[Double]) -> Double {
        
        return _fm.getWaveValue(frequencyRange: fromFrequencyRange, spectrum: decibels)
    }
    
    public func getMagnitude(fromFrequencyRange:[Double]) -> Double {
        
        return _fm.getWaveValue(frequencyRange: fromFrequencyRange, spectrum: magnitudes)
    }
    
    
    //MARK: Get wave value via bins
    public func getDecibel(fromBinRange:[Int]) -> Double {
        
        return _fm.getWaveValue(bins: fromBinRange, spectrum: decibels)
    }
    
    public func getMagnitude(fromBinRange:[Int]) -> Double {
        
        return _fm.getWaveValue(bins: fromBinRange, spectrum: magnitudes)
    }
    
    
}
