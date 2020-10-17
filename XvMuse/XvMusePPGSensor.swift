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

struct PPGSignalPacket {
    internal var samples:[Double]
    internal var frequencySpectrum:[Double]
    
    init(samples:[Double], frequencySpectrum:[Double]) {
        self.samples = samples
        self.frequencySpectrum = frequencySpectrum
    }
}

public class XvMusePPGSensor {
    
    fileprivate var id:Int
    
    //data processors
    fileprivate var _ffTransformer:FFTransformer
    fileprivate var _dct:DCT
    
    init(id:Int) {
        
        self.id = id
        _dct = DCT(bins: _maxCount)
        _ffTransformer = FFTransformer(bins: _maxCount)
    }
    
    //MARK: - Incoming Data
    
    //this is where packets from the device, via bluetooth, come in for processing
    //these raw, time-based samples are what create the heartbeat pattern
    internal func add(packet:XvMusePPGPacket) -> PPGSignalPacket? {
        
        //add to the existing array
        _rawSamples += packet.samples
        
        //and remove oldest values that are beyond the buffer size
        if (_rawSamples.count > _maxCount) {
            _rawSamples.removeFirst(_rawSamples.count-_maxCount)
            
            //MARK: Scale time based samples
            //scale samples into percentage (0.0 - 1.0)
            
            if let min:Double = _rawSamples.min(),
               let max:Double = _rawSamples.max()
            {
                
                let range:Double = max - min
                
                
                //store in var for external access via ppg.sensors[0].samples
                _timeBasedSamples = _rawSamples.map { (($0-min)) / range }
                
                //MARK: update frequency spectrum
                if let fs:[Double] = _getFrequencySpectrum(from: _timeBasedSamples) {
                    
                    //store in var for external access via ppg.sensors[0].frequencySpectrum
                    _frequencySpectrum = fs
                    
                    //store both arrays into signal packet
                    //and return to parnt class for processing into heart events and bpm
                    return PPGSignalPacket(
                        samples: _timeBasedSamples,
                        frequencySpectrum: _frequencySpectrum
                    )
                }
            }
            
        } else {
            
            //only print the buffer build from one sensor
            if (id == 1) {
                print("PPG: Building buffer", _rawSamples.count, "/", _maxCount)
            }
        }
        
        return nil
    }
    
    
    
    //MARK: - Samples -
    //muse PPG is at 256 Hz
    //https://mind-monitor.com/forums/viewtopic.php?f=19&t=1379
    //muse lsl python script uses 64 samples
    //https://github.com/alexandrebarachant/muse-lsl/blob/0afbdaafeaa6592eba6d4ff7869572e5853110a1/muselsl/constants.py
    
    fileprivate var _maxCount:Int = 128
    fileprivate var _rawSamples:[Double] = []
    fileprivate var _timeBasedSamples:[Double] = []
    
    //access to the raw, time-based ppg samples for each sensor
    public var samples:[Double]? {
        
        get {
            if (_timeBasedSamples.count < _maxCount) {
                
                return nil

            } else {
                return _timeBasedSamples
            }
        }
    }
    
    
    //MARK: - FREQUENCY SPECTRUM
    //access to the frequency spectrum for each sensor
    fileprivate var _frequencySpectrum:[Double] = []
    public var frequencySpectrum:[Double]? {
        
        get {
            
            if (_timeBasedSamples.count < _maxCount) {
                
                //print("PPG: Building buffer", _timeBasedSamples.count, "/", _maxCount)
                return nil
            
            } else {
                
                return _frequencySpectrum
            }
        }
    }
    
    fileprivate func _getFrequencySpectrum(from timeSamples:[Double]) -> [Double]? {
        
        //convert to frequency and apply noise gate reduce noise
        let dctResult:[Double] = _dct.transform(
            signal: timeSamples,
            threshold: Float(noiseGate)
        )
        
        return dctResult
    }
    
    //MARK: - Noise Gate -
    
    public func increaseNoiseGate() -> Double {
        noiseGate += _noiseGateInc
        return noiseGate
    }
    public func decreaseNoiseGate() -> Double {
        noiseGate -= _noiseGateInc
        return noiseGate
    }
    fileprivate var noiseGate:Double = 540
    let _noiseGateInc:Double = 25
    
    

    
}
