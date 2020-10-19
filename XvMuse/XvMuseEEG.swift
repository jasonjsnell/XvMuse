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
 eeg.magnitudes
 eeg.decibels
 
 REGION PSD VALUES
 eeg.front.magnitudes
 eeg.side.decibels
 
 SENSOR PSD VALUES
 can use the location or sensor name
 eeg.TP9.magnitudes
 eeg.leftEar.decibels
 
 AVERAGED WAVE VALUES
 eeg.delta.decibel
 eeg.alpha.magnitudes
 
 SENSOR-SPECIFIC WAVE VALUES
 can access via the sensor or via the wave
 eeg.TP9.delta.magnitude
 eeg.alpha.TP10.decibel
 
 */

public class XvMuseEEG {

    //MARK: - WAVES -
    
    public var waves:[XvMuseEEGWave]
    
    public var delta:XvMuseEEGWave
    public var theta:XvMuseEEGWave
    public var alpha:XvMuseEEGWave
    public var beta: XvMuseEEGWave
    public var gamma:XvMuseEEGWave
    
    
    //MARK: - SENSORS -
    
    //return in the order of left ear, left forehead, right forehead, right ear
    public var sensors:[XvMuseEEGSensor]
    
    //Access the sensors by either their technical location (TP9) or head location (leftEar)
    public var leftEar:XvMuseEEGSensor       { get { return sensors[0] } }
    public var TP9:XvMuseEEGSensor           { get { return sensors[0] } }
    
    public var leftForehead:XvMuseEEGSensor  { get { return sensors[1] } }
    public var FP1:XvMuseEEGSensor           { get { return sensors[1] } }
    
    public var rightForehead:XvMuseEEGSensor { get { return sensors[2] } }
    public var FP2:XvMuseEEGSensor           { get { return sensors[2] } }
    
    public var rightEar:XvMuseEEGSensor      { get { return sensors[3] } }
    public var TP10:XvMuseEEGSensor          { get { return sensors[3] } }
    
    // the muse fires in the sequences of right ear, right forehead, left ear, left forehead
    // the func allows the public array to be left to right: left ear, left forehead, right forehead, right ear
    fileprivate let museSensorFireSequence:[Int] = [2, 0, 3, 1]
    fileprivate func getSensorPosition(from id:Int) -> Int { return museSensorFireSequence[id] }
    
    //MARK: - REGIONS -
    /*
    Access to sensor values organized by region
    (1) front or 2) sides of head)
    
    examples:
    eeg.front.magnitudes
    eeg.sides.magnitudes
    eeg.front.decibels
    eeg.sides.decibels
    eeg.left.magnitudes
    eeg.left.magnitudes
    eeg.right.decibels
    eeg.right.decibels
    */
    
    public var regions:[XvMuseEEGRegion]
    public var front:XvMuseEEGRegion
    public var sides:XvMuseEEGRegion
    public var left:XvMuseEEGRegion
    public var right:XvMuseEEGRegion
    
    
    //MARK: - INIT -
    
    public init() {
        
        //init the sensors
        //they are the entry point into this system from the Muse hardware
        //example: for sensor in eeg.sensors { }
        
        sensors = [XvMuseEEGSensor(), XvMuseEEGSensor(), XvMuseEEGSensor(), XvMuseEEGSensor()]
        
        //init the waves
        //example: eeg.delta
        delta = XvMuseEEGWave(waveID: 0)
        theta = XvMuseEEGWave(waveID: 1)
        alpha = XvMuseEEGWave(waveID: 2)
        beta  = XvMuseEEGWave(waveID: 3)
        gamma = XvMuseEEGWave(waveID: 4)
        
        //store in array for user access
        //example: for wave in eeg.waves { }
        waves = [delta, theta, alpha, beta, gamma]
      
        
        // init the four regions (front, sides, left, right)
        // by passing those sensors into the region objects
        //example: eeg.front
        
        front = XvMuseEEGRegion()
        sides = XvMuseEEGRegion()
        left  = XvMuseEEGRegion()
        right = XvMuseEEGRegion()
        
        regions = [front, sides, left, right]
    }
    
    
    //MARK: - DATA UPDATES -
    //Incoming data from device -> FFT
    //this is the entry point from the FFT process to where the data gets mapped out into different sensors, regions, waves, histories, etc...

    public func update(with fftResult:FFTResult?) {
        
        //fftResult is nil when the buffers are loading in the beginng and inbetween Epoch window firings
        
        //so when the fft result is valid...
        
        if (fftResult != nil) {
            
            //MARK: 1. Update sensor objects
            //update the sensor objects first with the FFT's PSD arrays
            //meaning, not split into delta, alpha, etc... but the full PSD array of values
            //example: eeg.TP9.magnitudes
            //example: eeg.TP9.decibels
            
            let sensorPosition:Int = getSensorPosition(from: fftResult!.sensor)
    
            sensors[sensorPosition].updatePsd(
                psd: XvMuseEEGPsd(
                    magnitudes: fftResult!.magnitudes,
                    decibels: fftResult!.decibels
                )
            )
            
            //MARK: 2. Update wave objects
            for wave in waves {
                wave.update(with: sensors)
            }
            
            //MARK: 3. Update regions
            front.update(with: [sensors[1], sensors[2]])
            sides.update(with: [sensors[0], sensors[3]])
            left.update( with: [sensors[0], sensors[1]])
            right.update(with: [sensors[2], sensors[3]])
            
            //MARK: 4. Reset averaging processors for entire EEG
            //reset data on averaging processors
            _cache.update(with: sensors)
            
        }
    }
    
    //MARK: - AVERAGED VALUES -
    
    fileprivate var _cache:SensorCache = SensorCache()
    
    //MARK: Magnitudes
    //example: eeg.magnitudes
    public var magnitudes:[Double] {
        get { return _cache.getMagnitudes() }
    }
    
    //MARK: - Decibels
    //example: eeg.decibels
    public var decibels:[Double] {
        get { return _cache.getDecibels() }
    }
    
    //MARK: - Noise
    public var noise:Int {
        get { return _cache.getNoise() }
    }
    
    //MARK: - SETTERS -
    
    //MARK: History Lengths
    //the length of the sensor or wave value history can be changed by the user
    public var historyLength:Int {
        
        get {
            waves[0].history.historyLength
        }
        
        set {
            
            //each wave in each sensor
            for sensor in sensors {
               
                for wave in sensor.waves {
                    wave.history.historyLength = newValue
                }
            }
            
            for wave in waves {
                
                //each wave
                wave.history.historyLength = newValue
                
                //each sensor in each wave
                for sensorValue in wave.sensorValues {
                    sensorValue.history.historyLength = newValue
                }
                
                for region in wave.regions {
                    region.history.historyLength = newValue
                }
            }
            
            for region in regions {
                
                for wave in region.waves {
                    wave.history.historyLength = newValue
                }
            }
        }
    }
    
    //MARK: - GETTERS -
    
    //MARK: Accessing custom frequency ranges
    fileprivate let _fm:FrequencyManager = FrequencyManager.sharedInstance
    
    
    //MARK: Get bins
    public func getBins(fromFrequencyRange:[Double]) -> [Int] {
        
        return _fm.getBinsFor(frequencyRange: fromFrequencyRange)
    }
    
    //MARK: Get bin slices
    public func getDecibelSlice(fromBinRange:[Int]) -> [Double] {
        
        return _fm.getSlice(bins: fromBinRange, spectrum: decibels)
    }
    
    public func getMagnitudeSlice(fromBinRange:[Int]) -> [Double] {
        
        return _fm.getSlice(bins: fromBinRange, spectrum: magnitudes)
    }
    
    //MARK: Get spectrum slices
    public func getDecibelSlice(fromFrequencyRange:[Double]) -> [Double] {
        
        return _fm.getSlice(frequencyRange: fromFrequencyRange, spectrum: decibels)
    }
    
    public func getMagnitudeSlice(fromFrequencyRange:[Double]) -> [Double] {
        
        return _fm.getSlice(frequencyRange: fromFrequencyRange, spectrum: magnitudes)
    }
    
    
    //MARK: Get wave value via frequency range
    public func getDecibel(fromFrequencyRange:[Double]) -> Double {
        
        return _fm.getWaveValue(frequencyRange: fromFrequencyRange, spectrum: decibels)
    }
    
    public func getMagnitude(fromFrequencyRange:[Double]) -> Double {
        
        return _fm.getWaveValue(frequencyRange: fromFrequencyRange, spectrum: magnitudes)
    }
    
    
    //MARK: Get wave value via bins
    public func getDecibel(fromBinRange:[Int]) -> Double {
        
        return _fm.getWaveValue(bins: fromBinRange, spectrum: decibels)
    }
    
    public func getMagnitude(fromBinRange:[Int]) -> Double {
        
        return _fm.getWaveValue(bins: fromBinRange, spectrum: magnitudes)
    }

}
