//
//  XvMuseEEGSensor.swift
//  XvMuse
//
//  Created by Jason Snell on 7/5/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

internal class MuseEEGSensor {
    
    // receive update from FFT result
    internal func update(withFftPowerSpectrum: [Double]) {
        self.linearSpectrum = withFftPowerSpectrum
    }

    //delegate access this spectrum to pass up to parent app
    public var linearSpectrum: [Double] = []
    
    init(){}

}
