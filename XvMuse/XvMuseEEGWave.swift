//
//  XvMuseEEGWave.swift
//  XvMuse
//
//  Created by Jason Snell on 7/9/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

/*
instead of linking to Sensor Object, which could cause a circular reference
(TP9.delta.TP9.delta.etc...)
this is a simpler Sensor Value Object, which has the waves's 4 sensor values
example: eeg.TP9.delta.magnitude
*/

public class XvMuseEEGSensorValue:EEGValuePair {
    public var history:XvMuseEEGValueHistory = XvMuseEEGValueHistory()
}

//example: eeg.delta.decibel     <-- average delta value for all 4 sensors
//example: eeg.delta.TP9.decibel <-- delta value from one of the sensors
public class XvMuseEEGWave {
    
    public var magnitude:Float = 0 // fft absolute magnitudes
    public var decibel:Float = 0 // magnitudes processed into decibels
    
    public var sensors:[XvMuseEEGSensorValue] = [
        XvMuseEEGSensorValue(),
        XvMuseEEGSensorValue(),
        XvMuseEEGSensorValue(),
        XvMuseEEGSensorValue()
    ]
    
    // TP 9
    public var leftEar:XvMuseEEGSensorValue       { get { return sensors[XvMuseConstants.EEG_SENSOR_EAR_L] } }
    public var TP9:XvMuseEEGSensorValue           { get { return sensors[XvMuseConstants.EEG_SENSOR_EAR_L] } }
    
    // AF 7 / FP1
    public var leftForehead:XvMuseEEGSensorValue  { get { return sensors[XvMuseConstants.EEG_SENSOR_FOREHEAD_L] } }
    public var FP1:XvMuseEEGSensorValue           { get { return sensors[XvMuseConstants.EEG_SENSOR_FOREHEAD_L] } }
    
    // AF 8 / FP2
    public var rightForehead:XvMuseEEGSensorValue { get { return sensors[XvMuseConstants.EEG_SENSOR_FOREHEAD_R] } }
    public var FP2:XvMuseEEGSensorValue           { get { return sensors[XvMuseConstants.EEG_SENSOR_FOREHEAD_R] } }
    
    // TP 10
    public var rightEar:XvMuseEEGSensorValue      { get { return sensors[XvMuseConstants.EEG_SENSOR_EAR_R] } }
    public var TP10:XvMuseEEGSensorValue          { get { return sensors[XvMuseConstants.EEG_SENSOR_EAR_R] } }
}
