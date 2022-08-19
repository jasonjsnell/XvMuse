//
//  XvMuseEEGSensor.swift
//  XvMuse
//
//  Created by Jason Snell on 7/5/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

public class XvMuseEEGSensor {
    
    //MARK: - DATA UPDATE -
    //example: eeg.TP10.decibels
    
    //this is the entry point into the EEG system from the processed FFT data
    internal func update(spectrum:[Double]) {
        self._spectrum = spectrum
    }
    
    public var spectrum:[Double] { get { return _spectrum } }
    fileprivate var _spectrum:[Double] = [0]
    
    //Special setters for combining EEG objects into a multi-user eeg
    public func set(spectrum:[Double]) { _spectrum = spectrum }

    
    //MARK: - INIT
    init(){}
    
    
    //MARK: - GETTERS -
    //MARK: Accessing custom frequency ranges
    
    //fileprivate let _fm:FrequencyManager = FrequencyManager.sharedInstance
    
    //MARK: Get bin slices
//    public func getDecibelSlice(fromBinRange:[Int]) -> [Double] {
//        return _fm.getSlice(bins: fromBinRange, spectrum: decibels)
//    }
    
//    public func getDecibel(fromBin:Int) -> Double {
//        return _fm.getDecibel(fromBin: fromBin, spectrum: decibels)
//    }
    
    //MARK: Get spectrum slices
//    public func getDecibelSlice(fromFrequencyRange:[Double]) -> [Double] {
//        return _fm.getSlice(frequencyRange: fromFrequencyRange, spectrum: decibels)
//    }
    
    //MARK: Get wave value via frequency range
//    public func getDecibel(fromFrequencyRange:[Double]) -> Double {
//        return _fm.getWaveValue(frequencyRange: fromFrequencyRange, spectrum: decibels)
//    }
    
    //MARK: Get wave value via bins
//    public func getDecibel(fromBinRange:[Int]) -> Double {
//        return _fm.getWaveValue(bins: fromBinRange, spectrum: decibels)
//    }
}
