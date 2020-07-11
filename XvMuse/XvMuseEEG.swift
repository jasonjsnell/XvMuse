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

 There are several ways to access data from this object
 
 OVERALL PSD VALUES
 eeg.magnitudes
 eeg.decibels
 
 BY SENSOR
 can use the location or sensor name, it access the same data
 eeg.TP9.magnitudes  OR  eeg.leftEar.magnitudes
 eeg.TP9.decibels    OR  eeg.leftEar.decibels
 
 also can access each wave value in each sensor
 eeg.TP9.delta.magnitude
 eeg.TP9.delta.decibel
 
 BY BRAINWAVE
 eeg.delta.magnitude <-- average delta across all 4 sensors
 eeg.delta.decibel
 eeg.TP9.delta.magnitude <-- delta magnitude for just this sensor
 eeg.TP9.delta.decibel
 
 
 
Each sensor contains all 5 bands, and the overall EEG data object has the averaged values of each band
                   HEAD
left-side < < < < <   > > > > > > right-side
 
       TP9     AF7     AF8     TP10  < XvMuseEEGSensor contains each wave, and array of full PSD magnitudes & decibels
                       ---      ---
delta   x       x     | x |    | x | < XvMuseEEGWaveValue contains averaged magnitude, decibel
theta   x       x     | x |     ---
alpha   x       x     | x |      x
beta    x       x     | x |      x
gamma   x       x     | x |      x
                       ___
 
        ^       ^       ^        ^
       side   front   front    side  < XvMuseEEGRegions
 
 
 --------------------------------------------------------------
 
        Delta   Theta   Alpha   Gamma   Beta  < XvMuseEEGWave: Mags and Bels are the average of all 4 sensors
                                 ---     ---
 TP9      x       x       x     | x |   | x | < XvMuseEEGSensorValue contains the value for each individual sensor
 AF7      x       x       x     | x |    ---
 AF8      x       x       x     | x |     x
 TP10     x       x       x     | x |     x
                                 ___
 
*/

//MARK: Basics
//basic build block objects for the EEG classes
// single value magnitude and decibel
public class EEGValuePair {
    var magnitude:Float = 0
    var decibel:Float = 0
    
    init(magnitude:Float = 0, decibel:Float = 0) {
        self.magnitude = magnitude
        self.decibel = decibel
    }
}

//array of magnitudes and decibles, like in a PSD or history arrays
public class EEGValueArrays {
    public var magnitudes:[Float] = []
    public var decibels:[Float] = []
}

//MARK: PSD
//all-band, full spectrum Power Spectral Densities from the FFT
public class XvMuseEEGPsd:EEGValueArrays {}

//MARK: Region
//regions combine the values from sensors, the regions are
//region 1) front region (2 forehead sensors)
//region 2) sides (left and right ear)
public class XvMuseEEGRegion:EEGValueArrays {}

//MARK: History
//history object, holds the recent values, and the highest, lowest, and range values can be accessed
public class XvMuseEEGValueHistory:EEGValueArrays {
    public var highest:EEGValuePair {
        get { return EEGValuePair(magnitude: _highest(in: magnitudes), decibel: _highest(in: decibels)) }
    }
    public var lowest:EEGValuePair {
        get { return EEGValuePair(magnitude: _lowest(in: magnitudes), decibel: _lowest(in: decibels)) }
    }
    public var range:EEGValuePair {
        get { return EEGValuePair(magnitude: _range(of: magnitudes), decibel: _range(of: decibels)) }
    }
    
    fileprivate func _range(of array:[Float]) -> Float {
        _highest(in: array) - _lowest(in: array)
    }

    fileprivate func _highest(in array:[Float]) -> Float {
        if let max:Float = array.max() {
            return max
        } else {
            print("XvMuseEEG: Unable to calculate max value of array")
            return 0
        }
    }

    fileprivate func _lowest(in array:[Float]) -> Float {
        if let min:Float = array.min() {
            return min
        } else {
            print("XvMuseEEG: Unable to calculate min value of array")
            return 0
        }
    }
    
}




public class XvMuseEEG {

    public var psd:XvMuseEEGPsd = XvMuseEEGPsd() //average of all PSDs across all sensors
    
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
    
    //Access the sensors by either their technical location (TP9) or head location (leftEar)
    // TP 9
    public var leftEar:XvMuseEEGSensor       { get { return _sensors[XvMuseConstants.EEG_SENSOR_EAR_L] } }
    public var TP9:XvMuseEEGSensor           { get { return _sensors[XvMuseConstants.EEG_SENSOR_EAR_L] } }
    
    // AF 7 / FP1
    public var leftForehead:XvMuseEEGSensor  { get { return _sensors[XvMuseConstants.EEG_SENSOR_FOREHEAD_L] } }
    public var FP1:XvMuseEEGSensor           { get { return _sensors[XvMuseConstants.EEG_SENSOR_FOREHEAD_L] } }
    
    // AF 8 / FP2
    public var rightForehead:XvMuseEEGSensor { get { return _sensors[XvMuseConstants.EEG_SENSOR_FOREHEAD_R] } }
    public var FP2:XvMuseEEGSensor           { get { return _sensors[XvMuseConstants.EEG_SENSOR_FOREHEAD_R] } }
    
    // TP 10
    public var rightEar:XvMuseEEGSensor      { get { return _sensors[XvMuseConstants.EEG_SENSOR_EAR_R] } }
    public var TP10:XvMuseEEGSensor          { get { return _sensors[XvMuseConstants.EEG_SENSOR_EAR_R] } }
    
    
    public var regions:[XvMuseEEGRegion] { get { return[ _regions[0], _regions[1]] } }
    public var front:XvMuseEEGRegion { get { return _regions[0] } }
    public var sides:XvMuseEEGRegion { get { return _regions[1] } }
    fileprivate var _regions:[XvMuseEEGRegion]
    
    
    //MARK: Brainwaves
    public var waves:[XvMuseEEGWave]
    
    public var delta:XvMuseEEGWave { get { return waves[0] } }
    public var theta:XvMuseEEGWave { get { return waves[1] } }
    public var alpha:XvMuseEEGWave { get { return waves[2] } }
    public var beta:XvMuseEEGWave  { get { return waves[3] } }
    public var gamma:XvMuseEEGWave { get { return waves[4] } }
    
    fileprivate let _fm:FrequencyManager = FrequencyManager()
    
    //MARK: - Init
    init() {
        
        //MARK: Access via Sensor
        //tp10 af8 tp9 af7
        //rightEar, rightForehead, leftForehead, leftEar
        //position the sensors in an array so they are accessible via a sensor ID number
        _sensors = [XvMuseEEGSensor(), XvMuseEEGSensor(), XvMuseEEGSensor(), XvMuseEEGSensor()]
        
        //loop through the sensors and initiaze to prep for faster data entry once the streaming data comes in
        for s in 0..<_sensors.count {
            
            _sensors[s].waves = [_sensors[s].delta, _sensors[s].theta, _sensors[s].alpha, _sensors[s].beta, _sensors[s].gamma]
        
        }
        
        //MARK: Access via Region
        _regions = [XvMuseEEGRegion(), XvMuseEEGRegion()]
        
        //MARK: Access via Wave
        waves = [XvMuseEEGWave(), XvMuseEEGWave(), XvMuseEEGWave(), XvMuseEEGWave(), XvMuseEEGWave()]
        
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
                _calcAverages()
            }
        }
    }
    
    fileprivate func updateSensor(with fftResult:FFTResult) {
        
        //grab the sensor ID from this particular FFT result
        let s:Int = fftResult.sensor

        //save the full-spectrum PSDs
        //meaning, not split into delta, alpha, etc... but all of them in the full PSD array of values
        //example: eeg.TP9.magnitudes
        //example: eeg.TP9.decibels
        _sensors[s].psd.magnitudes = fftResult.magnitudes
        _sensors[s].psd.decibels = fftResult.decibels
        
        // loop through each wave
        for w in 0..<_sensors[s].waves.count {
            
            //calculate the magnitude and decibel level for each wave of the incoming sensor
            let waveMagnitude:Float = _getWaveValue(spectrum: fftResult.magnitudes, bins: _fm.bins[w])
            let waveDecibel:Float   = _getWaveValue(spectrum: fftResult.decibels,   bins: _fm.bins[w])
            
            //update each wave value in this sensor
            //example: eeg.TP9.delta.decibel
            _sensors[s].waves[w].magnitude = waveMagnitude
            _sensors[s].waves[w].decibel   = waveDecibel
            
            //and inversely, update this sensor value (like TP9) in each wave object
            //example: eeg.delta.TP9.decibel
            //this allows uers to access the same value through either delta.TP9 or TP9.delta
            waves[w].sensors[s].magnitude = waveMagnitude
            waves[w].sensors[s].decibel = waveDecibel
        }
        
    }
    
    fileprivate func _getWaveValue(spectrum:[Float], bins:[Int]) -> Float{
        
        let slice:[Float] = Array(spectrum[bins[0]...bins[1]]) //get band slice from incoming array of values
        
        /*var hammingWindow = [Float](repeating: 0.0, count: slice.count)
        vDSP_hamm_windowD(&hammingWindow, UInt(slice.count), 0)
        
        // Apply the window to incoming samples
        vDSP_vmulD(slice, 1, hammingWindow, 1, &slice, 1, UInt(slice.count))*/
  
        return slice.reduce(0, +) / Float(slice.count) //return average
    }
    
    fileprivate func _calcAverages(){
        
        //MARK: Averaged value for each wave
        //example: delta.magnitude
        //example: delta.decibel
        //loop through each wave
        for w in 0..<waves.count {
            let waveValuesAcrossAllSensors:[XvMuseEEGWaveValue] = _sensors.map{ $0.waves[w] } //grab wave w from each sensor
            let waveMagnitudes:[Float] = waveValuesAcrossAllSensors.map {$0.magnitude} //calc the mags
            let waveDecibels:[Float] = waveValuesAcrossAllSensors.map {$0.magnitude} //and decibels
            waves[w].magnitude = waveMagnitudes.reduce(0, +) / Float(waveMagnitudes.count) //then assign the average to the global band var
            waves[w].decibel = waveDecibels.reduce(0, +) / Float(waveDecibels.count) //same with decibels
        }
        
        //MARK: Averaged values for all sensors
        //example: eeg.magnitudes
        let sensorMagnitudes:[[Float]] = _sensors.map { $0.psd.magnitudes } //grab magnitude arrays from each sensor
        
        //average each index value of each array, and output an array of averaged values for all the sensors combined
        if let sensorAveragedMagnitudes = averageByIndex(arrays: sensorMagnitudes) {
            self.psd.magnitudes = sensorAveragedMagnitudes
        }
        
        //same with dBs
        //example: eeg.decibels
        let sensorDecibels:[[Float]] = _sensors.map { $0.psd.decibels }
        if let sensorAveragedDecibels = averageByIndex(arrays: sensorDecibels) {
            self.psd.decibels = sensorAveragedDecibels
        }
        
        //MARK: Averaged values for regions (front & sides)
        
        //grab forehead values
        //example: eeg.front.magnitudes
        let frontMagnitudes:[[Float]] = [
            sensorMagnitudes[XvMuseConstants.EEG_SENSOR_FOREHEAD_L],
            sensorMagnitudes[XvMuseConstants.EEG_SENSOR_FOREHEAD_R]
        ]
        if let frontAveragedMagnitudes = averageByIndex(arrays: frontMagnitudes) {
            _regions[0].magnitudes = frontAveragedMagnitudes
        }
        
        //example: eeg.front.decibels
        let frontDecibels:[[Float]] = [
            sensorDecibels[XvMuseConstants.EEG_SENSOR_FOREHEAD_L],
            sensorDecibels[XvMuseConstants.EEG_SENSOR_FOREHEAD_R]
        ]
        if let frontAveragedDecibels = averageByIndex(arrays: frontDecibels) {
            _regions[0].decibels = frontAveragedDecibels
        }
       
        //grab side values
        //example: eeg.side.magnitudes
        let sideMagnitudes:[[Float]] = [
            sensorMagnitudes[XvMuseConstants.EEG_SENSOR_EAR_L],
            sensorMagnitudes[XvMuseConstants.EEG_SENSOR_EAR_R]
        ]
        if let sideAveragedMagnitudes = averageByIndex(arrays: sideMagnitudes) {
            _regions[1].magnitudes = sideAveragedMagnitudes
        }
        
        //example: eeg.side.decibels
        let sideDecibels:[[Float]] = [
            sensorDecibels[XvMuseConstants.EEG_SENSOR_EAR_L],
            sensorDecibels[XvMuseConstants.EEG_SENSOR_EAR_R]
        ]
        if let sideAveragedDecibels = averageByIndex(arrays: sideDecibels) {
            _regions[1].decibels = sideAveragedDecibels
        }
        
    }
    
    //takes an array of arrays
    //and provides an average value for each position in the array
    //(each array must be the same length)
    //it returns an array with the averaged values
    
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
