//
//  XvMuseEEGHistory.swift
//  XvMuse
//
//  Created by Jason Snell on 7/11/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

public struct EEGValue {
    public var magnitude:Double = 0
    public var decibel:Double = 0
    
    init(magnitude:Double = 0, decibel:Double = 0) {
        self.magnitude = magnitude
        self.decibel = decibel
    }
}

//history buffer
//holds the recent values (up to buffer size)
//can provide info on the highest, lowest, and ranges of buffer values

public class XvMuseEEGHistory {
    
    //MARK: - INIT -
    init(){
        _magnitudes = [Double](repeating: 0.0, count: _maxCount)
        _decibels =   [Double](repeating: 0.0, count: _maxCount)
    }
    
    //MARK: - DATA UPDATES -
    fileprivate var source:XvMuseEEGValue?
    internal func update(with source:XvMuseEEGValue) {
        self.source = source
        newCache()
    }
    
    fileprivate var sources:[XvMuseEEGValue]?
    internal func update(with sources:[XvMuseEEGValue]) {
        self.sources = sources
        newCache()
    }
    
    fileprivate func newCache(){
        newSourceMagnitudes = true
        newSourcesMagnitudes = true
        newSourceDecibels = true
        newSourcesDecibels = true
        newHighest = true
        newLowest = true
        newRange = true
        newSum = true
        newAverage = true
        newPercent = true
    }
    
    
    //MARK: Magnitudes
    fileprivate var newSourceMagnitudes:Bool = true //single source
    fileprivate var newSourcesMagnitudes:Bool = true //multi source
    fileprivate var _magnitudes:[Double] = []
    public var magnitudes:[Double] {
        
        get {
            
            if (source != nil && newSourceMagnitudes) {
                //single source, add to array
                add(magnitude: source!.magnitude)
                newSourceMagnitudes = false
            
            } else if (sources != nil && newSourcesMagnitudes) {
                //if multiple sources, average the magnitudes from all sources, add to array
                add(magnitude: Number.getAverage(ofArray: sources!.map { $0.magnitude }))
                newSourcesMagnitudes = false
            }
            
            //return the array each time
            return _magnitudes
        }
    }
    
    fileprivate func add(magnitude:Double){
        //add to the buffer
        _magnitudes.append(magnitude)
        
        //and remove oldest values that are beyond the buffer size
        if (_magnitudes.count > _maxCount) {
            _magnitudes.removeFirst(_magnitudes.count-_maxCount)
        }
    }
    
    //MARK: Decibels
    fileprivate var newSourceDecibels:Bool = true //single source
    fileprivate var newSourcesDecibels:Bool = true //multi source
    fileprivate var _decibels:[Double] = []
    public var decibels:[Double] {
        
        get {
            if (source != nil && newSourceDecibels) {
                
                //single source, add to array
                add(decibel: source!.decibel)
                newSourceDecibels = false
            
            } else if (sources != nil && newSourcesDecibels) {
                
                //if multiple sources, average the magnitudes from all sources, add to array
                add(decibel: Number.getAverage(ofArray: sources!.map { $0.decibel }))
                newSourcesDecibels = false
            }
            
            //return the array each time
            return _decibels
        }
    }
    
    fileprivate func add(decibel:Double){
    
        //add to the buffer
        _decibels.append(decibel)
        
        //and remove oldest values that are beyond the buffer size
        if (_decibels.count > _maxCount) {
            _decibels.removeFirst(_decibels.count-_maxCount)
        }
    }
    
    
    //MARK: - Array attributes -
    fileprivate var newHighest:Bool = true
    fileprivate var _highest:EEGValue = EEGValue()
    public var highest:EEGValue {
        get {
            //if new data is avail
            if (newHighest) {
                
                //calc new var
                _highest = EEGValue(magnitude: _getHighest(in: magnitudes), decibel: _getHighest(in: decibels))
                
                //flag as no longer new data
                newHighest = false
            }
       
            //always return the curr var
            return _highest
        }
    }
    
    fileprivate var newLowest:Bool = true
    fileprivate var _lowest:EEGValue = EEGValue()
    public var lowest:EEGValue {
        get {
            if (newLowest) {
                
                _lowest = EEGValue(magnitude: _getLowest(in: magnitudes), decibel: _getLowest(in: decibels))
                newLowest = false
            }
          
            return _lowest
        }
    }
    
    fileprivate var newRange:Bool = true
    fileprivate var _range:EEGValue = EEGValue()
    public var range:EEGValue {
        get {
            if (newRange){
                _range = EEGValue(magnitude: _getRange(of: magnitudes), decibel: _getRange(of: decibels))
                newRange = false
            }
            return _range
        }
    }
    
    fileprivate var newSum:Bool = true
    fileprivate var _sum:EEGValue = EEGValue()
    public var sum:EEGValue {
        get {
            if (newSum){
                _sum = EEGValue(magnitude: _getSum(of: magnitudes), decibel: _getSum(of: decibels))
                newSum = false
            }
            return _sum
        }
    }
    
    fileprivate var newAverage:Bool = true
    fileprivate var _average:EEGValue = EEGValue()
    public var average:EEGValue {
        get {
            if (newAverage) {
                _average = EEGValue(magnitude: _getAverage(of: magnitudes), decibel: _getAverage(of: decibels))
                newAverage = false
            }
            return _average
        }
    }
    
    fileprivate var newPercent:Bool = true
    fileprivate var _percent:Double = 0
    public var percent:Double {
        get {
            if (newPercent) {
                if let curr:Double = decibels.last,
                    let highest:Double = decibels.max(){
                    _percent = curr / highest
                } else {
                    _percent = 0
                }
                newPercent = false
            }
            return _percent
        }
    }
    
    //MARK: attribute processing
    
    fileprivate func _getRange(of array:[Double]) -> Double {
        _getHighest(in: array) - _getLowest(in: array)
    }

    fileprivate func _getHighest(in array:[Double]) -> Double {
        if let max:Double = array.max() {
            return max
        } else {
            print("XvMuseEEG: Unable to calculate max value of array")
            return 0
        }
    }

    fileprivate func _getLowest(in array:[Double]) -> Double {
        if let min:Double = array.min() {
            return min
        } else {
            print("XvMuseEEG: Unable to calculate min value of array")
            return 0
        }
    }
    
    fileprivate func _getSum(of array:[Double]) -> Double {
        return array.reduce(0, +)
    }
    
    fileprivate func _getAverage(of array:[Double]) -> Double {
        if (array.count > 0) {
            return array.reduce(0, +) / Double(array.count)
        } else {
            return 0
        }
    }
    
 
    
    //MARK: - History Length -
    
    fileprivate var _maxCount:Int = 75
    public var historyLength:Int {
        get { return _maxCount }
        set {
            
            _maxCount = newValue
            
            //if magnitudes is less than max, fill with zeroes
            if (_magnitudes.count < _maxCount){
                
                let zeroes:[Double] = [Double](repeating: 0.0, count: _maxCount-_magnitudes.count)
                _magnitudes += zeroes
                
            } else if (_magnitudes.count > _maxCount) {
                
                //if more, then trim off oldest values
                _magnitudes.removeLast(_magnitudes.count-_maxCount)
            }
            
            //same with DBs
            if (_decibels.count < _maxCount){
                let zeroes:[Double] = [Double](repeating: 0.0, count: _maxCount-_decibels.count)
                _decibels += zeroes
            
            } else if (_decibels.count > _maxCount) {
                _decibels.removeLast(_decibels.count-_maxCount)
            }
        }
    }
}
