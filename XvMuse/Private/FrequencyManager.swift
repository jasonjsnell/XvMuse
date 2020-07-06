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
    
    fileprivate var frequencies:[Float]
    
    init(){
        
        let freqInc:Float = XvMuseConstants.SAMPLING_RATE / Float(XvMuseConstants.FFT_BINS)
        let freqRange:Array<Int> = Array(0...XvMuseConstants.FFT_BINS/2)
        
        frequencies = freqRange.map { Float($0) * freqInc }
        
        //put calculated bins into a public array
        bins = [
            getIndexesFor(frequencyRange: XvMuseConstants.FREQUENCY_BAND_DELTA),
            getIndexesFor(frequencyRange: XvMuseConstants.FREQUENCY_BAND_THETA),
            getIndexesFor(frequencyRange: XvMuseConstants.FREQUENCY_BAND_ALPHA),
            getIndexesFor(frequencyRange: XvMuseConstants.FREQUENCY_BAND_BETA),
            getIndexesFor(frequencyRange: XvMuseConstants.FREQUENCY_BAND_GAMMA)
        ]
        
        
        
    }
    
    //get indexes for an incoming frequency range
    public func getIndexesFor(frequencyRange:[Float]) -> [Int] {
        
        var indexes:[Int] = []
        
        for f in frequencyRange {
            indexes.append(getIndexFor(frequency: f))
        }
        
        return indexes
    }
    
    
    //get an index of a frequency
    fileprivate func getIndexFor(frequency:Float) -> Int {
        
        let closest:EnumeratedSequence<[Float]>.Element = frequencies.enumerated().min( by: { abs($0.1 - frequency) < abs($1.1 - frequency) } )!
        return closest.offset
    }
}
