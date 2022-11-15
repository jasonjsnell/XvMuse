//
//  Listener.swift
//  XvBluetooth
//
//  Created by Jason Snell on 5/22/17.
//  Copyright © 2017 Jason J. Snell. All rights reserved.
//

/*
 BluetoothListener object that listens to an indivdual BLE device
 //https://stackoverflow.com/questions/26501276/converting-hex-string-to-nsdata-in-swift/26503955
 //https://stackoverflow.com/questions/26377615/ble-swift-write-characterisitc
 //https://learn.adafruit.com/crack-the-code/communication
 //http://forum.choosemuse.com/t/muse-2016-bluetooth-packet-format/1887
 */

import CoreBluetooth

class BluetoothListener:NSObject {
    
    //bluetooth objects
    fileprivate var _centralManager: CBCentralManager?
    fileprivate var _device: CBPeripheral?
    fileprivate var _services:[CBService] = []
    fileprivate var _characteristics:[CBCharacteristic] = []
    
    //device, service, characteristics IDs
    public var deviceUUID:CBUUID? { get { return _deviceUUID }}
    fileprivate var _deviceUUID:CBUUID?
    fileprivate var _serviceUUID:CBUUID?
    fileprivate var _characteristicsUUIDs:[CBUUID]?
    
    //view controller to send updates to
    fileprivate weak var observer:XvBluetoothObserver?
    
    fileprivate let debug:Bool = false
    
    init(
        observer:XvBluetoothObserver,
        deviceUUID:CBUUID?,
        serviceUUID:CBUUID?, // can be nil
        characteristicsUUIDs: [CBUUID]){
        
        super.init()
        
        //capture vc
        self.observer = observer
        
        //capture IDs
        _deviceUUID = deviceUUID
        _serviceUUID = serviceUUID
        _characteristicsUUIDs = characteristicsUUIDs
        
        //init bluetooth
        //let workerQueue = DispatchQueue(label: "com.xv.EEGOSX.workerQueue")
        //let options: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: true]
        
        //_centralManager = CBCentralManager(delegate: self, queue: workerQueue, options: options)
        _centralManager = CBCentralManager(delegate: self, queue: nil)
        
        if (debug){ print("BLUETOOTH LISTENER: Init") }
        
    }
    
    internal func connect(){
        
        if (_centralManager != nil) {
            
            //init connection
            disconnect()
            
            //print("BLUETOOTH: Connect")
            
            if (_serviceUUID != nil && _deviceUUID != nil) {
                
                //scan for device with service
                _centralManager!.scanForPeripherals(withServices: [_serviceUUID!], options: nil)
                
            } else {
                
                //if no service ID, scan for all, and look for device ID
                _centralManager!.scanForPeripherals(withServices: nil, options: nil) //scans for all bluetooth devices in area
            }
            
        } else {
            print("BLUETOOTH: Error: Central Manager is nil in connect()")
        }
        
    }
    
    internal func disconnect(){
        
        if (_centralManager != nil) {
            
            if (debug){ print("BLUETOOTH: Disconnect") }
            
            //stop scan if one is occurring
            if (_centralManager!.isScanning){
                _centralManager!.stopScan()
            }
            
            //release peripheral if one is connected
            if (_device != nil){
                _centralManager!.cancelPeripheralConnection(_device!)
            }
            
        } else {
            print("BLUETOOTH: Error: Central Manager is nil in disconnect()")
        }
        
    }
    
    @objc internal func scanEnded(){
        
        if (_centralManager != nil){
            
            _centralManager!.stopScan()
            
            if (debug){ print("BLUETOOTH: Scan ended") }
            
        } else {
            print("BLUETOOTH: Error: Central Manager is nil in scanEnded()")
        }
    }
}

//MARK: - CENTRAL MANAGER FUNCTIONS -
//these are functions relating to the "central" device, the home device that is looking for the periphereal device
//for example, the iphone or Mac computer searaching for the bluetooth headset
extension BluetoothListener: CBCentralManagerDelegate {
    
    //MARK: State change for the central BLE (power on, off, etc.) not the periphereal
    
    internal func centralManagerDidUpdateState(_ central: CBCentralManager) {
        
        if (debug){
            BluetoothUtils.printState(state: central.state) //output status during debugging
        }
        
        observer?.update(state: BluetoothUtils.getDesc(forState: central.state))
        
    }
    
    
    
    //MARK: Peripherals discovered
    internal func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String : Any],
        rssi RSSI: NSNumber)
    {
        
        if (debug){ print("BLUETOOTH: Scanning nearby devices...", peripheral.identifier.uuidString) }
        
        if (deviceUUID != nil) {
            observer?.discovered(targetDevice: peripheral) //if the device with the target UUID is found
        } else {
            observer?.discovered(nearbyDevice: peripheral) //if no device CBUUID is avail, show scan results for all nearby devices
        }
        
        
        if (deviceUUID != nil && peripheral.identifier.uuidString == _deviceUUID!.uuidString){
            
            //stop the scan
            if (_centralManager != nil) {
                
                if (debug){ print("BLUETOOTH: Scan complete") }
                _centralManager!.stopScan()
                
            } else {
                if (debug){ print("BLUETOOTH: Error: Central Manager is nil in didDiscover peripheral") }
            }
            
            if (debug){ print("BLUETOOTH: Target device discovered = ", peripheral) }
            
            _device = peripheral //retain ref
            
            //set delegate to self (which is the peripheral code extension below)
            _device!.delegate = self
            
            //attempt to connect to the newly discovered peripheral
            if (_centralManager != nil) {
                _centralManager!.connect(_device!, options: nil)
            
            } else {
                print("BLUETOOTH: Error: Central Manager is nil in didDiscover peripheral()")
            }
            
        }
    }
    
    //MARK: Did connect to the peripheral
    internal func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        
        // Connection was successful, now search for services
        // (which takes us down to the code extension below for peripherals)
        
        if (debug){ print("BLUETOOTH: Connected to target device", peripheral.identifier.uuidString) }
        if (_device != nil){
            _device!.discoverServices(nil)
        
        } else {
            print("BLUETOOTH: Error: Device is nil in didConnect peripheral()")
        }
    }
    
    internal func centralManager(_ central: CBCentralManager,
            didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // IME the error codes encountered are:
        // 0 = rebooting the peripheral.
        // 6 = out of range.
        if let error:Error = error {
            print("BLUETOOTH: Disconnect:", error)
            observer?.didLoseConnection()
            
        } else {
            // Likely a deliberate unpairing.
             print("BLUETOOTH: Disconnect: Unpaired")
            observer?.didDisconnect()
        }
    }
}

//MARK: - DEVICE FUNCTIONS -
//these are methods relating to the device that is found, like the headset, and it sends data back to the central device
extension BluetoothListener: CBPeripheralDelegate {
    
    //MARK: Services were discovered
    internal func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        
        guard let services:[CBService] = _device!.services else {
            return
        }
        
        //save for later ref
        _services = services
        
        //search for services on peripheral
        for service in services{
            
            if (debug){ print("BLUETOOTH: Discovered service", service) }
            
            observer?.discovered(service: service)
            
            //search for its characteristics
            _device!.discoverCharacteristics(nil, for: service)
            //_device!.discoverCharacteristics(_characteristicsUUIDs, for: service)
            
        }
    }
    
    //MARK: Characteristics were discovered
    internal func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        
        guard let characteristics:[CBCharacteristic] = service.characteristics else {
            return
        }
        
        //save for later access
        _characteristics = characteristics
        
        if (debug){ print("BLUETOOTH:", characteristics.count, "characteristics found") }
        
        //loop through the incoming characteristics
        for characteristic in characteristics {
            
            observer?.discovered(characteristic: characteristic)
            
            if (debug) {
                print("BLUETOOTH: Discovered characteristic", characteristic.description)
                //Utils.printType(forCharacteristic: characteristic)
            }
            
            //for each charactertistic, see if it's UUID matches any of the UUIDs passed in during init
            for charUUID in _characteristicsUUIDs! {
                
                //if there is a match
                if (characteristic.uuid == charUUID) {
                    
                    //set notify if avail
                    if (characteristic.properties.contains(.notify)){
                        
                        if (debug){ print("BLUETOOTH: Add notify for characteristic", characteristic.uuid) }
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                   
                    //read if avail
                    if (characteristic.properties.contains(.read)){
                        peripheral.readValue(for: characteristic)
                    }
                }
            }
        }
    }
    
    //MARK: Value updates from the connected device
    internal func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        
        if let error = error {
            print("BLUETOOTH: Update value: Error:", error)
        }
        
        //guard characteristic.value != nil else {
          //  return
        //}
        
        if (debug) { print("BLUETOOTH: Update value", characteristic.description, characteristic.value as Any) }
        
        observer?.received(valueFromCharacteristic: characteristic, fromDevice: peripheral)

    }
    
    //MARK: Write to characteristic success
    //Tells the delegate that the peripheral successfully set a value for the characteristic.
    internal func peripheral(_ :CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
   
        if (debug) { print("BLUETOOTH: Did write value for characteristic", characteristic) }
    }
    
    
    //if the notification state changes on a charactertic, it shows up here
    internal func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        
        if (debug) { print("BLUETOOTH: Update notification state for:", characteristic.uuid.uuidString, "to", characteristic.isNotifying) }
    }
    
    //MARK: Device ready for another write value command
    //Tells the delegate that a peripheral is again ready to send characteristic updates.
    internal func peripheralIsReady(toSendWriteWithoutResponse: CBPeripheral) {
        
        if (debug) { print("BLUETOOTH: Device is ready for writeValue again") }
    }
    
    //MARK: Discovered descriptors
    internal func peripheral(_peripheral: CBPeripheral, didDiscoverDescriptorsFor: CBCharacteristic, error: Error?) {
        
        for desc in didDiscoverDescriptorsFor.descriptors! {
            print("BLUETOOTH: Descriptor discovered:", desc)
        }
    }
    

    
    //https://stackoverflow.com/questions/31760067/sending-hex-string-using-writevalue-in-swift
    public func write(data:Data, toDeviceWithID:CBUUID, forCharacteristicWithID:CBUUID, withType:CBCharacteristicWriteType) {
        
        //if this listener is targetting the correct device...
        if (_device != nil){
            
            //if the incoming device id the same as this listener's device ID...
            if (toDeviceWithID.uuidString == _device!.identifier.uuidString) {
                
                //get the CBChar object for the incoming ID
                if let characteristic:CBCharacteristic = _getCharacteristic(fromID: forCharacteristicWithID) {
                    
                    //then write data to that characteristic
                    _device!.writeValue(data, for: characteristic, type: withType)
                    
                }  else {
                    print("BLUETOOTH: Error: Unable to find characteristic with ID", forCharacteristicWithID, "in write(data) func")
                }
                
                
            }
        } else {
            print("BLUETOOTH: Error: Device is nil in write(data) func")
        }
        
        
    }
    
    fileprivate func _getCharacteristic(fromID:CBUUID) -> CBCharacteristic? {
        
        for characteristic in _characteristics {
            
            if (characteristic.uuid.uuidString == fromID.uuidString){
                return characteristic
            }
        }
        
        return nil
    }
}



