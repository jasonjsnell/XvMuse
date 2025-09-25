//
//  XvMuseEEG.swift
//  XvMuse
//
//  Created by Jason Snell on 7/4/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

internal class MuseEEG {

    //MARK: - SENSORS -
    
    //return in the order of left ear, left forehead, right forehead, right ear
    public var sensors:[MuseEEGSensor]
    
    //Access the sensors by either their technical location (TP9)
    public var TP9:MuseEEGSensor           { get { return sensors[0] } } //leftEar
    public var AF7:MuseEEGSensor           { get { return sensors[1] } } //leftForehead
    public var AF8:MuseEEGSensor           { get { return sensors[2] } } //rightForehead
    public var TP10:MuseEEGSensor          { get { return sensors[3] } } //rightEar:MuseEEGSensor
    
    // the muse fires in the sequences of:
    //0 TP10: right ear
    //1 AF08: right forehead
    //2 TP09: left ear
    //3 AF07: left forehead
    
    // the func allows the public array to be left to right:
    // left ear (2), left forehead (3), right forehead (1), right ear (0)
    // 0 -> position 2
    // 1 -> position 3
    // 2 -> position 1
    // 3 -> position 0
    
    //order logic
    // So for each incoming ID:
    // ID 0 (R ear) → seat 3
    // ID 1 (R forehead) → seat 2
    // ID 2 (L ear) → seat 0
    // ID 3 (L forehead) → seat 1
    
    private let museSensorFireSequence:[Int] = [3, 2, 0, 1]
    private func getSensorPosition(from id:Int) -> Int { return museSensorFireSequence[id] }
    
    //MARK: - INIT -
    
    public init() {
        
        sensors = [
            MuseEEGSensor(), // TP9  left ear (id 2)
            MuseEEGSensor(), // AF7  left forehead (id 3)
            MuseEEGSensor(), // AF8  right forehead (id 1)
            MuseEEGSensor()  // TP10 right ear (id 0)
        ]
    }
    
    //MARK: - DATA UPDATES -
    //Incoming data from device -> FFT
    //this is the entry point from the FFT process to where the data gets mapped out into different sensors, regions, waves, histories, etc...

    public func update(withFFTResult: FFTResult?) {
        
        //fftResult is nil when the buffers are loading in the beginning and inbetween Epoch window firings
        print("in eeg object", withFFTResult?.sensor, withFFTResult?.power.count, withFFTResult?.power[8])
        guard let _fftResult = withFFTResult else { return }
        //so when the fft result is valid...
        
        //MARK: Convert FFT result into Hz bin spectrum
        let _powerSpectrum = _fftResult.power
        
        //MARK: Save spectrum into the correct sensor
        //what sensor is this?
        let sensorIndex = getSensorPosition(from: _fftResult.sensor)
        if sensorIndex >= 0 && sensorIndex < sensors.count {
            sensors[sensorIndex].update(withFftPowerSpectrum: _powerSpectrum)
        } else {
            print("MuseEEG: Warning: sensor index out of range for id", _fftResult.sensor)
        }
        
        //and then the parent, XvMuse, then pulls data from the sensors in this class via eeg.TP9, eeg.FP1, (etc)
        //to make packets with the 4 sensor update and send up to the parent app
    
    }
}
