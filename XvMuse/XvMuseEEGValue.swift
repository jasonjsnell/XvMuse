//
//  XvMuseEEGValue.swift
//  XvMuse
//
//  Created by Jason Snell on 7/11/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

public class XvMuseEEGValue {
    
    //wave and sensor info
    fileprivate var waveID:Int
    fileprivate var sensor:XvMuseEEGSensor?
    fileprivate var sensors:[XvMuseEEGSensor]?
    
    //publicly accessible history
    public var history:XvMuseEEGHistory
    
    //MARK: - INIT -
    init(waveID:Int) {
        self.waveID = waveID
        _cache =  WaveValuesCache(waveID: waveID)
        history = XvMuseEEGHistory()
    }
    
    //MARK: - DATA UPDATES
    //if this object is owned by a sensor
    internal func update(with sensor:XvMuseEEGSensor){
        
        _cache.update(sensor: sensor)
        history.update(with: self)
    }
    
    //if this object is owned by a region of sensors
    internal func update(with sensors:[XvMuseEEGSensor]){
        
        _cache.update(sensors: sensors)
        history.update(with: self)
    }
    
    //MARK: - WAVE VALUE PROCESSING -
    fileprivate let _cache:WaveValuesCache
    
    //example: eeg.TP9.delta.magnitude
    public var magnitude: Double { get { return _cache.getMagnitude() } }
    public var decibel: Double {   get { return _cache.getDecibel()   } }
    public var relative:Double {   get { return _cache.getRelative()  } }
    
    //percent
    public var percent:Double { get { return decibel / history.highest.decibel } }
   

}
