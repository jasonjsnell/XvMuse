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
    
    //MARK: - INIT -
    public var waves:[XvMuseEEGValue]
    public var delta:XvMuseEEGValue = XvMuseEEGValue(waveID: 0)
    public var theta:XvMuseEEGValue = XvMuseEEGValue(waveID: 1)
    public var alpha:XvMuseEEGValue = XvMuseEEGValue(waveID: 2)
    public var beta: XvMuseEEGValue = XvMuseEEGValue(waveID: 3)
    public var gamma:XvMuseEEGValue = XvMuseEEGValue(waveID: 4)
    
    init() {
        
        //init waves array
        waves = [delta, theta, alpha, beta, gamma]
    }
    
    //MARK: - DATA UPDATES -
    internal func update(with sensors:[XvMuseEEGSensor]){
        
        //update averaging processors
        _cache.update(with: sensors)
        
        //update this regions wave value objects
        for wave in waves {
            wave.update(with: sensors)
        }
    }
    
    //MARK: - AVERAGED VALUES -
    
    fileprivate var _cache:SensorCache = SensorCache()
    
    public var magnitudes:[Double] { get { return _cache.getMagnitudes() } }
    public var decibels:[Double] {   get { return _cache.getDecibels()   } }
    public var noise:Int {           get { return _cache.getNoise()      } }
    
    //MARK: - ACCESS CUSTOM FREQ RANGES -
    
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
