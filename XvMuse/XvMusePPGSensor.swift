//
//  XvMusePPGSensor.swift
//  XvMuse
//
//  Created by Jason Snell on 7/25/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

/*
 
 sensor 0 - most sensitive
 sensor 1 - medium sensitive
 sensor 2 - least sensitve
 */

public class XvMusePPGSensor {
    
    fileprivate var id:Int
    init(id:Int) {
        self.id = id
        //_dct = DCT(bins: _maxCount)
        _ffTransformer = FFTransformer(bins: _maxCount)
    }

    //fileprivate let _dct:DCT
    
    
    //muse PPG is at 256 Hz
    //https://mind-monitor.com/forums/viewtopic.php?f=19&t=1379
    fileprivate var _maxCount:Int = 32
    fileprivate var _rawSamples:[Double] = []
    fileprivate var _frequencySpectrum:[Double] = []
    
    let _noiseFloorInc:Double = 5.0
    public func raiseNoiseFloor() -> Double {
        noiseFloor += _noiseFloorInc
        return noiseFloor
    }
    public func lowerNoiseFloor() -> Double {
        noiseFloor -= _noiseFloorInc
        return noiseFloor
    }
    fileprivate var noiseFloor:Double = 300
    
    
    internal func add(packet:XvMusePPGPacket) -> [Double]? {
        
        //add to the existing array
        _rawSamples += packet.samples
        
        //and remove oldest values that are beyond the buffer size
        if (_rawSamples.count > _maxCount) {
            _rawSamples.removeFirst(_rawSamples.count-_maxCount)
            
            //update frequency spectrum
            if let fs:[Double] = _getFrequencySpectrum(from: _rawSamples) {
                
                //store in var for external access
                _frequencySpectrum = fs
                
                //return to XvMusePPG for summing, creating heart and breath events
                return _frequencySpectrum
            }
        }
        
        return nil
    }
    
    //MARK: - TIME SAMPLES
    //access to the raw ppg samples for each sensor
    public var samples:[Double]? {
        
        get {
            
            if (_rawSamples.count < _maxCount) {
                
                print("PPG: Building buffer", _rawSamples.count, "/", _maxCount)
                return nil
            
            } else {
                
                return _rawSamples
            }
        }
    }
    
    //MARK: - FREQUENCY SPECTRUM
    //access to the frequency spectrum for each sensor
    public var frequencySpectrum:[Double]? {
        
        get {
            
            if (_rawSamples.count < _maxCount) {
                
                print("PPG: Building buffer", _rawSamples.count, "/", _maxCount)
                return nil
            
            } else {
                
                return _frequencySpectrum
            }
        }
    }
    
    fileprivate var _ffTransformer:FFTransformer
    fileprivate func _getFrequencySpectrum(from timeSamples:[Double]) -> [Double]? {
        
        
        if let fftResult:FFTResult = _ffTransformer.transform(
            samples: timeSamples,
            fromSensor: id,
            noiseFloor: noiseFloor
        ) {
            //return the result
            return fftResult.magnitudes
            //return fftResult.decibels
        
        } else {
            return nil
        }
        
        /*
        //convert to frequency and apply high pass filter to reduce noise
        let dctResult:[Double] = _dct.clean(
            signal: timeSamples,
            threshold: noiseFloor
        )
        
        return dctResult
        */
        
        /*
         //this code causes the values to go up and down every cycle, creating false movements in the output
         
        //once the buffer has been achieved
        if let min:Double = timeSamples.min(),
            let max:Double = timeSamples.max() {
            
            let range:Double = max-min
            
            //scale the samples down to a percentage for each sensor
            //creates consistency
            let scaledSamples:[Double] = _rawSamples.map { ($0-min) / range }
            
            //FFT
            /*if let fftResult:FFTResult = _ffTransformer.transform(
                samples: scaledSamples,
                fromSensor: id
            ) {
                //return the result
                //return fftResult.magnitudes
                return fftResult.decibels
            
            } else {
                return nil
            }*/
         
             let dctResult:[Double] = _dct.clean(
                 signal: scaledSamples,
                 threshold: noiseFloor
             )
         
            return dctResult
            
        } else {
            return nil
        }*/
    }
    
}
