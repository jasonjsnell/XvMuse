//
//  BluetoothConstants.swift
//  XvBluetooth
//
//  Created by Jason Snell on 5/17/17.
//  Copyright © 2017 Jason J. Snell. All rights reserved.
//

import Foundation

//PUBLIC ON PURPOSE, despite the folder name: sibling Xv projects import
//this directly. Narrowing it would break them. See the access-level note
//in XvMuse.swift.
public class BluetoothConstants {
    
    //MARK: - NOTIFICATIONS -
    //MARK: when bluetooth data is received
    public static let kXvBluetoothValueReceived:String = "kXvBluetoothValueReceived"
    
    public static let kXvBluetoothCentralManagerUpdateState:String = "kXvBluetoothCentralManagerUpdateState"
    
    public static let kXvBluetoothDeviceDiscovered:String = "kXvBluetoothDeviceDiscovered"
    
    public static let kXvBluetoothServiceDiscovered:String = "kXvBluetoothServiceDiscovered"
    
    public static let kXvBluetoothCharacteristicDiscovered:String = "kXvBluetoothCharacteristicDiscovered"
    
}


