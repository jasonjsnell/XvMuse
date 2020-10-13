//
//  XvMuseEEGSensor.swift
//  XvMuse
//
//  Created by Jason Snell on 7/5/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

//MARK: Structs
//all-band, full spectrum Power Spectral Densities from the FFT

struct XvMuseEEGPsd {
    
    public init(magnitudes:[Double] = [], decibels:[Double] = []){
        self.magnitudes = magnitudes
        self.decibels = decibels
    }
    public var magnitudes:[Double] = []
    public var decibels:[Double] = []
}




/* Each sensor can return
 
 1) sensor's power spectral density from FFT
 2) magnitudes or decibels from any of the specific 5 brainwave bands
 
       TP9     AF7     AF8     TP10
                       ---      ---
delta   x       x     | x |    | x | < XvMuseEEGValue
theta   x       x     | x |     ---
alpha   x       x     | x |      x
beta    x       x     | x |      x
gamma   x       x     | x |      x
                       ___
                        ^
                 XvMuseEEGSensor
*/

public class XvMuseEEGSensor {
    
    //MARK: - DATA UPDATE -
    
    /*
     PSD 128 bins
     */
    
    //example: eeg.TP9.magnitudes
    //example: eeg.TP10.decibels
    
    //this is the entry point into the EEG system from the processed FFT data
    fileprivate var psd:XvMuseEEGPsd = XvMuseEEGPsd()
    internal func updatePsd(psd:XvMuseEEGPsd) {
        
        self.psd = psd
        
        if let min:Double = psd.decibels.min() {
            noise = Int(min)
            if (noise < 0){ noise = 0 }
        }
        
        //update the data in all the wave value objects owned by this sensor
        for wave in waves { wave.update(with: self) }
    }
    
    public var noise:Int = 10
    public var decibels:[Double] { get { return psd.decibels } }
    public var magnitudes:[Double] { get { return psd.magnitudes } }
    

    //MARK: - WAVES -
    
    //vars for calculating wave values on the fly
    //eeg.TP9.delta.decibel
    //eeg.TP10.alpha.magnitude
    
    public var waves:[XvMuseEEGValue]
    
    public var delta:XvMuseEEGValue = XvMuseEEGValue(waveID: 0)
    public var theta:XvMuseEEGValue = XvMuseEEGValue(waveID: 1)
    public var alpha:XvMuseEEGValue = XvMuseEEGValue(waveID: 2)
    public var beta: XvMuseEEGValue = XvMuseEEGValue(waveID: 3)
    public var gamma:XvMuseEEGValue = XvMuseEEGValue(waveID: 4)

    //MARK: - INIT
    init(){
        //store wave value in an array
        waves = [delta, theta, alpha, beta, gamma]
    }
    
    
    //MARK: - GETTERS -
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
