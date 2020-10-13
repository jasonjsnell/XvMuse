//
//  Average.swift
//  XvMuse
//
//  Created by Jason Snell on 8/3/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

/*
 High performance storage object
 Doing averages of arrays (particular arrays by index) are expensive, and these objects may be called multiple times in a single refresh from various View Controllers. To lower the CPU use, these numbers are only calculated if called (because calculating them all each refresh is also expensive) and only calculated once. For each refresh, the calculated result is stored in a variable, which is return subsequent calls
 
 Example
 
 Refresh cycle begins
 First call to object: calculate new result, store in variable
 Second call to object: return var
 Third, etc...: return var
 
 */

class SensorCache {
    
    //MARK: - DATA UPDATE - 
    //each FFT refresh, reset the bools
    fileprivate var sensors:[XvMuseEEGSensor] = []
    internal func update(with sensors:[XvMuseEEGSensor]) {

        self.sensors = sensors

        newMagnitudes = true
        newDecibels = true
        newNoise = true
    }
    
    //MARK: - SENSOR GROUPS -
    //Entire EEG and Regions
    
    fileprivate var newMagnitudes:Bool = true
    fileprivate var magnitudes:[Double] = []
    internal func getMagnitudes() -> [Double]{
        
        //if data has been refreshed
        if (newMagnitudes) {
            
            //calculate the new value
            if let _mags:[Double] = Number.getAverageByIndex(
                arrays: sensors.map { $0.magnitudes }) {
                
                magnitudes = _mags
            
            } else {
                print("SensorCache: Error: getMagnitudes")
            }

            //flag as no longer new data
            newMagnitudes = false
        }
        //return the value each time
        return magnitudes
    }
    
    fileprivate var newDecibels:Bool = true
    fileprivate var decibels:[Double] = []
    internal func getDecibels() -> [Double]{
        if (newDecibels) {
            if let _dbs:[Double] = Number.getAverageByIndex(
                arrays: sensors.map { $0.decibels }) {
                
                decibels = _dbs
                
            } else {
                print("SensorCache: Error: getDecibels")
            }
            
            newDecibels = false
        }
        return decibels
    }
    
    fileprivate var newNoise:Bool = true
    fileprivate var noise:Int = 0
    internal func getNoise() -> Int {
        if (newNoise) {
            guard sensors.count != 0 else { return 10 }
            noise = sensors.map { $0.noise }.reduce(0, +) / sensors.count
        }
        return noise
    }
    //MARK: -
}

class WaveAveragesCache {
    
    //MARK: - INIT -
    fileprivate let _fm:FrequencyManager = FrequencyManager.sharedInstance
    
    fileprivate var waveID:Int = 0
    init(waveID:Int){
        self.waveID = waveID
    }
    
    //MARK: - DATA UPDATE -
    //each FFT refresh, reset the bools
    fileprivate var sensors:[XvMuseEEGSensor] = []
    internal func update(sensors:[XvMuseEEGSensor]) {

        self.sensors = sensors
    
        newMagnitude = true
        newDecibel = true
        newPercent = true
        newRelative = true
    }
    
    //MARK: - WAVES -
    
    fileprivate var newMagnitude:Bool = true
    fileprivate var magnitude:Double = 0
    internal func getMagnitude() -> Double{
        
        //if data has been refreshed
        if (newMagnitude) {
            //grab the wave magnitude from each sensor
            let magnitudes:[Double] = sensors.map { $0.waves[waveID].magnitude }
            
            //and calc the average
            magnitude = magnitudes.reduce(0, +) / Double(magnitudes.count)
            
            //flag as no longer new data
            newMagnitude = false
        }
        //return the value each time
        return magnitude
    }
    
    fileprivate var newDecibel:Bool = true
    fileprivate var decibel:Double = 0
    internal func getDecibel() -> Double{
        if (newDecibel) {
            let decibels:[Double] = sensors.map { $0.waves[waveID].decibel }
            decibel = decibels.reduce(0, +) / Double(decibels.count)
            newDecibel = false
        }
        return decibel
    }
    
    fileprivate var newPercent:Bool = true
    fileprivate var percent:Double = 0
    internal func getPercent() -> Double {
        if (newPercent) {
            let percents:[Double] = sensors.map { $0.waves[waveID].percent }
            percent = percents.reduce(0, +) / Double(percents.count)
            newPercent = false
        }
        return percent
    }
    
    fileprivate var newRelative:Bool = true
    fileprivate var relative:Double = 0
    internal func getRelative() -> Double {
        if (newRelative) {
            
            // get an averaged array of all the sensor's decibel arrays
            if let sensorAveragedDecibels:[Double] = Number.getAverageByIndex(arrays: sensors.map { $0.decibels }) {
            
                //return the relative percentage for this wave ID
                relative = _fm.getRelative(
                    waveID: waveID,
                    spectrum: sensorAveragedDecibels
                )
                
            } else {
                print("WaveAveragesCache: Error: getRelative")
            }
            
            newRelative = false
        }
        return relative
    }
    //MARK: - 
}

class WaveValuesCache {
    
    //MARK: - INIT -
    fileprivate let _fm:FrequencyManager = FrequencyManager.sharedInstance
    
    fileprivate var waveID:Int = 0
    init(waveID:Int){
        self.waveID = waveID
    }
    
    fileprivate var sensor:XvMuseEEGSensor?
    fileprivate var sensors:[XvMuseEEGSensor]?
    
    //MARK: - DATA UPDATES -
    
    //single sensor update
    internal func update(sensor:XvMuseEEGSensor) {

        self.sensor = sensor

        newSensorMagnitude = true
        newSensorDecibel = true
        newSensorRelative = true
    }
    
    //multi sensor update
    internal func update(sensors:[XvMuseEEGSensor]) {

        self.sensors = sensors

        newSensorsMagnitude = true
        newSensorsDecibel = true
        newSensorsRelative = true
    }
    
    //MARK: - WAVES -
    fileprivate var newSensorMagnitude:Bool = true
    fileprivate var newSensorsMagnitude:Bool = true
    fileprivate var magnitude:Double = 0
    
    internal func getMagnitude() -> Double{
        
        //if data has been refreshed
        if (newSensorMagnitude && sensor != nil) {
            
            //single sensor
            magnitude = _fm.getWaveValue(
                waveID: waveID,
                spectrum: sensor!.magnitudes
            )
            
            //flag as no longer new data
            newSensorMagnitude = false
        
        } else if (newSensorsMagnitude && sensors != nil) {
            
            //group of sensors, average the arrays
            if let averagedMagnitudes = Number.getAverageByIndex(arrays: sensors!.map { $0.magnitudes }) {
                
                magnitude = _fm.getWaveValue(
                    waveID: waveID,
                    spectrum: averagedMagnitudes
                )
                
            } else {
                print("WaveValuesCache: Error: getMagnitude")
            }
            
            //flag as no longer new data
            newSensorsMagnitude = false
        }
        
        //return the value each time
        return magnitude
    }
    
    fileprivate var newSensorDecibel:Bool = true
    fileprivate var newSensorsDecibel:Bool = true
    fileprivate var decibel:Double = 0
    
    internal func getDecibel() -> Double{
        
        if (newSensorDecibel && sensor != nil) {
            decibel = _fm.getWaveValue(waveID: waveID, spectrum: sensor!.decibels)
            newSensorDecibel = false
        
        } else if (newSensorsDecibel && sensors != nil) {
            if let averagedDecibels = Number.getAverageByIndex(arrays: sensors!.map { $0.decibels }) {
                decibel = _fm.getWaveValue(waveID: waveID, spectrum: averagedDecibels)
            } else { print("WaveValuesCache: Error: getDecibel") }
            newSensorsDecibel = false
        }
        return decibel
    }
    
    fileprivate var newSensorRelative:Bool = true
    fileprivate var newSensorsRelative:Bool = true
    fileprivate var relative:Double = 0
    internal func getRelative() -> Double{
        
        if (newSensorRelative && sensor != nil) {
            relative = _fm.getRelative(waveID: waveID, spectrum: sensor!.decibels)
            newSensorRelative = false
        
        } else if (newSensorsDecibel && sensors != nil) {
            if let averagedDecibels = Number.getAverageByIndex(arrays: sensors!.map { $0.decibels }) {
                relative = _fm.getRelative(waveID: waveID, spectrum: averagedDecibels)
            } else {
                print("WaveValuesCache: Error: getRelative")
            }
            newSensorsRelative = false
        }
        return relative
    }
}
