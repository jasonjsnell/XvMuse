//
//  FrequencyManager.swift
//  XvMuse
//
//  Created by Jason Snell on 7/4/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

class FrequencyManager {
    
    public var bins:[[Int]] = []
    
    fileprivate var frequencies:[Double]
    
    public static let sharedInstance = FrequencyManager()
       
    fileprivate init() {
        
        let freqInc:Double = XvMuseConstants.SAMPLING_RATE / Double(XvMuseConstants.EEG_FFT_BINS)
        let freqRange:Array<Int> = Array(0...XvMuseConstants.EEG_FFT_BINS/2)
        
        frequencies = freqRange.map { Double($0) * freqInc }
        
        //put calculated bins into a public array
        bins = [
            getBinsFor(frequencyRange: XvMuseConstants.FREQUENCY_BAND_DELTA),
            getBinsFor(frequencyRange: XvMuseConstants.FREQUENCY_BAND_THETA),
            getBinsFor(frequencyRange: XvMuseConstants.FREQUENCY_BAND_ALPHA),
            getBinsFor(frequencyRange: XvMuseConstants.FREQUENCY_BAND_BETA),
            getBinsFor(frequencyRange: XvMuseConstants.FREQUENCY_BAND_GAMMA)
        ]        
    }
    
    // MARK: - PRESET BANDS -
    // Delta Theta Alpha Bete Gamma
    
    let waveValueQueue:DispatchQueue = DispatchQueue(label: "waveValueQueue")
   
            
            
    internal func getWaveValue(waveID:Int, spectrum:[Double]) -> Double {
        
        //use queue to avoid fatal errors
        //examples
        //ERROR: Thread 1: EXC_BAD_ACCESS (code=1, address=0x8)
        //ERROR: Expected expression in list of expressions
        //these occur when too many sources call this func
        waveValueQueue.sync {
            
            //if the spectrum is populated...
            if (spectrum.count > 0) {
                
                //get the location of where to begin and end the spectrum slice
                let waveBins:[Int] = bins[waveID]
                //TODO: ERROR
                //print("waveBin", waveBins)
                //slice the spectrum piece out
                
                let slice:[Double] = Array(spectrum[waveBins[0]...waveBins[1]])
                
                //average it
                return slice.reduce(0, +) / Double(slice.count)
            
            } else {
                
                return 0.0
            }
        }
    }
    
    // MARK: - CUSTOM BANDS -
    
    // MARK: Get spectrum slice from frequency range
    internal func getSlice(frequencyRange:[Double], spectrum:[Double]) -> [Double] {
        
        //MARK: Error checking on spectrum
        
        //spectrum needs to have data
        if (spectrum.count == 0) { return [] }
        
        
        //MARK: Error checking on frequency range
        
        //range needs to be 2 values
        if (frequencyRange.count != 2) {
            print("XvMuse: FrequencyManager: Error: Range needs to be 2 items in length")
            return []
        }
        
        //if they are equal, there is no wave value, return 0
        if (frequencyRange[0] == frequencyRange[1]) { return [] }
        
        //order the values as [low, high] regardless of how they come in
        var range:[Double] = []
        
        if (frequencyRange[0] < frequencyRange[1]){
            range = [frequencyRange[0], frequencyRange[1]]
        } else {
            range = [frequencyRange[1], frequencyRange[0]]
        }
        
        //if high value is above the max, make it the max
        if (range[1] >= XvMuseConstants.SAMPLING_RATE/2) { range[1] = 109.0 }
        
        
        //MARK: Get bins
        //get the custom bins
        let bins:[Int] = getBinsFor(frequencyRange: range)
        

        return getSlice(bins: bins, spectrum: spectrum)
        
    }
    
    // MARK: Get spectrum slice from bin range
    internal func getSlice(bins:[Int], spectrum:[Double]) -> [Double] {
        
        //MARK: Error checking on spectrum
        //make sure spectrum has conten
        if (spectrum.count == 0) { return [] }
        
        //MARK: Error checking on bins
        //convert let to var
        var bins:[Int] = bins
        
        //Make sure the top bin is less than the spectrum max length
        if (bins[1] >= spectrum.count){ bins[1] = spectrum.count-1 }
        
        //make sure spectrum has data to assess
        if (spectrum.count < bins[1]) { return [] }
        
        //make sure its 2 bin values
        if (bins.count != 2){ return []}
        
        //make sure bins are in order [low, high]
        if (bins[0] > bins[1]){
            bins = [bins[1], bins[0]] //reverse order
        }
    
        //MARK: Process the slice
        //slice the spectrum piece out
        return Array(spectrum[bins[0]...bins[1]])
        
    }
    
    // MARK: Get wave value slice from frequency range
    internal func getWaveValue(frequencyRange:[Double], spectrum:[Double]) -> Double {
        
        //get slice
        let slice:[Double] = getSlice(frequencyRange: frequencyRange, spectrum: spectrum)
    
        //average it
        return slice.reduce(0, +) / Double(slice.count)
    }
    
    // MARK: Get wave value slice from bin range
    internal func getWaveValue(bins:[Int], spectrum:[Double]) -> Double {
        
        let slice:[Double] = getSlice(bins: bins, spectrum: spectrum)
        
        //average it
        var waveValue:Double = slice.reduce(0, +) / Double(slice.count)
        
        //clean it
        if (waveValue.isInfinite || waveValue.isNaN) {
            waveValue = 0
        }
        
        return waveValue
    }
    
    
    
    //MARK: get bin slots from frequency range
    internal func getBinsFor(frequencyRange:[Double]) -> [Int] {
        
        var bins:[Int] = []
        
        for f in frequencyRange {
            bins.append(getBinFor(frequency: f))
        }
        
        return bins
    }
    
    
    //get an index of a frequency
    fileprivate func getBinFor(frequency:Double) -> Int {
        
        if let closest:EnumeratedSequence<[Double]>.Element = frequencies.enumerated().min(
            by: { abs($0.1 - frequency) < abs($1.1 - frequency)}) {
            
            return closest.offset
            
        } else {
            
            print("XvMuse: FrequencyManager: Error getting bin for frequency", frequency)
            return 0
        }
        
    }
    
    //MARK: Relative valules
    public func getRelative(waveID:Int, spectrum:[Double]) -> Double {
        
        if (spectrum.count == 0) { return 0 }
        
        //get the incoming wave and power it up
        let incomingWave:Double = getWaveValue(waveID: waveID, spectrum: spectrum)
        
        //gather all the wave values
        var allWaves:[Double] = []
        for i in 0..<bins.count {
            allWaves.append(getWaveValue(waveID: i, spectrum: spectrum))
        }
        
        // make sure all values are above zero so all percentages are above zero
        allWaves = allWaves.map {
            if ($0 < 0) { return 0 }
            return $0
        }
        
        //sum the waves
        let allWavesSum:Double = allWaves.reduce(0, +)
        
        //return the incoming wave by the sum, and it returns a 0.0-1.0 percentage
        var average:Double = incomingWave / allWavesSum
        
        //error checking
        if (average.isNaN || average.isInfinite || average < 0) {
            average = 0
        }
        return average
    }
}
