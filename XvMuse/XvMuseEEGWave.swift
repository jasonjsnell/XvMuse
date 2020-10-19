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
    
    //MARK: - INIT -
    public var id:Int { get { return waveID } }
    fileprivate var waveID:Int
    
    internal var sensorValues:[XvMuseEEGValue]
    fileprivate let _fm:FrequencyManager = FrequencyManager.sharedInstance
    
    init(waveID:Int) {
        
        //save the incoming vars
        self.waveID = waveID
        
        //create the sensor value object array
        //this enables access to sensor values via the wave
        //example: eeg.delta.TP9
        
        sensorValues = [XvMuseEEGValue](
            repeating: XvMuseEEGValue(waveID: waveID),
            count: XvMuseConstants.EEG_SENSOR_TOTAL
        )
        
        // init the four regions (front, sides, left, right)
        //example: eeg.delta.front
        front = XvMuseEEGValue(waveID: waveID)
        sides = XvMuseEEGValue(waveID: waveID)
        left  = XvMuseEEGValue(waveID: waveID)
        right = XvMuseEEGValue(waveID: waveID)
        regions = [front, sides, left, right]

        //history
        history = XvMuseEEGHistory()
        
        //averaging processor
        _cache = WaveAveragesCache(waveID: waveID)
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
    
    public var regions:[XvMuseEEGValue]
    public var front:XvMuseEEGValue
    public var sides:XvMuseEEGValue
    public var left:XvMuseEEGValue
    public var right:XvMuseEEGValue
    
    //MARK: - History
    public var history:XvMuseEEGHistory
    
    //MARK: - DATA UPDATES -
    
    internal func update(with sensors:[XvMuseEEGSensor]) {
        
        //update regions
        front.update(with: [sensors[1], sensors[2]])
        sides.update(with: [sensors[0], sensors[3]])
        left.update(with:  [sensors[0], sensors[1]])
        right.update(with: [sensors[2], sensors[3]])
        
        //update sensor value objects with correspondng sensor
        for s in (0..<sensorValues.count) {
            sensorValues[s].update(with: sensors[s])
        }
        
        //update averaging processors
        _cache.update(sensors: sensors)
        
        //update history with new sensor values
        history.update(with: sensorValues)
        
    }
    
    //MARK: - AVERAGES VALUES -
    //example: eeg.delta.decibel <-- average delta value for all 4 sensors
    fileprivate var _cache:WaveAveragesCache
    
    public var magnitude:Double { get { return _cache.getMagnitude() } }
    public var decibel:Double {   get { return _cache.getDecibel()   } }
    public var percent:Double {   get { return _cache.getPercent()   } }
    public var relative:Double {  get { return _cache.getRelative()  } }
    
    
}
