//
//  XvMuseRawDataObserver.swift
//  XvMuse
//
//  Tap for the session raw archive. Implemented by the app's raw recorder.
//
//  These fire at full stream rate on the Bluetooth processing queue, straight
//  from the packet parser, so the data has had nothing done to it yet. An
//  implementation must be cheap and thread safe.
//

import Foundation

public protocol XvMuseRawDataObserver: AnyObject {

    ///One sensor's EEG samples, in microvolts. configSensorIndex is
    ///0 = TP9, 1 = AF7, 2 = AF8, 3 = TP10. deviceTime is the headset clock.
    func didReceiveRawEEG(configSensorIndex: Int, samples: [Double], deviceTime: Double)

    ///One optical channel's samples. Athena reports a single pre-averaged
    ///channel (index 1); the legacy headsets report three wavelengths (0, 1, 2).
    func didReceiveRawPPG(channelIndex: Int, samples: [Double], deviceTime: Double)

    ///One accelerometer reading, in g.
    func didReceiveRawIMU(x: Double, y: Double, z: Double, deviceTime: Double)
}
