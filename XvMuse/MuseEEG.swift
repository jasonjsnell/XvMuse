//
//  XvMuseEEG.swift
//  XvMuse
//
//  Created by Jason Snell on 7/4/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

//MARK: - Classes -

/*
 There are several ways to access data from this object

 AVERAGED PSD VALUES
 eeg.decibels
 
 SENSOR PSD VALUES
 can use the location or sensor name
 eeg.TP9.decibels
 eeg.leftEar.decibels
 
 */

internal class MuseEEG {

    //MARK: - SENSORS -
    
    //return in the order of left ear, left forehead, right forehead, right ear
    public var sensors:[MuseEEGSensor]
    
    //Access the sensors by either their technical location (TP9) or head location (leftEar)
    public var leftEar:MuseEEGSensor       { get { return sensors[0] } }
    public var TP9:MuseEEGSensor           { get { return sensors[0] } }
    
    public var leftForehead:MuseEEGSensor  { get { return sensors[1] } }
    public var FP1:MuseEEGSensor           { get { return sensors[1] } }
    
    public var rightForehead:MuseEEGSensor { get { return sensors[2] } }
    public var FP2:MuseEEGSensor           { get { return sensors[2] } }
    
    public var rightEar:MuseEEGSensor      { get { return sensors[3] } }
    public var TP10:MuseEEGSensor          { get { return sensors[3] } }
    
    // the muse fires in the sequences of:
    //0 TP10: right ear
    //1 AF08: right forehead
    //2 TP09: left ear
    //3 AF07: left forehead
    
    // the func allows the public array to be left to right:
    // left ear (2), left forehead (3), right forehead (1), right ear (0)
    // 0 -> position 3
    // 1 -> position 2
    // 2 -> position 0
    // 3 -> position 1
    fileprivate let museSensorFireSequence:[Int] = [2, 3, 1, 0]
    fileprivate func getSensorPosition(from id:Int) -> Int { return museSensorFireSequence[id] }
    
    //MARK: - INIT -
    fileprivate var _binLocs:[Int] = []
    
    public init(frequencyRange:[Int]) {
        
        //init the sensors
        //they are the entry point into this system from the Muse hardware
        //example: for sensor in eeg.sensors { }
        
        sensors = [MuseEEGSensor(), MuseEEGSensor(), MuseEEGSensor(), MuseEEGSensor()]
        
        //make sure frequency range is an array of two values
        if (frequencyRange.count == 2) {
            
            //loop through each hz in the frequency range
            for hz in frequencyRange[0]..<frequencyRange[1] {
                _binLocs.append(_fm.getBinFor(frequency: Double(hz)))
            }
            
        } else {
            print("XvMuseEEG: Init: Fatal error: frequencyRange needs to be 2 values. Currently", frequencyRange)
            fatalError()
        }
    }
    
    
    //MARK: - DATA UPDATES -
    //Incoming data from device -> FFT
    //this is the entry point from the FFT process to where the data gets mapped out into different sensors, regions, waves, histories, etc...

    public func update(with fftResult:FFTResult?) {
        
        //fftResult is nil when the buffers are loading in the beginning and inbetween Epoch window firings
        
        //so when the fft result is valid...
        if (fftResult != nil) {
            
            //MARK: Convert FFT result into Hz bin spectrum
            //temp, local array
            var _spectrum:[Double] = []
            
            //loop through each hz bin (ex: 0, 1, 3, 4, 6, 7, 9)
            for i in 0..<_binLocs.count {
                
                //grab the db values from the specific bin locations (ex: 0, 1, 3, 4, 6, 7, 9)
                //save the db from each of those hz bin locations into a spectrum array
                _spectrum.append(fftResult!.decibels[_binLocs[i]])
            }
            
            
            //MARK: Save spectrum into the correct sensor
            //what sensor is this?
            let sensorPosition:Int = getSensorPosition(from: fftResult!.sensor)
    
            //save spectrum into the sensor
            sensors[sensorPosition].update(spectrum: _spectrum)
            
            
            //MARK: Create device's average spectrum
            //for device averaged spectrum
            _spectrums.append(_spectrum)
            
            //once the 4 sensors populate the _spectrums array...
            if (_spectrums.count >= sensors.count){
                
                //calculate the average spectrum from the spectrums from the 4 sensors
                if let avg:[Double] = getAverageByIndex(arrays: _spectrums) {
                    
                    //save into the public var
                    spectrum = avg
                    
                    //reset the spectrums array so it can be populated again
                    _spectrums = []
                }
            }
        }
    }
    
    //MARK: - AVERAGED VALUES -
    
    public var spectrum:[Double] = []
    fileprivate var _spectrums:[[Double]] = []
    
    fileprivate func getAverageByIndex(arrays:[[Double]]) -> [Double]? {
        
        guard let length = arrays.first?.count else { return [] }

        // check all the elements have the same length, otherwise returns nil
        guard !arrays.contains(where:{ $0.count != length }) else { return nil }

        return (0..<length).map { index in
            let sum = arrays.map { $0[index] }.reduce(0, +)
            return sum / Double(arrays.count)
        }
    }
    
    //fileprivate var _cache:SensorCache = SensorCache()
    
    //MARK: - Decibels
    //example: eeg.decibels
//    public var decibels:[Double] {
//        get { return _cache.getDecibels() }
//    }
    
    //MARK: - Noise
//    public var noise:Int {
//        get { return _cache.getNoise() }
//    }
    
    //MARK: - SETTERS -
    
    //MARK: History Lengths
    //the length of the sensor or wave value history can be changed by the user
//    public var historyLength:Int {
//        
//        get {
//            waves[0].history.historyLength
//        }
//        
//        set {
//            
//            //each wave in each sensor
//            for sensor in sensors {
//               
//                for wave in sensor.waves {
//                    wave.history.historyLength = newValue
//                }
//            }
//            
//            for wave in waves {
//                
//                //each wave
//                wave.history.historyLength = newValue
//                
//                //each sensor in each wave
//                for sensorValue in wave.sensorValues {
//                    sensorValue.history.historyLength = newValue
//                }
//                
//                for region in wave.regions {
//                    region.history.historyLength = newValue
//                }
//            }
//            
//            for region in regions {
//                
//                for wave in region.waves {
//                    wave.history.historyLength = newValue
//                }
//            }
//        }
//    }
    
    //MARK: - GETTERS -
    
    //MARK: Accessing custom frequency ranges
    fileprivate let _fm:FrequencyManager = FrequencyManager.sharedInstance
    
    
    //MARK: Get bins
//    public func getBins(fromFrequencyRange:[Double]) -> [Int] {
//
//        return _fm.getBinsFor(frequencyRange: fromFrequencyRange)
//    }
    
    //MARK: Get bin slices
//    public func getDecibelSlice(fromBinRange:[Int]) -> [Double] {
//
//        return _fm.getSlice(bins: fromBinRange, spectrum: decibels)
//    }
    
//    public func getMagnitudeSlice(fromBinRange:[Int]) -> [Double] {
//
//        return _fm.getSlice(bins: fromBinRange, spectrum: magnitudes)
//    }
    
    //MARK: Get spectrum slices
//    public func getDecibelSlice(fromFrequencyRange:[Double]) -> [Double] {
//
//        return _fm.getSlice(frequencyRange: fromFrequencyRange, spectrum: decibels)
//    }
    
//    public func getMagnitudeSlice(fromFrequencyRange:[Double]) -> [Double] {
//
//        return _fm.getSlice(frequencyRange: fromFrequencyRange, spectrum: magnitudes)
//    }
    
    
    //MARK: Get wave value via frequency range
//    public func getDecibel(fromFrequencyRange:[Double]) -> Double {
//
//        return _fm.getWaveValue(frequencyRange: fromFrequencyRange, spectrum: decibels)
//    }
    
//    public func getMagnitude(fromFrequencyRange:[Double]) -> Double {
//
//        return _fm.getWaveValue(frequencyRange: fromFrequencyRange, spectrum: magnitudes)
//    }
    
    
    //MARK: Get wave value via bins
//    public func getDecibel(fromBinRange:[Int]) -> Double {
//
//        return _fm.getWaveValue(bins: fromBinRange, spectrum: decibels)
//    }
    
//    public func getMagnitude(fromBinRange:[Int]) -> Double {
//        
//        return _fm.getWaveValue(bins: fromBinRange, spectrum: magnitudes)
//    }

}
