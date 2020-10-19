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
        _LFO1 = []
        _LFO2 = []
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
                    
                    //update the two LFO waves, using specific bins from the frequency spectrum
                    _update(lfo: 1, fs: _frequencySpectrum, binRange:[2, 2])
                    _update(lfo: 2, fs: _frequencySpectrum, binRange:[6, 7])
                    
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
    
    internal var sampleCount:Int {
        get { return _maxCount }
    }
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
            signal: timeSamples
        )
        
        return dctResult
    }

    
    //MARK: - LFO -
    fileprivate let _fm:FrequencyManager = FrequencyManager.sharedInstance
    fileprivate func _update(lfo:Int, fs:[Double], binRange:[Int]) {
        
        let binValues:[Double] = _fm.getSlice(bins: binRange, spectrum: fs)
        if (binValues.count > 0) {
            let binAverage:Double = binValues.reduce(0, +) / Double(binValues.count)
            
            if (lfo == 1) {
                _LFO1.append(binAverage)
                if (_LFO1.count > _maxCount) {
                    _LFO1.removeFirst(_LFO1.count - _maxCount)
                }
            } else {
                _LFO2.append(binAverage)
                if (_LFO2.count > _maxCount) {
                    _LFO2.removeFirst(_LFO2.count - _maxCount)
                }
            }
        }
    }
    
    fileprivate var _LFO1:[Double]
    public var LFO1:[Double] {
        get { return _LFO1 }
    }
    
    fileprivate var _LFO2:[Double]
    public var LFO2:[Double] {
        get { return _LFO2 }
    }
}

/*
 
 PPG NOTES
 Weds 10/14 9am
 ppgGraph!.set(psdCustomBinRange: [0, 3])
 ppgGraph!.set(amplifier: 0.035)
 sensor 1 goes from ~5000-32000 based on whether i'm leaning forward or not
 I think it's a sort of reading of blood pressure flowing towards the sensor
 
 10:30am
 DCT, bin 0 sees to be pure noise
 
 bin 1 may be breath. Perhaps sum all 3 sensors, bin 1
 
 DCT
 [5, 16] heart range
 
 10/15 7:30am
 //ussing fft, noise thread of about 240
 ppgGraph!.set(psdCustomBinRange:
 [6, 8]) - lub and dub range
 [5, 6]) - peak detection range
 ppgGraph!.set(amplifier: 0.1)
 
 Thurs 10/15
 ppgGraph!.initView()
 ppgGraph!.set(psdCustomBinRange:  [13, 16]) //113
 //ppgGraph!.set(amplifier: 3.0)//dct
 ppgGraph!.set(amplifier: 1.0)
 
 */
