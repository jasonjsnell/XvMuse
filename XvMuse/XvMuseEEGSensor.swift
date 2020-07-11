//
//  XvMuseEEGSensor.swift
//  XvMuse
//
//  Created by Jason Snell on 7/5/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

/*
 instead of linking to Wave Object, which could cause a circular reference
 (delta.TP9.delta.TP9.etc...)
 this is a simpler Wave Value Object, which has the sensor's delta values
 example: eeg.TP9.delta.magnitude
 */

public class XvMuseEEGWaveValue:EEGValuePair {
    public var history:XvMuseEEGValueHistory = XvMuseEEGValueHistory()
}

//object accessed directly from FFT Result
//has each brainwave value, or entire PSD as magnitudes or decibels
public class XvMuseEEGSensor {
    
    //each wave value on this sensor
    public var waves:[XvMuseEEGWaveValue]
    public var delta:XvMuseEEGWaveValue { get { return waves[0] } }
    public var theta:XvMuseEEGWaveValue { get { return waves[1] } }
    public var alpha:XvMuseEEGWaveValue { get { return waves[2] } }
    public var beta:XvMuseEEGWaveValue  { get { return waves[3] } }
    public var gamma:XvMuseEEGWaveValue { get { return waves[4] } }

    //entire PSD spectrum magnitudes and decibels
    public var psd:XvMuseEEGPsd = XvMuseEEGPsd()
    
    init(){
        waves = [XvMuseEEGWaveValue(), XvMuseEEGWaveValue(), XvMuseEEGWaveValue(), XvMuseEEGWaveValue(), XvMuseEEGWaveValue()]
    }
}
