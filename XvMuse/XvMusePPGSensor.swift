//
//  XvMusePPGSensor.swift
//  XvMuse
//
//  Created by Jason Snell on 7/25/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

public class XvMusePPGSensor {
    
    fileprivate var id:Int
    init(id:Int) {
        self.id = id
    }

    fileprivate let _dct:DCT = DCT(bins: 256)
    fileprivate let _hba:HeartbeatAnalyzer = HeartbeatAnalyzer()
    fileprivate let _bpm:BeatsPerMinute = BeatsPerMinute()
    
    fileprivate var _maxCount:Int = 256
    fileprivate var _rawSamples:[Double] = []
    fileprivate var _frequencySpectrum:[Double] = []
    
    public func add() -> Float {
        HIGH_PASS_FILTER_FREQ += 0.1
        return HIGH_PASS_FILTER_FREQ
    }
    public func reduce() -> Float {
        HIGH_PASS_FILTER_FREQ -= 0.1
        return HIGH_PASS_FILTER_FREQ
    }
    fileprivate var HIGH_PASS_FILTER_FREQ:Float = 1.6
    
    
    internal func add(packet:XvMusePPGPacket) -> PPGResult? {
        
        //add to the existing array
        _rawSamples += packet.samples
        
        //and remove oldest values that are beyond the buffer size
        if (_rawSamples.count > _maxCount) {
            _rawSamples.removeFirst(_rawSamples.count-_maxCount)
            
            //update frequency spectrum
            if let fs:[Double] = _getFrequencySpectrum(from: _rawSamples) {
                _frequencySpectrum = fs
                
                //only get heart events from sensor 1
                if (id == 1) {
                    
                    //if data is full
                    if (_frequencySpectrum.count == _maxCount) {
                        
                        //grab the heartbeat slice from spectrum
                        let slice:[Double] = Array(_frequencySpectrum[11...12])
                        
                        if let heartEvent:XvMusePPGHeartEvent = _hba.getHeartEvent(from: slice) {
                            
                            if heartEvent.type == XvMuseConstants.PPG_S2_EVENT {
                                
                                
                                let bpmPacket:XvMusePPGBpmPacket = _bpm.update(with: packet.timestamp)
                                return PPGResult(heartEvent: heartEvent, bpmPacket: bpmPacket)
                            }
                            
                            //non AV events don't have a bpm update
                            return PPGResult(heartEvent: heartEvent, bpmPacket: nil)
                        }
                    }
                }
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
    
    
    fileprivate func _getFrequencySpectrum(from timeSamples:[Double]) -> [Double]? {
        
        //once the buffer has been achieved
        if let min:Double = timeSamples.min(),
            let max:Double = timeSamples.max() {
            
            let range:Double = max-min
            
            //scale the samples down to a percentage for each sensor
            //creates consistency
            let scaledSamples:[Double] = _rawSamples.map { ($0-min) / range }
            
            //convert to frequency and apply high pass filter to reduce noise
            let cleanedSamples:[Double] = _dct.clean(signal: scaledSamples, threshold: HIGH_PASS_FILTER_FREQ)
            
            return cleanedSamples.map { $0 * 10 } //scale up
            
        } else {
            return nil
        }
    }
    
}
