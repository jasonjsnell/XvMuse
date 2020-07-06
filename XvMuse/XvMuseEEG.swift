//
//  XvMuseEEG.swift
//  XvMuse
//
//  Created by Jason Snell on 7/4/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

/*
 
 Each time the Muse headband fires off an EEG sensor update (order is: tp10 af8 tp9 af7),
 the XvMuse class puts that data into XvMuseEEGPackets
 and sends it here to create a streaming buffer, slice out epoch windows, and return Fast Fourier Transformed array of frequency data
        
        ch1     ch2     ch3     ch4  < EEG sensors tp10 af8 tp9 af7
                        ---     ---
 0:00    p       p     | p |   | p | < XvMuseEEGPacket is one packet of a 12 sample EEG reading, index, timestamp, channel ID
 0:01    p       p     | p |    ---
 0:02    p       p     | p |     p
 0:03    p       p     | p |     p
 0:04    p       p     | p |     p
 0:05    p       p     | p |     p
                        ___
 
                         ^ DataBuffer of streaming samples. Each channel has it's own buffer
 */

public struct XvMuseEEGPacket {
    
    public var sensor:Int = 0 // 0 to 4: tp10 af8 tp9 af7 aux
    public var timestamp:Double = 0 // milliseconds since packet creation
    public var samples:[Float] = [] // 12 samples of EEG sensor data
    
    public init(sensor:Int, timestamp:Double, samples:[Float]){
        self.sensor = sensor
        self.timestamp = timestamp
        self.samples = samples
    }
}

/*

Each sensor contains all 5 bands, and the overall EEG data object has the averaged values of each band
                   HEAD
left-side < < < < <   > > > > > > right-side
 
       TP9     AF7     AF8     TP10
                       ---      ---
delta   x       x     | x |    | x | < XvMuseEEGBand contains averaged magnitude, decibel
theta   x       x     | x |     ---
alpha   x       x     | x |      x
beta    x       x     | x |      x
gamma   x       x     | x |      x
                       ___

                        ^ XvMuseEEGSensor contains each band, and array of unfiltered magnitudes, decibels
*/

public struct XvMuseEEGBand {
    
    public var magnitude:Float = 0 // fft absolute magnitudes
    public var decibel:Float = 0 // magnitudes processed into decibels
    
}

//regions combine the values from sensors, so sides and front
public struct XvMuseEEGRegion {
    
    public var magnitudes:[Float] = []
    public var decibels:[Float] = []
}

public class XvMuseEEG {

    public var magnitudes:[Float] = [] //averaged absolute magnitudes across all sensors
    public var decibels:[Float] = [] //averaged decibels across all sensors

    //MARK: Sensors
    //for the public accessor, return in the order of left ear, left forehead, right forehead, right ear
    public var sensors:[XvMuseEEGSensor] { get { return[
        _sensors[XvMuseConstants.EEG_SENSOR_EAR_L],
        _sensors[XvMuseConstants.EEG_SENSOR_FOREHEAD_L],
        _sensors[XvMuseConstants.EEG_SENSOR_FOREHEAD_R],
        _sensors[XvMuseConstants.EEG_SENSOR_EAR_R]
        ] }
    }
    fileprivate var _sensors:[XvMuseEEGSensor]
    
    public var leftEar:XvMuseEEGSensor       { get { return _sensors[XvMuseConstants.EEG_SENSOR_EAR_L] } }      // TP 9
    public var leftForehead:XvMuseEEGSensor  { get { return _sensors[XvMuseConstants.EEG_SENSOR_FOREHEAD_L] } } // AF 7
    public var rightForehead:XvMuseEEGSensor { get { return _sensors[XvMuseConstants.EEG_SENSOR_FOREHEAD_R] } } // AF 8
    public var rightEar:XvMuseEEGSensor      { get { return _sensors[XvMuseConstants.EEG_SENSOR_EAR_R] } }      // TP 10
    
    
    public var regions:[XvMuseEEGRegion] { get { return[ _regions[0], _regions[1]] } }
    public var front:XvMuseEEGRegion { get { return _regions[0] } }
    public var sides:XvMuseEEGRegion { get { return _regions[1] } }
    fileprivate var _regions:[XvMuseEEGRegion]
    
    //MARK: Brainwave bands
    fileprivate var _bands:[XvMuseEEGBand]
    public var delta:XvMuseEEGBand { get { return _bands[0] } }
    public var theta:XvMuseEEGBand { get { return _bands[1] } }
    public var alpha:XvMuseEEGBand { get { return _bands[2] } }
    public var beta:XvMuseEEGBand  { get { return _bands[3] } }
    public var gamma:XvMuseEEGBand { get { return _bands[4] } }
    
    
    fileprivate let _fm:FrequencyManager = FrequencyManager()
    
    init() {
        
        //tp10 af8 tp9 af7
        //rightEar, rightForehead, leftForehead, leftEar
        //position the sensors in an array so they are accessible via a sensor ID number
        _sensors = [XvMuseEEGSensor(), XvMuseEEGSensor(), XvMuseEEGSensor(), XvMuseEEGSensor()]
        
        //loop through the sensors and initiaze to prep for faster data entry once the streaming data comes in
        for s in 0..<_sensors.count {
            
            _sensors[s]._bands = [_sensors[s].delta, _sensors[s].theta, _sensors[s].alpha, _sensors[s].beta, _sensors[s].gamma]
        
        }
        _bands = [XvMuseEEGBand(), XvMuseEEGBand(), XvMuseEEGBand(), XvMuseEEGBand(), XvMuseEEGBand()]
        
        _regions = [XvMuseEEGRegion(), XvMuseEEGRegion()]
    }
    
    public func update(with fftResult:FFTResult?) {
        
        //fftResult is nil when the buffers are loading in the beginng and inbetween Epoch window firings
        if (fftResult != nil) {
            
            //when the fft result is valid,
            //update the sensor object with the FFT result arrays
            updateSensor(with: fftResult!)
            
            //if this is the last sensor in the updating sequencing
            if (fftResult!.sensor == _sensors.count-1) {
                
                //calculate averages across all the sensors
                calcAverages()
            }
        }
    }
    
    fileprivate func updateSensor(with fftResult:FFTResult) {
        
        let s:Int = fftResult.sensor

        _sensors[s].magnitudes = fftResult.magnitudes
        _sensors[s].decibels = fftResult.decibels
        
        //loop through each band in this sensor and calc the new values
        for b in 0..<_sensors[s]._bands.count {
            _sensors[s]._bands[b].decibel = getBandValue(spectrum: _sensors[s].decibels, bins: _fm.bins[b])
            _sensors[s]._bands[b].magnitude = getBandValue(spectrum: _sensors[s].magnitudes, bins: _fm.bins[b])
        }
    }
    
    fileprivate func getBandValue(spectrum:[Float], bins:[Int]) -> Float{
        
        let slice:[Float] = Array(spectrum[bins[0]...bins[1]]) //get band slice from incoming array of values
        
        /*var hammingWindow = [Float](repeating: 0.0, count: slice.count)
        vDSP_hamm_windowD(&hammingWindow, UInt(slice.count), 0)
        
        // Apply the window to incoming samples
        vDSP_vmulD(slice, 1, hammingWindow, 1, &slice, 1, UInt(slice.count))*/
  
        return slice.reduce(0, +) / Float(slice.count) //return average
    }
    
    fileprivate func calcAverages(){
        
        //MARK: Averaged values for each band
        //loop through the bands
        for b in 0..<_bands.count {
            let bandAcrossAllSensors:[XvMuseEEGBand] = _sensors.map{ $0._bands[b] } //grab band b from each sensor
            let bandMagnitudes:[Float] = bandAcrossAllSensors.map {$0.magnitude} //calc the mags
            let bandDecibels:[Float] = bandAcrossAllSensors.map {$0.magnitude} //and decibels
            _bands[b].magnitude = bandMagnitudes.reduce(0, +) / Float(bandMagnitudes.count) //then assign the average to the global band var
            _bands[b].decibel = bandDecibels.reduce(0, +) / Float(bandDecibels.count) //same with decibels
        }
        
        //MARK: Averaged values for all sensors
        let sensorMagnitudes:[[Float]] = _sensors.map { $0.magnitudes } //grab magnitude arrays from each sensor
        
        //average each index value of each array, and output an array of averaged values for all the sensors combined
        if let sensorAveragedMagnitudes = averageByIndex(arrays: sensorMagnitudes) {
            self.magnitudes = sensorAveragedMagnitudes
        }
        
        //same with dBs
        let sensorDecibels:[[Float]] = _sensors.map { $0.decibels }
        if let sensorAveragedDecibels = averageByIndex(arrays: sensorDecibels) {
            self.decibels = sensorAveragedDecibels
        }
        
        //MARK: Averaged values for regions (front & sides)
        
        //grab forehead values
        let frontMagnitudes:[[Float]] = [
            sensorMagnitudes[XvMuseConstants.EEG_SENSOR_FOREHEAD_L],
            sensorMagnitudes[XvMuseConstants.EEG_SENSOR_FOREHEAD_R]
        ]
        if let frontAveragedMagnitudes = averageByIndex(arrays: frontMagnitudes) {
            _regions[0].magnitudes = frontAveragedMagnitudes
        }
        let frontDecibels:[[Float]] = [
            sensorDecibels[XvMuseConstants.EEG_SENSOR_FOREHEAD_L],
            sensorDecibels[XvMuseConstants.EEG_SENSOR_FOREHEAD_R]
        ]
        if let frontAveragedDecibels = averageByIndex(arrays: frontDecibels) {
            _regions[0].decibels = frontAveragedDecibels
        }
       
        //grab side values
        let sideMagnitudes:[[Float]] = [
            sensorMagnitudes[XvMuseConstants.EEG_SENSOR_EAR_L],
            sensorMagnitudes[XvMuseConstants.EEG_SENSOR_EAR_R]
        ]
        if let sideAveragedMagnitudes = averageByIndex(arrays: sideMagnitudes) {
            _regions[1].magnitudes = sideAveragedMagnitudes
        }
        let sideDecibels:[[Float]] = [
            sensorDecibels[XvMuseConstants.EEG_SENSOR_EAR_L],
            sensorDecibels[XvMuseConstants.EEG_SENSOR_EAR_R]
        ]
        if let sideAveragedDecibels = averageByIndex(arrays: sideDecibels) {
            _regions[1].decibels = sideAveragedDecibels
        }
        
    }
    
    func averageByIndex(arrays:[[Float]]) -> [Float]? {
        guard let length = arrays.first?.count else { return []}

        // check all the elements have the same length, otherwise returns nil
        guard !arrays.contains(where:{ $0.count != length }) else { return nil }

        return (0..<length).map { index in
            let sum = arrays.map { $0[index] }.reduce(0, +)
            return sum / Float(arrays.count)
        }
    }

    
}
