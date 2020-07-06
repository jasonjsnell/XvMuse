//
//  XvMuseEEGSensor.swift
//  XvMuse
//
//  Created by Jason Snell on 7/5/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

public class XvMuseEEGSensor {
    
    //each band on this sensor
    public var delta:XvMuseEEGBand { get { return _bands[0] } }
    public var theta:XvMuseEEGBand { get { return _bands[1] } }
    public var alpha:XvMuseEEGBand { get { return _bands[2] } }
    public var beta:XvMuseEEGBand  { get { return _bands[3] } }
    public var gamma:XvMuseEEGBand { get { return _bands[4] } }

    public var magnitudes:[Double] = []
    public var decibels:[Double] = []
    public var epoch:[Double] = []
    
    internal var _bands:[XvMuseEEGBand]
    
    init(){
        
        _bands = [XvMuseEEGBand(), XvMuseEEGBand(), XvMuseEEGBand(), XvMuseEEGBand(), XvMuseEEGBand()]
        
    }
}
