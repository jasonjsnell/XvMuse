//
//  XvMuseEEGWave.swift
//  XvMuse
//
//  Created by Jason Snell on 7/9/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

/*
        Delta   Theta   Alpha   Gamma   Beta  < XvMuseEEGWave
                                 ---     ---
 TP9      x       x       x     | x |   | x | < XvMuseEEGSensor
 AF7      x       x       x     | x |    ---
 AF8      x       x       x     | x |     x
 TP10     x       x       x     | x |     x
                                 ___
  
 */

//example: eeg.delta.TP9.decibel <-- delta value from one of the sensors
public class XvMuseEEGWave {
    
    //MARK: - Init
    public var id:Int {
        get { return waveID }
    }
    fileprivate var waveID:Int
    fileprivate var _sensors:[XvMuseEEGSensor]
    internal var sensorValues:[XvMuseEEGValue]
    
    init(waveID:Int, sensors:[XvMuseEEGSensor]) {
        
        //save the incoming vars
        self.waveID = waveID
        self._sensors = sensors
        
        //loop through incoming sensors and create the sensor value objects
        //this enables access to sensor values via the wave
        //example: eeg.delta.TP9
        
        self.sensorValues = []
        
        for s in 0..<_sensors.count {
            
            let sensor:XvMuseEEGSensor = _sensors[s] //grab from incoming array
            
            //init with wave and sensor info
            let sensorValue:XvMuseEEGValue = XvMuseEEGValue(waveID: waveID)
            sensorValue.assign(sensor: sensor)
            
            //save to local array for public accessors
            sensorValues.append(sensorValue)
        }
        
        // init the four regions (front, sides, left, right)
        // by passing those sensors into the region objects
        //example: eeg.delta.front
        
        front = XvMuseEEGValue(waveID: waveID)
        front.assign(sensors: [_sensors[1], _sensors[2]])
        
        sides = XvMuseEEGValue(waveID: waveID)
        sides.assign(sensors: [_sensors[0], _sensors[3]])
        
        left  = XvMuseEEGValue(waveID: waveID)
        left.assign(sensors: [_sensors[0], _sensors[1]])
        
        right = XvMuseEEGValue(waveID: waveID)
        right.assign(sensors: [_sensors[2], _sensors[3]])
        
        //history
        history = XvMuseEEGHistory()
        history.assign(sources: sensorValues)
    }
    
    //MARK: - Sensor Accessors
    
    //references to the sensors objects and their data
    //using the same naming convention as the top-level XvMuseEEGSensor arrays
    
    //example: eeg.delta.leftForehead.magnitude
    
    public var leftEar:XvMuseEEGValue       { get { return sensorValues[0] } }
    public var TP9:XvMuseEEGValue           { get { return sensorValues[0] } }
    
    public var leftForehead:XvMuseEEGValue  { get { return sensorValues[1] } }
    public var FP1:XvMuseEEGValue           { get { return sensorValues[1] } }
    
    public var rightForehead:XvMuseEEGValue { get { return sensorValues[2] } }
    public var FP2:XvMuseEEGValue           { get { return sensorValues[2] } }
    
    public var rightEar:XvMuseEEGValue      { get { return sensorValues[3] } }
    public var TP10:XvMuseEEGValue          { get { return sensorValues[3] } }
    
    //MARK: Regions
    
    public var front:XvMuseEEGValue
    public var sides:XvMuseEEGValue
    public var left:XvMuseEEGValue
    public var right:XvMuseEEGValue
    
    //MARK: - Wave Averages
    
    //example: eeg.delta.decibel <-- average delta value for all 4 sensors
    
    public var magnitude:Double {
    
        get {
            //grab the wave magnitude from each sensor
            let magnitudes:[Double] = _sensors.map { $0.waves[waveID].magnitude }
            
            //and return the average
            return magnitudes.reduce(0, +) / Double(magnitudes.count)
        }
    }
    
    public var decibel:Double {
        
        get {
            //grab the wave decibels from each sensor
            let decibels:[Double] = _sensors.map { $0.waves[waveID].decibel }
            
            //and return the average
            return decibels.reduce(0, +) / Double(decibels.count)
        }
    }
    
    public var percent:Double {
        
        //grab the percent value of this wave from each sensor
        let percents:[Double] = _sensors.map { $0.waves[waveID].percent }
        
        //and return the average
        return percents.reduce(0, +) / Double(percents.count)
        
    }
    
    fileprivate let _fm:FrequencyManager = FrequencyManager.sharedInstance
    
    public var relative:Double {
        
        // get an averaged array of all the sensor's decibel arrays
        if let sensorAveragedDecibels:[Double] = Number.getAverageByIndex(arrays: _sensors.map { $0.decibels }) {
        
            //return the relative percentage for this wave ID
            return _fm.getRelative(waveID: waveID, spectrum: sensorAveragedDecibels)
        
        } else {
            return 0
        }
    }
    
    //MARK: - History
    
    public var history:XvMuseEEGHistory
}
