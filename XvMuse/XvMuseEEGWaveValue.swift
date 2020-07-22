//
//  XvMuseEEGValue.swift
//  XvMuse
//
//  Created by Jason Snell on 7/11/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation
import XvUtils

public class XvMuseEEGValue {
    
    //wave and sensor info
    fileprivate var waveID:Int
    fileprivate var sensor:XvMuseEEGSensor?
    fileprivate var sensors:[XvMuseEEGSensor]?
    
    //publicly accessible history
    public var history:XvMuseEEGHistory = XvMuseEEGHistory()
    
    init(waveID:Int) {
        self.waveID = waveID
        history.assign(source: self)
    }
    
    //MARK: Sensor source
    //this object can be powered by EITHER one sensor or an array of sensors, but not both.
    //these assign funcs will block an object from being assigned to two sources
    internal func assign(sensor:XvMuseEEGSensor?){
        if (sensors == nil) {
            self.sensor = sensor
        } else {
            print("XvMuseEEGValue: Error: Object has already been assigned to a set of sensors.")
        }
    }
    
    internal func assign(sensors:[XvMuseEEGSensor]?){
        if (sensor == nil) {
            self.sensors = sensors
        } else {
            print("XvMuseEEGValue: Error: Object has already been assigned to a single sensors.")
        }
    }
    
    
    //example: eeg.TP9.delta.magnitude
    public var magnitude: Double {
        
        get {
            
            //if single sensor
            if (sensor != nil) {
                
                //process into a single value
                return _fm.getWaveValue(waveID: waveID, spectrum: sensor!.magnitudes)
                
            } else if (sensors != nil) {
                
                //if multiple sensors
                
                //average the arrays
                if let averagedMagnitudes = Number.getAverageByIndex(arrays: sensors!.map { $0.magnitudes }) {
                    
                    //process into a single value
                    return _fm.getWaveValue(waveID: waveID, spectrum: averagedMagnitudes)
                    
                } else {
                    
                    print("XvMuseEEGValue: Error: Unable to calculate averaged magnitudes of sensors set")
                    return 0
                }
                
            } else {
                print("XvMuseEEGValue: Error: No sensor(s) when attempting to calculate wave magnitude")
                return 0
            }
        }
    }
    
    public var decibel: Double {
        
        get {
            
            //if single sensor
            if (sensor != nil) {
                
                //process into a single value
                return _fm.getWaveValue(waveID: waveID, spectrum: sensor!.decibels)
                
            } else if (sensors != nil) {
                
                //if multiple sensors
                
                //average the arrays
                if let averagedDecibels = Number.getAverageByIndex(arrays: sensors!.map { $0.decibels }) {
                    
                    //process into a single value
                    return _fm.getWaveValue(waveID: waveID, spectrum: averagedDecibels)
                    
                } else {
                    
                    print("XvMuseEEGValue: Error: Unable to calculate averaged decibels of sensors set")
                    return 0
                }
                
            } else {
                print("XvMuseEEGValue: Error: No sensor(s) allocated when attempting to calculate wave decibel")
                return 0
            }
        }
    }
    
    public var relative:Double {
        
        get {
            
            if (sensor != nil) {
                 
                 //if this is an individual sensor
                 return _fm.getRelative(waveID: waveID, spectrum: sensor!.decibels)
                
            } else if (sensors != nil) {
                
                //if multiple sensors
                if let averagedDecibels = Number.getAverageByIndex(arrays: sensors!.map { $0.decibels }) {
                    
                    //process into a single spectrum
                 return _fm.getRelative(waveID: waveID, spectrum: averagedDecibels)
                    
                } else {
                    
                    print("XvMuseEEGValue: Relative: Error: Unable to calculate averaged decibels of sensors set")
                    return 0
                }
                
            } else {
                print("XvMuseEEGValue: Error: No sensor(s) when attempting to calculate relative value")
                return 0
            }
        }
    }
    
    public var percent:Double {
        
        get { return decibel / history.highest.decibel }
    }
    
    //MARK: Helpers
    
    //helpers
    fileprivate let _fm:FrequencyManager = FrequencyManager.sharedInstance
    
    fileprivate func _getValue(from spectrum:[Double]) -> Double {
        
        return _fm.getWaveValue(
            waveID: waveID,
            spectrum: spectrum
        )
    }

}
