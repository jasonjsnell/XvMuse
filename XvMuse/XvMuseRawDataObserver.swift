//
//  XvMuseRawDataObserver.swift
//  XvMuse
//
//  Tap for the session raw archive. Implemented by the app's raw recorder.
//
//  The data callbacks fire at full stream rate on the Bluetooth processing queue,
//  straight from the packet parser, so the data has had nothing done to it yet.
//  An implementation must be cheap and thread safe.
//

import Foundation
import XvSensors

public protocol XvMuseRawDataObserver: AnyObject {

    ///One sensor's EEG samples, in microvolts. configSensorIndex is
    ///0 = TP9, 1 = AF7, 2 = AF8, 3 = TP10.
    ///deviceTime is the PHONE's clock, in seconds since the app launched, taken
    ///when the Bluetooth notification was handled. It is not the headset's clock,
    ///despite the name, so gaps in it mean late arrival, not necessarily loss.
    func didReceiveRawEEG(configSensorIndex: Int, samples: [Double], deviceTime: Double)

    ///One optical channel's samples. Athena reports a single pre-averaged
    ///channel (index 0); the legacy headsets report three wavelengths (0, 1, 2).
    ///deviceTime as above.
    func didReceiveRawPPG(channelIndex: Int, samples: [Double], deviceTime: Double)

    ///One accelerometer reading, in g. deviceTime as above.
    func didReceiveRawIMU(x: Double, y: Double, z: Double, deviceTime: Double)

    /* The framework's current identification of the connected headset, sent every
     time it changes, on the main thread.

     Sent more than once per connection, deliberately. Selecting an Athena first
     reports .museS, because both advertise the same "MuseS" name, and only later
     reports .museAthena, once its Athena characteristic turns up in discovery.
     Data does not flow until discovery has finished, so the last value received
     before the samples is the right one to label them with.

     Also sent immediately when an observer is attached, if a headset is already
     identified, so an observer that arrives late still knows the device. */
    func didIdentifyDevice(_ device: XvDeviceName)
}

public extension XvMuseRawDataObserver {
    ///Optional: an observer that does not care which headset it is can ignore this.
    func didIdentifyDevice(_ device: XvDeviceName) {}
}
