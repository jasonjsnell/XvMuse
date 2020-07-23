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
    
    init(){
        _magnitudes = [Double](repeating: 0.0, count: _maxCount)
        _decibels = [Double](repeating: 0.0, count: _maxCount)
    }
    
    fileprivate var source:XvMuseEEGValue?
    fileprivate var sources:[XvMuseEEGValue]?
  
    internal func assign(source:XvMuseEEGValue?){
        if (sources == nil) {
            self.source = source
        } else {
            print("XvMuseEEGHistory: Error: Object has already been assigned to a set of sources.")
        }
    }
    
    internal func assign(sources:[XvMuseEEGValue]?){
        if (source == nil) {
            self.sources = sources
        } else {
            print("XvMuseEEGHistory: Error: Object has already been assigned to a single source.")
        }
    }
    
    //MARK: Accessors
    
    fileprivate var _magnitudes:[Double] = []
    public var magnitudes:[Double] {
        
        get {
            
            if (source != nil) {
                
                //single source
                add(magnitude: source!.magnitude)
                
            } else if (sources != nil) {
                
                //if multiple sources, average the magnitudes from all sources
                let averageMagnitude:Double = Number.getAverage(ofArray: sources!.map { $0.magnitude })
                add(magnitude: averageMagnitude)
                
            } else {
                print("XvMuseEEGHistory: Error: No source(s) assigned when accessing magnitudes")
            }
            
            return _magnitudes
        }
    }
    
    fileprivate var _decibels:[Double] = []
    public var decibels:[Double] {
        
        get {
            
            if (source != nil) {
                
                add(decibel: source!.decibel)
                
            } else if (sources != nil) {
                
                //if multiple sources, average the magnitudes from all sources
                let averageDecibel:Double = Number.getAverage(ofArray: sources!.map { $0.decibel })
                add(decibel: averageDecibel)
                
            } else {
                print("XvMuseEEGHistory: Error: No source(s) assigned when accessing decibels")
            }
            
            return _decibels
        }
    }
    
    
    //MARK: - Changing the data
    let magnitudeHistoryQueue:DispatchQueue = DispatchQueue(label: "magnitudeHistoryQueue")
    fileprivate func add(magnitude:Double){
        
        //run inside of queue to avoid fatal errors from multiple sources calling this simultaneously
        magnitudeHistoryQueue.sync {
            
            //only add to array if value is new
            //this prevents duplicate entries from the history being called repeatedly in one render loop
            if let last:Double = _magnitudes.last {
                if (magnitude == last) { return }
            }
            
            //add to the buffer
            _magnitudes.append(magnitude)
            
            //and remove oldest values that are beyond the buffer size
            if (_magnitudes.count > _maxCount) {
                let _:Double? = _magnitudes.removeFirst()
            }
            
        }
        
        
    }
    
    let decibelHistoryQueue:DispatchQueue = DispatchQueue(label: "decibelHistoryQueue")
    fileprivate func add(decibel:Double){
        
        // run in a queue to avoid fatal errors like
        // fatal error: UnsafeMutablePointer.deinitialize with negative count
        // this error can happen if this func is being called from multiple places at the same time
        decibelHistoryQueue.sync {
            
            //only add to array if value is new
            //this prevents duplicate entries from the history being called repeatedly in one render loop
            
            if let last:Double = _decibels.last {
                if (decibel == last) { return }
            }
            
            //add to the buffer
            _decibels.append(decibel)
            
            //and remove oldest values that are beyond the buffer size
            if (_decibels.count > _maxCount) {
                let _:Double? = _decibels.removeFirst()
            }
        }
    }
    
    
    //MARK: - Buffer
    
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
    
    
    //MARK: Information requests
    
    public var highest:EEGValue {
        get { return EEGValue(magnitude: _highest(in: magnitudes), decibel: _highest(in: decibels)) }
    }
    public var lowest:EEGValue {
        get { return EEGValue(magnitude: _lowest(in: magnitudes), decibel: _lowest(in: decibels)) }
    }
    public var range:EEGValue {
        get { return EEGValue(magnitude: _range(of: magnitudes), decibel: _range(of: decibels)) }
    }
    public var sum:EEGValue {
        get { return EEGValue(magnitude: _sum(of: magnitudes), decibel: _sum(of: decibels)) }
    }
    public var average:EEGValue {
        get { return EEGValue(magnitude: _average(of: magnitudes), decibel: _average(of: decibels)) }
    }
    public var percent:Double {
        get {
            if let first:Double = decibels.first,
                let highest:Double = decibels.max(){
                return first / highest
            } else {
                return 0
            }
        }
    }
    
    
    //MARK: Helpers
    
    fileprivate func _range(of array:[Double]) -> Double {
        _highest(in: array) - _lowest(in: array)
    }

    fileprivate func _highest(in array:[Double]) -> Double {
        if let max:Double = array.max() {
            return max
        } else {
            print("XvMuseEEG: Unable to calculate max value of array")
            return 0
        }
    }

    fileprivate func _lowest(in array:[Double]) -> Double {
        if let min:Double = array.min() {
            return min
        } else {
            print("XvMuseEEG: Unable to calculate min value of array")
            return 0
        }
    }
    
    fileprivate func _sum(of array:[Double]) -> Double {
        return array.reduce(0, +)
    }
    
    fileprivate func _average(of array:[Double]) -> Double {
        if (array.count > 0) {
            return array.reduce(0, +) / Double(array.count)
        } else {
            return 0
        }
    }
    
    
}
