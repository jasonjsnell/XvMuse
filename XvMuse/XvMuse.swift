//
//  XvMuse.swift
//  XvMuse
//
//  Created by Jason Snell on 6/14/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//
// UInt8  255
// UInt16 65535
// UInt32 4294967295

import Foundation
import CoreBluetooth
import XvSensors
import XvEEG

public enum XvMuseBluetoothState: Equatable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn

    internal init(managerState: CBManagerState) {
        switch managerState {
        case .poweredOn:
            self = .poweredOn
        case .poweredOff:
            self = .poweredOff
        case .unsupported:
            self = .unsupported
        case .unauthorized:
            self = .unauthorized
        case .resetting:
            self = .resetting
        case .unknown:
            self = .unknown
        @unknown default:
            self = .unknown
        }
    }

    public var canScan: Bool {
        self == .poweredOn
    }
}

//another object or a view controller that can listen to this class's updates
public protocol XvMuseDelegate:AnyObject {
    
    //post FFT PSD
    func didReceive(linearSpectrum:[Double])
    func didReceive(frontLinearSpectrum:[Double])
    func didReceive(detailLinearSpectrum:[Double])
    
    //ML and state detection
    func didReceiveQuiet(_ quiet: Double)
    func didReceiveML(noise: Double, tension: Double, blink: Double, clean: Double)
    func didReceiveSensorNoise(tp9: Double, af7: Double, af8: Double, tp10: Double)
    func didReceiveEEGPosition(deltaPan: Double, thetaPan: Double, alphaPan: Double, betaPan: Double, gammaPan: Double, deltaX: Double, deltaY: Double, thetaX: Double, thetaY: Double, alphaX: Double, alphaY: Double, betaX: Double, betaY: Double, gammaX: Double, gammaY: Double)
    func didReceiveBrainwaveState(meditation: Double, focus: Double, dreamy: Double)
    func didReceiveGammaFocus(_ score: Double)
    func didReceiveBrainwaveDimensions(tiltHz: Double, steadiness: Double, intensity: Double, spreadHz: Double, confidence: Double, rhythmHz: Double, rhythmSlowHz: Double)
    func didReceiveStateTuningReadout(_ readout: [String: Double])
    func didReceiveEEGNoteTrigger(_ trigger: XvEEGNoteTrigger)
    func didReceiveEEGBufferProgress(samples: Int, total: Int, progress: Double)
    
    //brainwaves
    func didReceiveBrainwave(delta: Double, theta: Double, alpha: Double, beta: Double, gamma: Double)
    func didReceiveBrainwaveHistory(deltaHistory: [Double], thetaHistory: [Double], alphaHistory: [Double], betaHistory: [Double], gammaHistory: [Double])
    
    //alpha synchrony (left right hemisphere
    func didReceive(faa:Double)
    
    //heart
    func didReceive(ppgStreams:XvPPGStreams)
    func didReceive(ppgHeartEvent:XvPPGHeartEvent)
    
    //motion, battery, command
    func didReceive(accelPacket:XvAccelPacket)
    func didReceive(batteryPacket:XvBatteryPacket)
    func didReceive(commandResponse:[String:Any])
    
    //bluetooth connection updates
    func museIsAttemptingConnection()
    func museIsConnecting()
    func museDidConnect()
    func museDidDisconnect()
    func museLostConnection()
    func didFindNearby(muses: [CBPeripheral])
    func didReceiveBluetoothState(_ bluetoothState: XvMuseBluetoothState, message: String)
    
}

public extension XvMuseDelegate {
    func didReceiveGammaFocus(_ score: Double) {}
    func didReceiveStateTuningReadout(_ readout: [String: Double]) {}
    func didReceive(frontLinearSpectrum:[Double]) {}
    func didReceive(detailLinearSpectrum:[Double]) {}
    func didReceiveBrainwaveDimensions(tiltHz: Double, steadiness: Double, intensity: Double, spreadHz: Double, confidence: Double, rhythmHz: Double, rhythmSlowHz: Double) {}
    func didReceiveEEGNoteTrigger(_ trigger: XvEEGNoteTrigger) {}
    func didReceiveEEGBufferProgress(samples: Int, total: Int, progress: Double) {}
    func didReceiveBluetoothState(_ bluetoothState: XvMuseBluetoothState, message: String) {}
}

//MARK: - PACKETS -
//data objects that get sent to the observer when updates come in from the headband

/* Each time the Muse headband fires off an EEG sensor update (order is: tp10 af8 tp9 af7),
the XvMuse class puts that data into MuseEEGPackets
and sends it here to create a streaming buffer, slice out epoch windows, and return Fast Fourier Transformed array of frequency data
       
       ch1     ch2     ch3     ch4  < EEG sensors tp10 af8 tp9 af7
                       ---     ---
0:00    p       p     | p |   | p | < MuseEEGPacket is one packet of a 12 sample EEG reading, index, timestamp, channel ID
0:01    p       p     | p |    ---
0:02    p       p     | p |     p
0:03    p       p     | p |     p
0:04    p       p     | p |     p
0:05    p       p     | p |     p
                       ___

                        ^ DataBuffer of streaming samples. Each channel has it's own buffer
*/

internal class MusePacket {
    
    internal var packetIndex:UInt16 = 0
    internal var sensor:Int = 0 // 0 to 4: tp10 af8 tp9 af7 aux
    internal var timestamp:Double = 0 // milliseconds since packet creation
    internal var samples:[Double] = [] // 12 samples of EEG sensor data
    
    internal init(packetIndex:UInt16, sensor:Int, timestamp:Double, samples:[Double]){
        self.packetIndex = packetIndex
        self.sensor = sensor
        self.timestamp = timestamp
        self.samples = samples
    }
}

//MARK: - EEG / PPG
internal class MuseEEGPacket:MusePacket {}
internal class MusePPGPacket:MusePacket {}

//MARK: - Battery
internal struct MuseBattery {
    internal var packetIndex:UInt16 = 0
    internal var percentage:Int16 = 0
    internal var raw:[UInt16] = []
}

//MARK: - MUSE -
public class XvMuse:MuseBluetoothObserver, ParserAthenaDelegate, EEGMLManagerDelegate, EEGStateAnalyzerDelegate, XvEEGNoteTriggerDelegate {

    //MARK: - vars

    /* Receives commands from the view controller (like keyDown), translates and sends them to the Muse, and receives data back via parse(bluetoothCharacteristic func */
    public var bluetooth:MuseBluetooth
    
    //this class does generic EEG processing
    public let eeg:XvmEEG
    
    //the view controller that receives EEG, accel, PPG, etc updates
    public weak var delegate:XvMuseDelegate?
    
    //device version
    private var deviceName:XvDeviceName? //.muse2
    private var majorVersion:String? //"Muse"
    private var minorVersion:String? //1, 2, Athena

    /* The identified headset model, for app-side per-device calibration (terrain display gain,
     EQ resting offsets). .unknown until Bluetooth discovery resolves it; the Athena resolves a
     beat after the provisional Muse S guess, so poll on a data callback rather than caching at
     connect. */
    public var connectedDeviceName: XvDeviceName { deviceName ?? .unknown }
    
    
    //MARK: - Private
    //sensor data objects
    private var _eeg:MuseEEG
    private var _testEEG:MuseEEG
    private var _ppg:MusePPG
    private var _testPPG:MusePPG
    private var _accel:MuseAccel
    private var _accelRaw:[Int16] = []
    private var _batteryRaw:[UInt16] = []
    private let _mlManager: EEGMLManager
    private let _stateAnalyzer: EEGStateAnalyzer
    private var latestNoisePct: Double = 0.0
    private var latestCleanPct: Double = 0.0
    private var latestTensionPct: Double = 0.0
    private var latestBlinkPct: Double = 0.0
    private var latestPublishedQuietPct: Double = 0.0
    /* Per-frame blend weights at the ~21 Hz publish rate. The earlier 0.15/0.10 pair (~0.3-0.5 s)
     still let quiet swing fast enough to yank the music around — the wideband loudness it
     measures is naturally jumpy, and every jump went straight to the quiet-driven mixes. Slowed
     to fader-ride speed (Sep 2026): 0.03 falls in ~1.6 s, 0.02 rises in ~2.4 s — quiet now
     describes the last few seconds of stillness rather than the last few frames. Fall stays a
     touch quicker than rise so movement/tension still takes the quiet outputs down promptly.

     This is the SOURCE smoothing, ahead of the split to music and visuals, so it is the one place
     that fixes the shape of the signal for both. */
    private let quietFallSmoothing: Double = 0.03
    private let quietRecoverSmoothing: Double = 0.02

    // Diagnostic: how many brainwave-history points/sec this device's EEG pipeline publishes.
    // Athena vs legacy comparison for the chunky-vs-smooth chart investigation.
    private var _eegPublishCount: Int = 0
    private var _eegPublishWindowStart: Double = 0.0

    // Muse 2 PPG tolerates higher tension before gating heart metrics.
    // Muse S / Athena get a little more headroom because their PPG is stable under mild tension.
    private var heartTensionThreshold: Double {
        switch deviceName {
        case .muse2:
            return 99.0
        case .museS, .museAthena:
            return 90.0
        default:
            return 75.0
        }
    }

    //helper classes
    private let _parserLegacy:ParserLegacy = ParserLegacy() //processes 1/2/S data
    private let _parserAthena:ParserAthena = ParserAthena() //processes Athena data
    private var _fft:FFTManager = FFTManager()

    // Athena protocol diagnostics. These counters are observation-only: parsing still uses the
    // characteristic value read on processingQ so this test does not change existing behavior.
    private var _athenaRXSequence: UInt64 = 0
    private var _athenaLastRXUptime: TimeInterval = 0
    
    //grabs a timestamp when the system launches, to make timestamps easier to read
    private let _systemLaunchTime:Double = Date().timeIntervalSince1970
    
    private var deviceUUID:String?
    
    private let debug:Bool = true
    
    //matrix to store bytes from 4 sensors when recording test data
    private var eegSensorBytes: [[[UInt8]]] = Array(repeating: [], count: 4)
    private var ppgSensorBytes:[[UInt8]] = []
    public func printEEGPPGSensorBytes() {
        print("========== EEG/PPG Data Start ==========")
        for (sensorIndex, packets) in eegSensorBytes.enumerated() {
            print("EEG \(sensorIndex + 1):")
            print(packets)
            print("") // blank line between sensors
        }
        print("")
        print("PPG")
        print(ppgSensorBytes)
        print("========== EEG/PPG Data End ==========")
    }

    private static func museFrequencyBand(_ values: [Int], fallback: ClosedRange<Int>) -> ClosedRange<Int> {
        guard values.count >= 2 else { return fallback }
        let low = min(values[0], values[1])
        let high = max(values[0], values[1])
        return low...high
    }

    private static func museEEGConfig() -> XvEEGConfig {
        let baseConfig = XvSupportedDevices.museConfig
        let museBandConfig = baseConfig.withBandRanges((
            delta: museFrequencyBand(MuseConstants.FREQUENCY_BAND_DELTA, fallback: baseConfig.bandRanges.delta),
            theta: museFrequencyBand(MuseConstants.FREQUENCY_BAND_THETA, fallback: baseConfig.bandRanges.theta),
            alpha: museFrequencyBand(MuseConstants.FREQUENCY_BAND_ALPHA, fallback: baseConfig.bandRanges.alpha),
            beta: museFrequencyBand(MuseConstants.FREQUENCY_BAND_BETA, fallback: baseConfig.bandRanges.beta),
            gamma: museFrequencyBand(MuseConstants.FREQUENCY_BAND_GAMMA, fallback: baseConfig.bandRanges.gamma)
        ))

        return museBandConfig.withDetailBandRangeHz(
            MuseConstants.DETAIL_BANDPASS_LOW_HZ...MuseConstants.DETAIL_BANDPASS_HIGH_HZ
        )
    }
    
    
    //MARK: - INIT -
    //default range is 0 Hz delta to 45 Hz gamma
    public init(deviceUUID:String? = nil) {
       
        if (deviceUUID == nil) {
            print("XvMuse: init with no deviceUUID")
        }
        
        //if a valid device ID string comes in, make a CBUUID for the bluetooth object
        var deviceCBUUID:CBUUID?
        
        if (deviceUUID != nil) {
            self.deviceUUID = deviceUUID //local storage
            deviceCBUUID = CBUUID(string: deviceUUID!)
        }
        
        eeg = XvmEEG(config: Self.museEEGConfig())
        
        _eeg = MuseEEG()
        _testEEG = MuseEEG()
        
        _ppg = MusePPG()
        _testPPG = MusePPG()
        
        _accel = MuseAccel()
        _mlManager = EEGMLManager()
        _stateAnalyzer = EEGStateAnalyzer()
        
     
        bluetooth = MuseBluetooth(deviceCBUUID: deviceCBUUID)
        bluetooth.delegate = self
        bluetooth.start()
        
        _parserAthena.delegate = self
        _fft.delegate = self
        eeg.noteTriggers.delegate = self
        _mlManager.delegate = self
        _stateAnalyzer.delegate = self
    }
    
    //MARK: - Device API -
    //MARK: Nearby Muses
    public func lookForNearbyMuses(){
        
        if (debug) { print("XvMuse: lookForNearbyMuses") }
        
        //reset deviceID
        deviceUUID = nil
        bluetooth.reset()
        
        //connect bluetooth again
        bluetooth.connect()
    }
    
    public func didFindNearby(muses: [CBPeripheral]) {
        //print("XvMuse: didFindNearby", muses)
        delegate?.didFindNearby(muses: muses)
    }

    public func didReceiveBluetoothState(_ bluetoothState: XvMuseBluetoothState, message: String) {
        delegate?.didReceiveBluetoothState(bluetoothState, message: message)
    }
    
    //MARK: User selects Muse
    
    public func userSelectedMuse(museDevice:CBPeripheral){
        
        if let museName = museDevice.name {
            
            // "Muse-66CD" -> "Muse"
            let parts = museName.split(separator: "-")
            if let firstPart = parts.first {
                majorVersion = String(firstPart)
            } else {
                // Fallback if no dash found
                majorVersion = museName
            }
            if (majorVersion == "Muse") {
                deviceName = .muse1
                applyQuietCalibration(deviceDefault: .legacy)
                applyStateCalibration(deviceDefaults: XvMuse.baseStateTuningDefaults)
                _ppg.set(deviceName: .muse1)
            } else if (majorVersion == "MuseS") {
                /* Both the Muse S and the Athena advertise as "MuseS" — same sleep-band housing.
                 This is the provisional guess; if the Athena main characteristic turns up during
                 discovery, discoveredAthena() overwrites both the device and the calibration. */
                deviceName = .museS
                applyQuietCalibration(deviceDefault: .museS)
                applyStateCalibration(deviceDefaults: XvMuse.museSStateTuningDefaults)
                _ppg.set(deviceName: .museS)
            }
            _stateAnalyzer.deviceLabel = deviceName?.rawValue ?? "?"
            print("XvMuse: Major version =", majorVersion ?? "unknown", "| Device may be", deviceName ?? .unknown)
        }
        
        bluetooth.stop() //stop the search
        bluetooth.load(muse: museDevice) //load user selected muse
        processingQ.asyncAfter(deadline: .now() + 1) {
            self.bluetooth.connect()
        }
    }
    
    //MARK: Discovered sensors
    func discoveredPPG() {
        if (majorVersion == "Muse"){
            minorVersion = "2"
            deviceName = .muse2
            applyQuietCalibration(deviceDefault: .muse2)
            applyStateCalibration(deviceDefaults: XvMuse.baseStateTuningDefaults)
            _ppg.set(deviceName: .muse2)
            _stateAnalyzer.deviceLabel = XvDeviceName.muse2.rawValue
        }
        print("XvMuse: Version:", majorVersion ?? "unknown", minorVersion ?? "unknown", "| Device", deviceName ?? .unknown)
    }
    func discoveredAthena() {
        minorVersion = "Athena"
        deviceName = .museAthena
        applyQuietCalibration(deviceDefault: .athena)
        applyStateCalibration(deviceDefaults: XvMuse.athenaStateTuningDefaults)
        _ppg.set(deviceName: .museAthena)
        _stateAnalyzer.deviceLabel = XvDeviceName.museAthena.rawValue
        print("XvMuse: Version:", majorVersion ?? "unknown", minorVersion ?? "unknown", "| Device", deviceName ?? .unknown)
    }
    
    //MARK: Start streaming
    public func startMuse(){
        print("XvMuse: Start streaming Muse data")
        _fft.resetBufferProgress()
        bluetooth.startStreaming()
    }
    
    
    
    //MARK: - DATA PROCESSING -
    internal func parse(bluetoothCharacteristic: CBCharacteristic) {

        let callbackUUID = bluetoothCharacteristic.uuid
        let callbackUptime = ProcessInfo.processInfo.systemUptime

        var athenaRXSequence: UInt64 = 0
        var athenaIngressDeltaMS: Double = 0
        if callbackUUID == MuseConstants.CHAR_ATHENA_MAIN {
            _athenaRXSequence &+= 1
            athenaRXSequence = _athenaRXSequence

            if _athenaLastRXUptime > 0 {
                athenaIngressDeltaMS = (callbackUptime - _athenaLastRXUptime) * 1_000.0
            }
            _athenaLastRXUptime = callbackUptime
        }
        
        processingQ.async { [weak self] in

            //safety checks
            guard let self = self else { return }
            guard let _data:Data = bluetoothCharacteristic.value else { return }

            /* Mock data yields to the real thing. Test packets never come through here — they are
             injected straight into processAndPublishEEGData — so any characteristic arriving in
             this parser is proof of a live, connected headset. If a test set is still looping at
             that moment, the two sources would interleave into one stream and every downstream
             number would be a blend of recorded and live data. (This actually happened during a
             quiet-calibration recording: the log was half test set, half headset.) */
            if self.isTestDataRunning {
                print("XvMuse: Live device data arrived — stopping test data set", self.testDataSet)
                //flag drops here so this fires once; the timers themselves must be invalidated
                //on the main thread, where they were scheduled
                self.isTestDataRunning = false
                DispatchQueue.main.async { self.stopTestData() }
            }
            
            //get a current timestamp, and substract the system launch time so it's a smaller, more readable number
            let timestamp:Double = Date().timeIntervalSince1970 - _systemLaunchTime
            
            //MARK: route Athena data to parser
            // Special-case Athena main stream BEFORE legacy parsing
            if bluetoothCharacteristic.uuid == MuseConstants.CHAR_ATHENA_MAIN {
                let bytes = [UInt8](_data)
                _parserAthena.parse(
                    bytes: bytes,
                    timestamp: timestamp,
                    rxSequence: athenaRXSequence,
                    ingressDeltaMS: athenaIngressDeltaMS
                )
                //results are returned by delegate callbacks below
                return
            }
        
            //MARK: Legacy processing (Muse 1/2/S)
            var bytes:[UInt8] = [UInt8](_data) //move into an array
            
            let packetIndex:UInt16 = _parserLegacy.getPacketIndex(fromBytes: bytes) //remove and store package index
            bytes.removeFirst(2) //2 bytes is 1 UInt16 package index

            
            
            // local func to make EEG packet from the above variables
            
            func _makeEEGPacket(i:Int) -> MuseEEGPacket {
                
                //uncomment to store bytes for test data recording
                //and wire a key P command to fire off printEEGPPGSensorBytes() at the end
                //eegSensorBytes[i].append(bytes)
                
                //to see a single packet for testing
                //if (i == 2) { print(bytes, ",") }
                
                return MuseEEGPacket(
                    packetIndex: packetIndex,
                    sensor: i,
                    timestamp: timestamp,
                    samples: _parserLegacy.getEEGSamples(from: bytes))
            }
            
            // local func to make PPG packet from the above variables
            
            func _makePPGPacket(sensor: Int) -> MusePPGPacket {
                
                //uncomment to store bytes for test data recording
                //and wire a key P command to fire off printEEGPPGSensorBytes() at the end
                //ppgSensorBytes.append(bytes)
                
                //print off a single packet for testing
                //print(bytes, ",")
                
                return MusePPGPacket(
                    packetIndex: packetIndex,
                    sensor: sensor,
                    timestamp: timestamp,
                    samples: _parserLegacy.getPPGSamples(from: bytes))
            }
    
            //check the char ID and parse data based on it
           
            switch bluetoothCharacteristic.uuid {
                
            
                /*
                uint:12,uint:12,uint:12,uint:12,
                uint:12,uint:12,uint:12,uint:12,
                uint:12,uint:12,uint:12,uint:12"
                UInt12 x 12 time samples
                eeg order: tp10 af8 tp9 af7
                */
                
                //MARK: EEG
                //parse the incoming data through the parser, which includes FFT. Returned value is an FFTResult, which updates the MuseEEG object
            //packet order
            //0 TP10: right ear
            //1 AF08: right forehead
            //2 TP09: left ear
            //3 AF07: left forehead
            case MuseConstants.CHAR_TP10:
                 _eeg.update(withFFTResultSet: _fft.process(eegPacket: _makeEEGPacket(i: 0)))
            case MuseConstants.CHAR_AF8:
                 _eeg.update(withFFTResultSet: _fft.process(eegPacket: _makeEEGPacket(i: 1)))
            case MuseConstants.CHAR_TP9:
                 _eeg.update(withFFTResultSet: _fft.process(eegPacket: _makeEEGPacket(i: 2)))
            case MuseConstants.CHAR_AF7:
                 _eeg.update(withFFTResultSet: _fft.process(eegPacket: _makeEEGPacket(i: 3)))
                 
                 //only broadcast the MuseEEG object once per cycle, giving each sensor the chance to input its new sensor data
                 processAndPublishEEGData(from: convert(museEEG: _eeg))
                
                //MARK: PPG
            case MuseConstants.CHAR_PPG1, MuseConstants.CHAR_PPG2, MuseConstants.CHAR_PPG3:
            
                //PPG1 values ~ 87,000
                //PPG2 values ~ 280,000
                //PPG3 values ~ 0-100 but very erratic
                //Athena PPG averaged values ~7
                //PPG2 is what I usually use for Muse S
                //PPG3 works on Muse 2 as well
                //all PPGs now work on Muse S if preset is set to 51 on init
                
                /*
                 //https://mind-monitor.com/forums/viewtopic.php?f=19&t=1379
                 //https://developer.apple.com/documentation/accelerate/signal_extraction_from_noise
                uint:24,uint:24,uint:24
                uint:24,uint:24,uint:24
                UInt24 x 6 samples
                */
                
                //print(bytes) // <-- use to print out test PPG samples
                
                let ppgSensorIndex: Int
                switch bluetoothCharacteristic.uuid {
                case MuseConstants.CHAR_PPG1:
                    ppgSensorIndex = 0
                case MuseConstants.CHAR_PPG2:
                    ppgSensorIndex = 1
                case MuseConstants.CHAR_PPG3:
                    ppgSensorIndex = 2
                default:
                    ppgSensorIndex = 1
                }

                if let ppgResult:MusePPGResult = _ppg.update(
                    withPPGPacket: _makePPGPacket(sensor: ppgSensorIndex),
                    allowsHeartMetrics: heartGateNoisePct <= 35.0 && latestTensionPct < heartTensionThreshold,
                    allowsRespMetrics: heartGateNoisePct <= 35.0
                ) {
                    
                    //if streams are valid...
                    if let ppgStreams:MusePPGStreams = ppgResult.streams {
                        
                        //send blood flow and resp streams to parent
                        delegate?.didReceive(ppgStreams: convert(musePPGStreams: ppgStreams))
                    }
                    
                    //if heart event is valid...
                    if let ppgHeartEvent:MusePPGHeartEvent = ppgResult.heartEvent {
                        //send up to parent
                        //print("XvMuse: didReceive heart event", ppgHeartEvent.bpm, ppgHeartEvent.sdnn, ppgHeartEvent.pulseStrength)
                        delegate?.didReceive(ppgHeartEvent: convert(musePPGHeartEvent: ppgHeartEvent))
                    }
                }
                
            case MuseConstants.CHAR_ACCEL:
                
                //MARK: Accel
                /*
                 pattern = "int:16,int:16,int:16,int:16,int:16,int:16,int:16,int:16,int:16"
                 Int16 9 xyz samples (x,y,z,x,y,z,x,y,z)
                */
                
                _accelRaw = Bytes.constructInt16Array(fromUInt8Array: bytes, packetTotal: 9)
                
                let _accelPacket:XvAccelPacket = convert(
                    museAccelPacket: _accel.update(
                        withAccelPacket: MuseAccelPacket(
                            x: _parserLegacy.getXYZ(values: _accelRaw, start: 0),
                            y: _parserLegacy.getXYZ(values: _accelRaw, start: 1),
                            z: _parserLegacy.getXYZ(values: _accelRaw, start: 2)
                        )
                    )
                )
                delegate?.didReceive(accelPacket: _accelPacket)
                
                
            case MuseConstants.CHAR_BATTERY:
                
                //MARK: Battery
                /*
                 pattern = "uint:16,uint:16,uint:16,uint:16"
                 UInt16 battery / 512
                 UInt16 fuel gauge * 2.2
                 UInt16 adc volt
                 UInt16 temperature
                 //the rest is padding
                */
                
                _batteryRaw = Bytes.constructUInt16Array(fromUInt8Array: bytes, packetTotal: 4)
                
                //parse the percentage and send up to parent
                let primaryBatteryPercent = Int16(_batteryRaw[0] / MuseConstants.BATTERY_PCT_DIVIDEND)
                guard !shouldIgnorePrimaryBattery(primaryBatteryPercent) else { return }
                delegate?.didReceive(batteryPacket:
                    XvBatteryPacket(
                        percentage: primaryBatteryPercent
                    )
                )

            case MuseConstants.CHAR_CONTROL:
                
                //MARK: Control Commands
                //any calls to the headband cause a reply. With most its a "rc:0" response code = 0 (success)
                //getting device info or a control status send back JSON dictionaries with several vars
                //note: this package does not use packetIndex, so pass in the raw charactersitic value
                if let commandResponse: [String: Any] = _parserLegacy.parse(controlLine: bluetoothCharacteristic.value) {
                    
                    // Drop the rc field
                    var filtered = commandResponse
                    filtered.removeValue(forKey: "rc")
                    
                    // If nothing is left (i.e. it was just ["rc": 0]), ignore it
                    guard !filtered.isEmpty else {
                        return
                    }
                    
                    // Otherwise, broadcast the response
                    print("XvMuse: commandResponse:", filtered)
                    delegate?.didReceive(commandResponse: filtered)

                    /* Battery now comes from here on Athena firmware 3.1.29.

                     The old path was subpacket tag 0x98, which that firmware stopped sending —
                     it appears zero times across thousands of packets. The readings that used to
                     arrive on it were never real anyway: they came from a misaligned tag scan
                     finding the byte 0x98 inside raw sensor data, which is why they reported
                     139%, 178% and 255%.

                     "bp" in the control response is a genuine percentage, arrives on its own
                     schedule, and needs no reverse engineering. */
                    if let bp = batteryPercentage(fromCommandResponse: filtered) {
                        didPublishCommandResponseBatteryPacket(bp)
                        delegate?.didReceive(batteryPacket: XvBatteryPacket(percentage: bp))
                    }
                }
                
            default:
                //print("Unused UUID:", bluetoothCharacteristic.uuid)
                break
            }
            
        }
    }

    private static func athenaDiagnosticHex(_ data: Data, limit: Int) -> String {
        data.prefix(limit).map { String(format: "%02X", Int($0)) }.joined()
    }

    private static func athenaDiagnosticChecksum(_ data: Data) -> String {
        // FNV-1a is only a compact log fingerprint; it is not used for validation or parsing.
        var hash: UInt32 = 2_166_136_261
        for byte in data {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return String(format: "%08X", hash)
    }
    
    private func processAndPublishEEGData(from eegPacket: XvEEGPacket) {

        // === EEG publish-rate diagnostic === (history points/sec → chart smoothness)
        let now = Date().timeIntervalSince1970
        if _eegPublishWindowStart == 0.0 { _eegPublishWindowStart = now }
        _eegPublishCount += 1
        if now - _eegPublishWindowStart >= 1.0 {
            // print(String(format: "EEG RATE | %@ | %d publishes/sec", "\(deviceName ?? .unknown)", _eegPublishCount))
            _eegPublishCount = 0
            _eegPublishWindowStart = now
        }

        eeg.process(eegPacket: eegPacket)
        delegate?.didReceiveEEGPosition(
            deltaPan: eeg.position.panDelta,
            thetaPan: eeg.position.panTheta,
            alphaPan: eeg.position.panAlpha,
            betaPan: eeg.position.panBeta,
            gammaPan: eeg.position.panGamma,
            deltaX: eeg.position.delta.x,
            deltaY: eeg.position.delta.y,
            thetaX: eeg.position.theta.x,
            thetaY: eeg.position.theta.y,
            alphaX: eeg.position.alpha.x,
            alphaY: eeg.position.alpha.y,
            betaX: eeg.position.beta.x,
            betaY: eeg.position.beta.y,
            gammaX: eeg.position.gamma.x,
            gammaY: eeg.position.gamma.y
        )

        delegate?.didReceive(linearSpectrum: eeg.linearSpectrum)
        delegate?.didReceive(detailLinearSpectrum: eeg.detailLinearSpectrum)
        /* ML HEARTBEAT — must never be starved by the adaptive weights. The device average
         goes EMPTY when every pad is fully distrusted (all contact weights 0 — the ordinary
         headset-on-the-table case), and this call's callback is the sole writer of the
         per-sensor scores that could ever recover those weights. Feeding it the weighted
         average therefore created a permanent lockout: weights 0 -> empty average -> ML
         guard bails -> no callback -> weights stay 0 forever, surviving a re-seated headset.
         When the weighted average is empty, drive the cadence with any valid sensor's
         spectrum instead — the callback ignores the device-level score and judges each
         sensor individually, so the input only needs to exist, not be meaningful. */
        let mlDriveSpectrum = !eeg.linearSpectrum.isEmpty
            ? eeg.linearSpectrum
            : (eeg.sensors.first(where: { $0.hasValidSpectrum })?.linearSpectrum ?? [])
        _mlManager.process(linearSpectrum: mlDriveSpectrum)

        /* Signal quality is emitted from here rather than from the ML callback, because only one
         of its three parts comes from the model. Noise is the BEST enabled sensor's held score
         (adaptive weighting — only high when every pad is compromised); tension and blink are
         measured straight off the spectrum by XvEEGAnalysis, each against its own drifting
         resting level. Publishing all of it on the EEG cadence keeps the three in step.

         Tension and blink read the CONTACT-WEIGHTED device average across the sensors: a pad
         that has faded out for contact noise no longer fakes tension, while genuine muscle
         tension on any well-seated sensor still registers (brow spikes 20-35 Hz just as hard
         as jaw, so tension is never limited to one region). */
        latestTensionPct = eeg.analysis.tension
        latestBlinkPct = eeg.analysis.blink

        _stateAnalyzer.updateSignalQuality(
            clean: latestCleanPct,
            tension: latestTensionPct,
            blink: latestBlinkPct
        )

        delegate?.didReceiveML(
            noise: latestNoisePct,
            tension: latestTensionPct,
            blink: latestBlinkPct,
            clean: latestCleanPct
        )

        /* THE FRONTAL SPECTRUM: AF7 + AF8 only, averaged in parallel with the four-sensor
         broadband. Per Penijean — EEG in the front, EMG in the back. The temporals sit over jaw
         and neck muscle and are assumed to be contaminated for most wearers, so anything measuring
         brain state reads from the forehead pair while the artifact detectors keep the broadband.

         `eeg.front` is a plain cached lookup — XvEEG invalidates region caches once per packet in
         process(), so repeated reads within this cycle all hit the cache. The local is just for
         readability. */
        let frontal = eeg.front
        let frontalSpectrum = frontal.linearSpectrum

        /* The region drops sensors that have no valid spectrum, so if BOTH forehead pads are out
         it hands back an empty array — and an empty spectrum reads as theta 0 / quiet 0, which is
         a plausible-looking number rather than an obvious failure. Freezing the state values is
         the honest response: there is no frontal EEG this frame, and the onboarding screens that
         show these states already hide themselves on forehead noise.

         Everything derived from the broadband — signal quality, tension, blink, the brainwave
         history — is published above and below regardless, since it is unaffected. */
        if !frontalSpectrum.isEmpty {
            delegate?.didReceive(frontLinearSpectrum: frontalSpectrum)

            //Quiet: absolute low activity across the bandwidth, now frontal-only
            let rawQuiet = frontal.analysis.quiet
            let quiet = gatedQuiet(fromRawQuiet: rawQuiet, levelDb: frontal.analysis.quietLevelDb)
            delegate?.didReceiveQuiet(quiet)

            /* Focus and meditation are measured from the clean detail-window shape. Alpha/beta use
             the detail-window bands, which are already forehead-only (DETAIL_EEG_SENSOR_IDS). Theta
             and quiet now come from the frontal region for the same reason; delta and gamma stay
             broadband because they serve as artifact context rather than as states themselves. */
            _stateAnalyzer.updateBands(
                delta: eeg.delta.decibel,
                theta: frontal.theta.decibel,
                alpha: eeg.detailAlpha.decibel,
                beta: eeg.detailBeta.decibel,
                gamma: eeg.gamma.decibel,
                //raw, not gated — the gated value already carries tension damping, which dreamy
                //applies separately, and double-counting it would suppress dreamy twice over
                quiet: frontal.analysis.quiet,
                quietDb: frontal.analysis.quietLevelDb
            )

            /* Ear pair (TP9+TP10) — now feeds meditation's alpha gate, routed by ear
             confidence (see EEGStateAnalyzer.updateEarBands). The level gap between the ear and
             forehead pairs is the contact-quality evidence: hair over an ear pad reads far
             hotter or far deader than the forehead ever does. When the sides region hands back
             no spectrum (ear sensors off in the UI, or both pads invalid), confidence collapses
             and the gate falls back to the forehead pair automatically. */
            let sides = eeg.sides
            if !sides.linearSpectrum.isEmpty {
                /* Ear trust uses the SAME per-sensor noise scores that drive the weights and
                 the interface's sensor symbols — one noise system, one opinion, everywhere
                 (now read from the held per-sensor values instead of re-running the model
                 here). Each valid ear judged separately and the worse one rules: even with
                 contact-weighted averaging, a partially-degraded pad still colors the sides
                 spectrum the alpha is measured from. An ear disabled in the UI isn't judged. */
                /* Only ears still CONTRIBUTING to the sides average get a vote: on the
                 25-60 partial ramp a degraded pad both colors the average and lowers trust
                 (consistent), but at >=60 it contributes nothing — letting it keep vetoing
                 would defeat the whole "one clean ear keeps meditation alive" behavior. */
                var earNoises: [Double] = []
                if eeg.TP9.hasValidSpectrum && heldSensorNoise[0] < sensorWeightNoiseFull {
                    earNoises.append(heldSensorNoise[0])
                }
                if eeg.TP10.hasValidSpectrum && heldSensorNoise[3] < sensorWeightNoiseFull {
                    earNoises.append(heldSensorNoise[3])
                }
                _stateAnalyzer.updateEarBands(
                    delta: sides.delta.decibel,
                    theta: sides.theta.decibel,
                    alpha: sides.alpha.decibel,
                    beta: sides.beta.decibel,
                    gamma: sides.gamma.decibel,
                    noisePct: earNoises.max() ?? 100.0
                )
            } else {
                _stateAnalyzer.earBandsUnavailable()
            }

            /* Theta PROMINENCE has to read the same spectrum theta's amplitude came from, or dreamy
             would score its size from the forehead and its shape from the whole head. */
            _stateAnalyzer.processFrontalSpectrum(frontalSpectrum)
        }

        //the dominant-rhythm tracker stays on the broadband, where it was tuned
        _stateAnalyzer.processFullSpectrum(eeg.linearSpectrum)
        _stateAnalyzer.processDetailSpectrum(eeg.detailLinearSpectrum)

        publishGammaFocus(gammaDb: eeg.gamma.decibel)
        delegate?.didReceiveBrainwave(
            delta: eeg.delta.decibel,
            theta: eeg.theta.decibel,
            alpha: eeg.alpha.decibel,
            beta: eeg.beta.decibel,
            gamma: eeg.gamma.decibel
        )
        
        if let faa = eeg.faa {
            delegate?.didReceive(faa: faa)
        }
        
        delegate?.didReceiveBrainwaveHistory(
            deltaHistory: eeg.delta.history.decibels,
            thetaHistory: eeg.theta.history.decibels,
            alphaHistory: eeg.alpha.history.decibels,
            betaHistory: eeg.beta.history.decibels,
            gammaHistory: eeg.gamma.history.decibels
        )
    }

    func fftManagerDidUpdateBufferProgress(samples:Int, total:Int) {
        let safeTotal = max(total, 1)
        let progress = min(1.0, max(0.0, Double(samples) / Double(safeTotal)))

        delegate?.didReceiveEEGBufferProgress(
            samples: min(samples, safeTotal),
            total: safeTotal,
            progress: progress
        )
    }

    /* SIGNAL QUALITY RELEASE — bad news instantly, good news slowly.

     Taking the headset off drives noise straight up, correctly. But a headset lying on a table
     picks up ambient electromagnetic interference that intermittently LOOKS like clean EEG, so the
     raw value dips for a second or two before the noise returns. Every one of those dips reads
     downstream as "the signal is fine again" — notes resume, gates reopen, and the music plays to
     an empty room.

     So noise can rise instantly but only falls with a 5 s time constant, and clean is the mirror
     image: it can fall instantly but only rises over 5 s. Both express the same rule — a problem
     is believed the moment it appears, a recovery has to be sustained before it is trusted.

     Sized against the tightest consumer of these numbers, the note gate at noise >= 35: coming
     down from a headset-off reading of 100, that threshold is not crossed until about 5.3 s of
     continuously clean signal, so no realistic interference dip can restart the music. Both are
     held HERE, at the source, so the note gate, the heart/resp gates, the quiet cap, the state
     analyzer and the UI all agree on one number.

     dt is capped at 1 s so that returning from the background releases by at most one second's
     worth rather than a whole gap — erring toward keeping noise high, which is the safe side. */
    /* ADAPTIVE SENSOR WEIGHTING (Sep 2026). Every ML cycle each sensor is judged by the same
     contact-noise model — no longer only when the device average looks bad, because the whole
     point is to know which pads to LEAN ON, not just which to blame. Three outputs:

     1. Per-sensor held noise: rises instantly, releases over ~5 s (same asymmetry the old
        device-level hold had) so weights don't flicker with the raw 0-100 model output.
        A sensor with no valid spectrum reads 100 (worst) — no data is NOT clean data. (The old
        code reported 0 for a dead pad, which painted a disconnected sensor as perfect.)
     2. Contact weights into XvEEG (1.0 clean, fading to 0.0 over the 25-60 noise ramp — the
        same ramp ear trust uses): every region/device average fades a failing pad out
        proportionally while the clean sensors carry the signal.
     3. Device noise/clean = the BEST enabled sensor's noise. Noise only reads high when every
        sensor is compromised; one flaky pad no longer pushes the noise output or trips the
        global gates while three good sensors are still delivering. */
    private var heldSensorNoise: [Double] = [0.0, 0.0, 0.0, 0.0]  //TP9, AF7, AF8, TP10
    private var heartGateNoisePct: Double = 0.0  //best FOREHEAD pad — gates the PPG, which sits on the forehead
    private var lastSensorNoiseTime: TimeInterval?
    private let signalQualityReleaseSeconds: Double = 5.0
    private let sensorWeightNoiseOnset: Double = 25.0  //full weight at or below this noise
    private let sensorWeightNoiseFull: Double = 60.0   //zero weight at or above this noise

    func didReceiveMLNoise(noise: Double, clean: Double) {
        //independent per-sensor judgment, so "all loose / headset off" reads all high
        func sensorNoise(_ sensor: XvEEGSensor) -> Double {
            guard sensor.hasValidSpectrum,
                  let p = _mlManager.noiseProbability(forSpectrum: sensor.linearSpectrum) else {
                return 100.0
            }
            return p
        }
        let rawByIndex = [
            sensorNoise(eeg.TP9),
            sensorNoise(eeg.AF7),
            sensorNoise(eeg.AF8),
            sensorNoise(eeg.TP10)
        ]

        //asymmetric hold: up instantly, down over ~5 s; dt capped so backgrounding can't leap it
        let now = Date().timeIntervalSinceReferenceDate
        var alpha = 1.0
        if let last = lastSensorNoiseTime {
            let dt = min(max(now - last, 0.0), 1.0)
            alpha = 1 - exp(-dt / signalQualityReleaseSeconds)
        }
        lastSensorNoiseTime = now
        for index in 0..<heldSensorNoise.count {
            let raw = rawByIndex[index]
            heldSensorNoise[index] = raw >= heldSensorNoise[index]
                ? raw
                : heldSensorNoise[index] + alpha * (raw - heldSensorNoise[index])
        }

        //weights into the averaging layer, config order TP9, AF7, AF8, TP10
        let ramp = sensorWeightNoiseFull - sensorWeightNoiseOnset
        eeg.setSensorContactWeights(heldSensorNoise.map { held in
            1.0 - min(max((held - sensorWeightNoiseOnset) / ramp, 0.0), 1.0)
        })

        //device quality = best enabled sensor; clean is its mirror (the model defines clean = 100 - noise)
        let sensorsByIndex = [eeg.TP9, eeg.AF7, eeg.AF8, eeg.TP10]
        let bestNoise = sensorsByIndex.enumerated()
            .filter { $0.element.isEnabled }
            .map { heldSensorNoise[$0.offset] }
            .min() ?? 100.0
        latestNoisePct = min(max(bestNoise, 0.0), 100.0)
        latestCleanPct = 100.0 - latestNoisePct

        /* The PPG is a FOREHEAD optical sensor: both forehead EEG pads noisy is strong
         evidence the band is loose exactly where the PPG needs skin contact, even when an
         ear pad is pristine. Heart/resp gating therefore keys on the best FOREHEAD pad,
         not the best pad anywhere on the head. */
        heartGateNoisePct = min(heldSensorNoise[1], heldSensorNoise[2])

        /* Held per-sensor values published every cycle — the UI arcs now always show real
         scores. A USER-disabled sensor publishes 0 (the legacy "not judged" convention):
         the headset-fit views read this feed as "does this pad need fixing", and a pad the
         wearer deliberately turned off must not block their ready checks or raise fix-it
         tips forever. Internally its held value stays 100 so weights, the best-sensor min
         (which filters isEnabled anyway) and the ear votes all treat it as absent. */
        func published(_ index: Int, _ sensor: XvEEGSensor) -> Double {
            sensor.isEnabled ? heldSensorNoise[index] : 0.0
        }
        delegate?.didReceiveSensorNoise(
            tp9: published(0, eeg.TP9),
            af7: published(1, eeg.AF7),
            af8: published(2, eeg.AF8),
            tp10: published(3, eeg.TP10)
        )

        logSensorWeightsIfDue()
    }

    ///Adaptive-weighting log, ~every 5 s. ON for the adaptive test round — set false when done.
    private static let logSensorWeights = true
    private var lastSensorWeightLogTime: TimeInterval = 0

    private func logSensorWeightsIfDue() {
        guard Self.logSensorWeights else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastSensorWeightLogTime >= 5.0 else { return }
        lastSensorWeightLogTime = now

        let ramp = sensorWeightNoiseFull - sensorWeightNoiseOnset
        func entry(_ label: String, _ index: Int) -> String {
            let weight = 1.0 - min(max((heldSensorNoise[index] - sensorWeightNoiseOnset) / ramp, 0.0), 1.0)
            return String(format: "%@ %3.0f w%.2f", label, heldSensorNoise[index], weight)
        }
        print("SENSORS | \(entry("TP9", 0)) | \(entry("AF7", 1)) | \(entry("AF8", 2)) | \(entry("TP10", 3)) | best noise \(Int(latestNoisePct.rounded()))")
    }

    /* "bp" is a FALLBACK, not a second source.

     Muse 2 and S report battery on CHAR_BATTERY; Athena on older firmware reports it as subpacket
     0x98. Both still work, and CHAR_CONTROL is shared by every model — so publishing "bp"
     unconditionally would give those devices two battery feeds that could disagree and flicker.

     Publish "bp" whenever it appears. Muse S/2 can send a real "bp" in the command response while
     the notify battery characteristic decodes to 0, so a strict primary/fallback split lets a bad
     primary value win. A recent nonzero "bp" also blocks primary zero packets from overwriting it. */
    private var lastCommandResponseBatteryTime: Date? = nil
    private var lastCommandResponseBatteryPercent: Int16? = nil
    private let commandResponseBatteryGuardSeconds: TimeInterval = 60.0

    private func didPublishCommandResponseBatteryPacket(_ percent: Int16) {
        lastCommandResponseBatteryTime = Date()
        lastCommandResponseBatteryPercent = percent
    }

    private func shouldIgnorePrimaryBattery(_ percent: Int16) -> Bool {
        guard percent == 0,
              let commandPercent = lastCommandResponseBatteryPercent,
              commandPercent > 0,
              let lastCommandTime = lastCommandResponseBatteryTime else {
            return false
        }

        return Date().timeIntervalSince(lastCommandTime) <= commandResponseBatteryGuardSeconds
    }

    private func resetBatteryStateForConnection() {
        lastCommandResponseBatteryTime = nil
        lastCommandResponseBatteryPercent = nil
    }

    /* Pull "bp" out of a control response. Arrives as a Double (94.44) but has also been seen as
     Int and as a String, so all three are accepted. Values outside 0-100 are rejected rather than
     clamped — a percentage that far off means the field was misread, and reporting nothing beats
     reporting a wrong number. */
    private func batteryPercentage(fromCommandResponse response: [String: Any]) -> Int16? {

        guard let raw = response["bp"] else { return nil }

        let value: Double
        switch raw {
        case let d as Double: value = d
        case let i as Int:    value = Double(i)
        case let s as String: guard let d = Double(s) else { return nil }; value = d
        default: return nil
        }

        guard value >= 0, value <= 100 else { return nil }
        return Int16(value.rounded())
    }

    /* QUIET DIAGNOSTIC — the analyzer logs the scored states; quiet's gating and smoothing live
     here, so its log does too. One line per second, one summary per 10 s window with the share of
     frames each gate actually fired, matching the state summaries' cadence. */
    private var _quietLogTime: TimeInterval = 0
    private var _quietWindowStart: TimeInterval = 0
    private var _quietRawSamples: [Double] = []
    private var _quietPubSamples: [Double] = []
    private var _quietFadedFrames: Int = 0
    private var _quietCappedFrames: Int = 0

    ///quiet logging. Off — flip on when re-tuning the quiet anchors.
    private static let logQuietLines = false
    private var _quietDbSamples: [Double] = []

    private func logQuiet(
        raw: Double,
        published: Double,
        levelDb: Double,
        faded: Bool,
        capped: Bool,
        tensionDamp: Double,
        blinkDamp: Double,
        gammaDamp: Double
    ) {
        guard Self.logQuietLines else { return }
        let now = Date().timeIntervalSince1970

        if _quietWindowStart == 0 { _quietWindowStart = now }
        _quietRawSamples.append(raw)
        _quietPubSamples.append(published)
        _quietDbSamples.append(levelDb)
        if faded { _quietFadedFrames += 1 }
        if capped { _quietCappedFrames += 1 }

        if now - _quietLogTime >= 1.0 {
            _quietLogTime = now
            /* level is the ONE number quiet measures: trimmed-mean loudness of the 2-47 Hz
             frontal spectrum, in dB. The anchors map it to the score: level <= quietDb reads
             100, level >= loudDb reads 0. damp shows the facial-stress multipliers
             (tension/blink/gamma, x1.00 = no damping); the rest of the line is gates. */
            let cal = XvEEGAnalysis.quietCalibration
            print(String(
                format: "QUIET  %3.0f (raw %3.0f) | level %+5.1fdB (anchors %+4.1f..%+4.1f) | damp t%.2f b%.2f g%.2f%@%@ | tension %3.0f blink %3.0f clean %3.0f noise %3.0f",
                published, raw,
                levelDb, cal.quietDb, cal.loudDb,
                tensionDamp, blinkDamp, gammaDamp,
                faded ? " FADED (clean<60 or tension>60)" : "",
                capped ? " CAPPED (noise>70)" : "",
                latestTensionPct, latestBlinkPct, latestCleanPct, latestNoisePct
            ))
        }

        if now - _quietWindowStart >= 10.0 {
            let count = Double(max(_quietRawSamples.count, 1))
            let sortedRaw = _quietRawSamples.sorted()
            let sortedPub = _quietPubSamples.sorted()
            func pct(_ sorted: [Double], _ p: Double) -> Double {
                sorted.isEmpty ? 0 : sorted[min(Int((Double(sorted.count - 1) * p).rounded()), sorted.count - 1)]
            }
            //the dB distribution is the tuning payload: set quietDb near a settled state's p10
            //and loudDb near an active state's p90, and the score will separate the two
            let sortedDb = _quietDbSamples.sorted()
            print(String(
                format: "QUIET SUMMARY  | frames %3d | level dB med %+5.1f p10 %+5.1f p90 %+5.1f | raw med %3.0f p10 %3.0f p90 %3.0f | published med %3.0f p10 %3.0f p90 %3.0f | faded %2.0f%% capped %2.0f%%",
                _quietRawSamples.count,
                pct(sortedDb, 0.5), pct(sortedDb, 0.1), pct(sortedDb, 0.9),
                pct(sortedRaw, 0.5), pct(sortedRaw, 0.1), pct(sortedRaw, 0.9),
                pct(sortedPub, 0.5), pct(sortedPub, 0.1), pct(sortedPub, 0.9),
                Double(_quietFadedFrames) / count * 100.0,
                Double(_quietCappedFrames) / count * 100.0
            ))
            _quietWindowStart = now
            _quietRawSamples.removeAll(keepingCapacity: true)
            _quietPubSamples.removeAll(keepingCapacity: true)
            _quietDbSamples.removeAll(keepingCapacity: true)
            _quietFadedFrames = 0
            _quietCappedFrames = 0
        }
    }

    /* GAMMA FOCUS — the positive reading of the same evidence dreamy uses as a veto.

     High broadband gamma with a relaxed face is fast cortical activity: hard engagement, the
     coding-style concentration that the labeled corpus showed at gamma median +4.1 dB while every
     restful state sat at or below +1.3. Published as its own 0-100 state so it can be sonified
     independently of the detail-window focus score; the two will often overlap, by design.

     THE TENSION GATE IS NOT OPTIONAL. The tension EMG band (20-35 Hz) and the gamma band
     (31-44 Hz) physically overlap, so a jaw clench floods this measure with muscle, not brain.
     Tension therefore fades the score toward zero from 30% and fully by 70% — same shape as the
     RelaxedStateGate but with no floor, because a fake gamma reading has no display value.

     Anchors (1.5..4.5 dB) were measured on the Muse 2 corpus. Gamma on the Athena runs about
     2.2 dB lower at rest (-3.9 median vs the Muse 2's -1.7), so device identification installs
     per-device anchors — see deviceStateTuningDefaults, same arrangement as quiet's. */
    //MARK: - Runtime state tuning API

    /* Live tuning for the state-detection pipeline. Keys, defaults and ranges are declared in
     XvEEGStateTuningParameter.all (bottom of this file) — the app's tuning panel renders itself
     from that list. Routing:
       gamma.*                       -> the gammaFocus mapping below
       quiet.*                       -> XvEEGAnalysis.quietCalibration (override survives device re-identification)
       gates.* / med.* / focus.* / dreamy.* -> EEGStateAnalyzer / EEGStateScorer */
    public func setStateTuning(key: String, value: Double) {
        guard value.isFinite else { return }
        switch key {
        case "gamma.lowDb": gammaFocusLowDb = value
        case "gamma.highDb": gammaFocusHighDb = value
        case "gamma.smoothing": gammaFocusSmoothing = value
        case "gamma.tensionGateOnset": gammaTensionGateOnset = value
        case "gamma.tensionGateFull": gammaTensionGateFull = value
        case "quiet.quietDb": quietDbOverride = value; refreshQuietCalibration()
        case "quiet.loudDb": loudDbOverride = value; refreshQuietCalibration()
        default: _stateAnalyzer.setTuning(key: key, value: value)
        }
    }

    /* Performer's manual heart-rate offset, in BPM. Set from the diagnostic UI's OFF +/- control.

     Applied inside the PPG analyzer so beat strength sees it too; the app adds the same offset to
     the BPM number it publishes downstream. Unlike the measured rate, the offset is never capped —
     it exists precisely to reach output levels a resting heart will not produce on stage. */
    public func set(heartRateOffsetBPM: Double) {
        guard heartRateOffsetBPM.isFinite else { return }
        _ppg.set(heartRateOffsetBPM: heartRateOffsetBPM)
        _testPPG.set(heartRateOffsetBPM: heartRateOffsetBPM)
    }

    /* HR-corrected HRV master curve (the wearer's personal RMSSD-vs-heart-rate baseline).
     The curve improves the longer it accumulates, so the app should snapshot it periodically
     and restore it at launch — restore REPLACES the in-memory curve, so do it before the
     session generates beats. The snapshot is 40 doubles (20 bin values + 20 counts). */
    public func hrvMasterCurveSnapshot() -> [Double] {
        return _ppg.hrvMasterCurveSnapshot()
    }

    public func restoreHRVMasterCurve(_ snapshot: [Double]) {
        _ppg.restoreHRVMasterCurve(snapshot)
    }

    /* Return one parameter to its code default. For most keys the descriptor default IS the
     code default, so a plain set suffices — but the quiet anchors are PER-DEVICE (muse2 -0.5/2.5,
     museS -0.5/2.5, athena -5.5/-1.5), so resetting them must CLEAR the user override and restore
     the identified device's own calibration, not install the descriptor (muse2) numbers. */
    public func resetStateTuning(key: String) {
        switch key {
        case "quiet.quietDb":
            quietDbOverride = nil
            refreshQuietCalibration()
        case "quiet.loudDb":
            loudDbOverride = nil
            refreshQuietCalibration()
        default:
            /* Device-calibrated keys reset to the IDENTIFIED device's default, not the
             descriptor's (which carries the Muse 2 corpus numbers) — same rule as quiet. */
            if let deviceDefault = deviceStateTuningDefaults[key] {
                setStateTuning(key: key, value: deviceDefault)
            } else if let param = XvEEGStateTuningParameter.all.first(where: { $0.key == key }) {
                setStateTuning(key: key, value: param.defaultValue)
            }
        }
    }

    /* Per-component user overrides of the quiet calibration anchors. Held separately from the
     device default so (a) the device-identification sites don't stomp a user's live tuning if
     the device re-identifies mid-session, and (b) resetting one component restores THAT device's
     default for it while keeping the other component's override. */
    private var quietDbOverride: Double?
    private var loudDbOverride: Double?
    private var deviceDefaultQuietCalibration: XvEEGAnalysis.QuietCalibration = .legacy

    private func refreshQuietCalibration() {
        XvEEGAnalysis.quietCalibration = XvEEGAnalysis.QuietCalibration(
            quietDb: quietDbOverride ?? deviceDefaultQuietCalibration.quietDb,
            loudDb: loudDbOverride ?? deviceDefaultQuietCalibration.loudDb
        )
    }

    private func applyQuietCalibration(deviceDefault: XvEEGAnalysis.QuietCalibration) {
        deviceDefaultQuietCalibration = deviceDefault
        refreshQuietCalibration()
    }

    /* PER-DEVICE STATE-DETECTION DEFAULTS — the anchors that read RAW dB, which is the one
     scale the headsets disagree on. The detrended residual measures (meditation, focus shape,
     dreamy's theta lead) self-normalize and need none of this.

     Measured 14-15 Sep 2026, same-brain A/B/C sessions (one wearer, all three headsets back
     to back). Front gamma beds: Athena ~2 dB below the Muse 2 (session medians -0.2 vs +1.8;
     corpus rest -3.9 vs -1.7), the Muse S ~1.5 dB ABOVE it (+3.2) — the S is the hottest of
     the three, not the middle, and on inherited Muse 2 anchors its dreamy detector sat at
     LIMIT calmGamma in ~85% of windows. Athena 8-20 Hz detail power runs about half a log10
     unit low; the S's is close enough to the Muse 2's to share anchors.

     Applied through setStateTuning at identification so the tuning panel shows the live
     values; resetStateTuning restores the identified device's entry from this table. A swap
     to another headset mid-session re-applies that device's defaults, which also overwrites
     any live tuning of these keys — accepted: a headset change invalidates those tweaks anyway. */
    private static let baseStateTuningDefaults: [String: Double] = [
        "gamma.lowDb": 1.5, "gamma.highDb": 4.5,
        "dreamy.gammaLowDb": 2.0, "dreamy.gammaHighDb": 4.0,
        "gates.intensityLowLogPower": 0.0, "gates.intensityHighLogPower": 3.0,
    ]
    private static let athenaStateTuningDefaults: [String: Double] = [
        "gamma.lowDb": -0.7, "gamma.highDb": 2.3,
        "dreamy.gammaLowDb": -0.2, "dreamy.gammaHighDb": 1.8,
        "gates.intensityLowLogPower": -0.5, "gates.intensityHighLogPower": 2.5,
    ]
    private static let museSStateTuningDefaults: [String: Double] = [
        "gamma.lowDb": 3.0, "gamma.highDb": 6.0,
        "dreamy.gammaLowDb": 3.5, "dreamy.gammaHighDb": 5.5,
        "gates.intensityLowLogPower": 0.0, "gates.intensityHighLogPower": 3.0,
    ]
    private var deviceStateTuningDefaults: [String: Double] = [:]

    private func applyStateCalibration(deviceDefaults: [String: Double]) {
        deviceStateTuningDefaults = deviceDefaults
        for (key, value) in deviceDefaults {
            setStateTuning(key: key, value: value)
        }
    }

    private var latestPublishedGammaPct: Double = 0.0
    //runtime-tunable via setStateTuning ("gamma.*" keys)
    private var gammaFocusSmoothing: Double = 0.10
    private var gammaFocusLowDb: Double = 1.5
    private var gammaFocusHighDb: Double = 4.5
    private var gammaTensionGateOnset: Double = 30.0
    private var gammaTensionGateFull: Double = 70.0

    private func publishGammaFocus(gammaDb: Double) {
        guard gammaDb.isFinite else { return }

        let span = max(gammaFocusHighDb - gammaFocusLowDb, 1e-6)
        let raw = min(max((gammaDb - gammaFocusLowDb) / span, 0.0), 1.0)

        let tensionGateSpan = max(gammaTensionGateFull - gammaTensionGateOnset, 1e-6)
        let tensionAmount = min(max((latestTensionPct - gammaTensionGateOnset) / tensionGateSpan, 0.0), 1.0)
        let target = raw * (1.0 - tensionAmount) * 100.0

        latestPublishedGammaPct += gammaFocusSmoothing * (target - latestPublishedGammaPct)
        delegate?.didReceiveGammaFocus(min(max(latestPublishedGammaPct, 0.0), 100.0))
    }

    /* Facial-stress damping ramps for quiet (Sep 2026, by request): tension, blinking, and
     gamma are all face/arousal evidence, and a face under load is not a quiet mind even when
     the broadband dB happens to read low. Each factor scales quiet from x1.0 at its onset to
     x0.0 at full; the three multiply, so any one of them can take quiet out alone.

     Yes, tension partly double-counts (a clench also raises the 20-35 Hz stretch of the level
     measure) — that is now deliberate: quiet should be the hardest state to earn, and facial
     stress should kill it from both directions. Blink damping is safe again because the
     published value is smoothed over seconds, so a single blink barely dents it — only
     SUSTAINED eye activity pulls quiet down. Gamma uses the published gammaFocus score, which
     is per-device anchored and already smoothed. */
    private let quietTensionDampOnset: Double = 20.0
    private let quietTensionDampFull: Double = 60.0
    private let quietBlinkDampOnset: Double = 30.0
    private let quietBlinkDampFull: Double = 80.0
    private let quietGammaDampOnset: Double = 30.0
    private let quietGammaDampFull: Double = 80.0

    private func stressDamp(_ value: Double, onset: Double, full: Double) -> Double {
        guard full > onset else { return value >= full ? 0.0 : 1.0 }
        return 1.0 - min(max((value - onset) / (full - onset), 0.0), 1.0)
    }

    private func gatedQuiet(fromRawQuiet rawQuiet: Double, levelDb: Double) -> Double {
        var quiet = rawQuiet

        //an unusable signal can't be called quiet, whatever the numbers say
        let faded = shouldFadeCleanStateValues
        let capped = !faded && latestNoisePct > 70.0
        if faded {
            quiet = 0.0
        } else if capped {
            quiet = min(quiet, 30.0)
        }

        //facial stress is not a quiet mind — see the damping comment above
        let tensionDamp = stressDamp(latestTensionPct, onset: quietTensionDampOnset, full: quietTensionDampFull)
        let blinkDamp = stressDamp(latestBlinkPct, onset: quietBlinkDampOnset, full: quietBlinkDampFull)
        let gammaDamp = stressDamp(latestPublishedGammaPct, onset: quietGammaDampOnset, full: quietGammaDampFull)
        quiet *= tensionDamp * blinkDamp * gammaDamp

        let target = min(max(quiet, 0.0), 100.0)
        let smoothing = target < latestPublishedQuietPct ? quietFallSmoothing : quietRecoverSmoothing
        latestPublishedQuietPct = (smoothing * target) + ((1.0 - smoothing) * latestPublishedQuietPct)
        let published = min(max(latestPublishedQuietPct, 0.0), 100.0)

        logQuiet(
            raw: rawQuiet,
            published: published,
            levelDb: levelDb,
            faded: faded,
            capped: capped,
            tensionDamp: tensionDamp,
            blinkDamp: blinkDamp,
            gammaDamp: gammaDamp
        )
        return published
    }

    /* What is allowed to disqualify a quiet reading. Used only by gatedQuiet.

     BLINK NO LONGER COUNTS. A blink is a sub-second transient, but this gate slams quiet to zero
     outright, and blink crosses its threshold constantly during ordinary wear — so a value meant
     to describe a settled mind was being knocked flat several times a minute by nothing more than
     normal eye movement. Quiet is a wideband loudness average; a blink barely moves it. Screening
     the frame out was doing far more damage to the reading than the artifact ever did.

     Muscle tension stays, because a clench genuinely does fill the band being measured, and poor
     signal quality stays because an unusable signal cannot be called quiet whatever it reads. */
    private var shouldFadeCleanStateValues: Bool {
        latestCleanPct < 60.0 ||
        latestTensionPct > 60.0
    }

    func didReceiveBrainwaveState(meditation: Double, focus: Double, dreamy: Double) {
        delegate?.didReceiveBrainwaveState(meditation: meditation, focus: focus, dreamy: dreamy)
    }

    func didReceiveBrainwaveDimensions(tiltHz: Double, steadiness: Double, intensity: Double, spreadHz: Double, confidence: Double, rhythmHz: Double, rhythmSlowHz: Double) {
        delegate?.didReceiveBrainwaveDimensions(
            tiltHz: tiltHz,
            steadiness: steadiness,
            intensity: intensity,
            spreadHz: spreadHz,
            confidence: confidence,
            rhythmHz: rhythmHz,
            rhythmSlowHz: rhythmSlowHz
        )
    }

    func didReceiveStateTuningReadout(_ readout: [String: Double]) {
        delegate?.didReceiveStateTuningReadout(readout)
    }

    public func didReceiveEEGNoteTrigger(_ trigger: XvEEGNoteTrigger) {
        delegate?.didReceiveEEGNoteTrigger(trigger)
    }
    
    //MARK: - Athena
    //packets received from Athena and passed up to the parent app
    func didReceiveAthenaEEGBuffer(
        packetIndex:UInt8,
        timestamp:TimeInterval,
        sensor: Int,
        samples: [Float]
    ) {
        guard !samples.isEmpty else {
            print("XvMuse: Error: Athena EEG buffer is empty")
            return
        }

        let eegPacket = MuseEEGPacket(
            packetIndex: UInt16(packetIndex),
            sensor: sensor,
            timestamp: timestamp,
            samples: samples.map { Double($0) }
        )

        _eeg.update(withFFTResultSet: _fft.process(eegPacket: eegPacket))

        // AF7 is the final sensor in the legacy publish cycle.
        if sensor == 3 {
            processAndPublishEEGData(from: convert(museEEG: _eeg))
        }
    }
    
    //Athena parser creates and sends a Muse PPG packet
    //includes the sensor num, timestamp, and with a single sample or array of samples
    func didReceiveAthena(ppgPacket: MusePPGPacket) {

        // Feed Athena PPG packet into MusePPG processor to detect blood flow, resp, and heart beats
        if let ppgResult:MusePPGResult = _ppg.update(
            withPPGPacket: ppgPacket,
            allowsHeartMetrics: heartGateNoisePct <= 35.0 && latestTensionPct < heartTensionThreshold,
            allowsRespMetrics: heartGateNoisePct <= 35.0
        ) {
            
            //if streams are valid...
            if let ppgStreams:MusePPGStreams = ppgResult.streams {

                //send blood flow and resp streams to parent
                delegate?.didReceive(ppgStreams: convert( musePPGStreams: ppgStreams))
            }
            
            //if heart event is valid...
            if let ppgHeartEvent:MusePPGHeartEvent = ppgResult.heartEvent {
                //send up to parent
                //print("XvMuse: Athena heart event: BPM;", ppgHeartEvent.bpm, "Str:", ppgHeartEvent.pulseStrength, "HRV SDNN", ppgHeartEvent.sdnn )
                delegate?.didReceive(ppgHeartEvent: convert(musePPGHeartEvent: ppgHeartEvent))
            }
        }
    }
    
    func didReceiveAthena(accelPacket: MuseAccelPacket) {
        //receive muse accel, convert to xvaccel, and send to parent
        let _accelPacket = convert(museAccelPacket: _accel.update(withAccelPacket: accelPacket))
        delegate?.didReceive(accelPacket: _accelPacket)
    }
    
    func didReceiveAthena(batteryPacket: XvBatteryPacket) {
        delegate?.didReceive(batteryPacket: batteryPacket)
    }

    
    //MARK: - Test Data
    //only engage test data objects when called directly from external program
    private let _testEEGData:[TestEEGData] = [
        
        //ACTIVE SETS
        
        //NOISE
        TestEEGNoiseData(name: "Noise"),
//        TestEEGLooseFitData(name:"Loose"),
        TestEEGStressData(name: "Stress"),
//        TestEEGJawData(name: "Jaw"),
//        TestEEGForeheadData(name: "Forehead"),
//        TestEEGBlinksData(name: "Blinks"),
//        
        
        TestEEGCodingData(name:"Coding"),
        TestEEGRestingFocusData(name: "Resting Focus"),
//
//        TestEEGGammaBurstData(name: "Gamma Bursts")
        
//        TestEEGHoldingBreathData(name: "Holding Breath"), //active
        TestEEGClearMindData(name:"Clear Mind"), //active
//        TestEEGEyesClosedData(name: "Eyes Closed"), //not active
        TestEEGMeditationData(name: "Meditation"), //active
        TestEEGTiredData(name: "Tired"), //active
        TestEEGFallingAlseepData(name: "Falling Asleep"),
//        TestEEGSleepingData(name: "Sleeping"),
        
        // WARNING - large, deactivated sets
        //these files are too large for file indexing
        //commented these out inside of each file unless needed, one at a time
//        TestEEGReadingNewsData(name: "Reading News"),
//        TestEEGSocialMediaData(name:"Social Media"),
        //TestEEGTypingEmailData(name: "Typing Emails"),
        
        //TestEEGArousalData(name: "Arousal"),
        //TestEEGCoffeeData(name: "Coffee"),
        
    ]
    private let _testPPGData:[TestPPGData] = [
   //     TestPPGNoiseData(),
//        TestPPGLooseFitData(),
 //       TestPPGStressData(),
        TestPPGMeditationData(),
        TestPPGMeditationData(),
        TestPPGMeditationData(),
        TestPPGMeditationData(),
        TestPPGMeditationData(),
        TestPPGMeditationData(),
        TestPPGMeditationData(),
        TestPPGMeditationData(),
        TestPPGMeditationData(),
//        TestPPGTiredData(),
//        TestPPGFallingAsleepData(),
//        TestPPGSleepingData(),
        
        
    ]
    
    public func getTestEEGName(id:Int) -> String {
        //keep in bounds
        var dataID:Int = id-1
        if (dataID >= _testEEGData.count) {
            print("XvMuse: getTestEEG(id): Error: ID", dataID, "out of bounds of", _testEEGData.count, "- Using array max")
            dataID = _testEEGData.count-1
        }
        return _testEEGData[dataID].getName()
    }
    public func getTestEEG(id:Int) -> XvEEGPacket {
        
        //keep in bounds
        var dataID:Int = id-1
        if (dataID >= _testEEGData.count) {
            print("XvMuse: getTestEEG(id): Error: ID", dataID, "out of bounds of", _testEEGData.count, "- Using array max")
            dataID = _testEEGData.count-1
        }
        
        //loop through all four sensors, getting test data and processing it via FFT
        for i:Int in 0..<4 {
            let testEEGPacket:MuseEEGPacket = _testEEGData[dataID].getPacket(for: i)
            _testEEG.update(withFFTResultSet: _fft.process(eegPacket: testEEGPacket))
        }
        //after the four sensors are processed, return the object to use by the application
        return convert(museEEG: _testEEG)
        
    }
    
    private var testPPGInit:Bool = false
    public func processTestPPG(id:Int) {
        
        if (!testPPGInit){
            _testPPG.set(deviceName: .muse2)
            testPPGInit = true
        }
       
        //keep in bounds
        var dataID:Int = id-1
        if (dataID >= _testPPGData.count) {
            print("XvMuse: getTestPPG(id): Error: ID", dataID, "out of bounds of", _testPPGData.count, "- Using array max")
            dataID = _testPPGData.count-1
        }
        
        //process middle sensor
        let testPPGPacket:MusePPGPacket = _testPPGData[dataID].getPacket()
        
        if let testPPGResult:MusePPGResult = _testPPG.update(
            withPPGPacket: testPPGPacket,
            allowsHeartMetrics: heartGateNoisePct <= 35.0 && latestTensionPct < heartTensionThreshold,
            allowsRespMetrics: heartGateNoisePct <= 35.0
        ) {
            
            //if streams are valid...
            if let testPPGStreams:MusePPGStreams = testPPGResult.streams {
                //send blood flow and resp streams to parent
                delegate?.didReceive(ppgStreams: convert(musePPGStreams: testPPGStreams))
            }
            
            //if heart event is valid...
            if let testPPGHeartEvent:MusePPGHeartEvent = testPPGResult.heartEvent {
                //send up to parent
                delegate?.didReceive(ppgHeartEvent: convert(musePPGHeartEvent: testPPGHeartEvent))
            }
        }
    }
    
    //MARK: - BLUETOOTH CONNECTION
    public var connected:Bool = false
    
    func isAttemptingConnection() {
        delegate?.museIsAttemptingConnection()
    }
    
    public func isConnecting() {
        delegate?.museIsConnecting()
    }
    
    public func didConnect() {
    
        connected = true
        resetBatteryStateForConnection()
        
        //communication protocol
        //https://sites.google.com/a/interaxon.ca/muse-developer-site/muse-communication-protocol
        
        //version handshake, set to v2
        processingQ.asyncAfter(deadline: .now() + 0.5) {
            self.bluetooth.versionHandshake()
        }
        
        //config commands, if desired
        processingQ.asyncAfter(deadline: .now() + 0.9) { [self] in
            
            //uncomment to turn off PPG
            //setting the preset turns off the PPG
            //bluetooth.set(preset: MuseConstants.PRESET_20)
            
            //print("Version?", majorVersion, minorVersion)
            if (deviceName == .museS) {
                print("XvMuse: Using MuseS preset 51")
                bluetooth.set(preset: MuseConstants.PRESET_51)
            } else if (deviceName == .museAthena) {
                print("XvMuse: Init Athena")
                bluetooth.athenaInitializeAndStart()
            }
            
            
            //sets host platform to Mac
            //bluetooth.set(hostPlatform: MuseConstants.HOST_PLATFORM_MAC)
        }
        
        //get status
        processingQ.asyncAfter(deadline: .now() + 1.2) {
            self.bluetooth.controlStatus()
        }
        
        //notify delegate
        delegate?.museDidConnect()
    }
    
    public func didDisconnect() {
        connected = false
        resetBatteryStateForConnection()
        delegate?.museDidDisconnect()
    }
    
    public func didLoseConnection() {
        connected = false
        resetBatteryStateForConnection()
        delegate?.museLostConnection()
    }
    
    
    //MARK: - Thread -
    // Single lane for all DSP + parsing (keeps _fft/history thread-safe)
    private let processingQ = DispatchQueue(label: "com.primaryassembly.xvmuse.processing", qos: .userInitiated)
    
    //MARK: - MOCK DATA -
    //if the muse disconnects, this pipes in test EEG data until the muse can reconnect
    fileprivate var eegTestDataLoop:Timer = Timer()
    fileprivate var ppgTestDataLoop:Timer = Timer() //PPG has its own timer interval
    fileprivate var testDataSet:Int = 0

    /* Tracked with a flag rather than by asking the Timers: these are non-optional placeholders
     before the first start, and the parse hot path checks this on every notification — a Bool
     read is free. */
    fileprivate var isTestDataRunning:Bool = false

    public func startTestData(set:Int){
        print("MuseHelper: startTestData: Set", set)
        testDataSet = set
        isTestDataRunning = true

        eegTestDataLoop.invalidate()
        eegTestDataLoop = Timer.scheduledTimer(timeInterval: 0.05, target: self, selector: #selector(generateTestEEGData), userInfo: nil, repeats: true)
        ppgTestDataLoop.invalidate()
        ppgTestDataLoop = Timer.scheduledTimer(timeInterval: 0.10, target: self, selector: #selector(generateTestPPGData), userInfo: nil, repeats: true)
        
    }
    
    /* The timers fire on the MAIN run loop, but the pipeline they drive mutates the same
     state (sensor spectra, heldSensorNoise, region caches, analyzers) that live packets
     mutate on processingQ — so the work is dispatched onto processingQ to keep the "single
     lane for all DSP + parsing" rule true during test playback and the test/live handoff. */
    @objc public func generateTestEEGData() {
        processingQ.async { [weak self] in
            guard let self else { return }
            //grabs pre-recorded EEG data from muse framework
            self.processAndPublishEEGData(from: self.getTestEEG(id: self.testDataSet))
        }
    }
    @objc func generateTestPPGData() {
        processingQ.async { [weak self] in
            //processes pre-recorded PPG data from muse framework
            //note: delegate callbacks happen inside the processTestPPG func
            self?.processTestPPG(id: self?.testDataSet ?? 0)
        }
    }

    public func stopTestData(){
        eegTestDataLoop.invalidate()
        ppgTestDataLoop.invalidate()
        isTestDataRunning = false
    }

    
    //MARK: - Converters -
    
    //ordered left ear, left forehead, right forehead, right ear
    private func convert(museEEG:MuseEEG) -> XvEEGPacket {
        
        return XvEEGPacket(
            
            sensors: [
                XvEEGSensorPacket(
                    area: XvEEGScalpLocation.TP.rawValue,
                    index: 9,
                    spectrum: museEEG.TP9.linearSpectrum,
                    detailSpectrum: museEEG.TP9.detailLinearSpectrum
                ),
                XvEEGSensorPacket(
                    area: XvEEGScalpLocation.AF.rawValue,
                    index: 7,
                    spectrum: museEEG.AF7.linearSpectrum,
                    detailSpectrum: museEEG.AF7.detailLinearSpectrum
                ),
                XvEEGSensorPacket(
                    area: XvEEGScalpLocation.AF.rawValue,
                    index: 8,
                    spectrum: museEEG.AF8.linearSpectrum,
                    detailSpectrum: museEEG.AF8.detailLinearSpectrum
                ),
                XvEEGSensorPacket(
                    area: XvEEGScalpLocation.TP.rawValue,
                    index: 10,
                    spectrum: museEEG.TP10.linearSpectrum,
                    detailSpectrum: museEEG.TP10.detailLinearSpectrum
                )
            ]
        )
    }
    
    private func convert(musePPGStreams:MusePPGStreams) -> XvPPGStreams {
        return XvPPGStreams(
            bloodFlow: musePPGStreams.bloodFlow,
            resp: musePPGStreams.resp
        )
    }
    
    private func convert(musePPGHeartEvent:MusePPGHeartEvent) -> XvPPGHeartEvent {
        return XvPPGHeartEvent(
            bpm: musePPGHeartEvent.bpm,
            sdnn: musePPGHeartEvent.sdnn,
            beatStrength: musePPGHeartEvent.pulseStrength,
            hrvBaseline: musePPGHeartEvent.hrvBaseline
        )
    }
    
    private func convert(museAccelPacket:MuseAccelPacket) -> XvAccelPacket {
        return XvAccelPacket(
            x: museAccelPacket.x,
            y: museAccelPacket.y,
            z: museAccelPacket.z,
            movement: museAccelPacket.movement
        )
    }

}

extension XvMuse: FFTManagerDelegate {}

//MARK: - State tuning parameter descriptors

/* Descriptor for one runtime-tunable state-detection parameter. The app's tuning panel
 renders itself from `XvEEGStateTuningParameter.all`, so adding a parameter here (plus its
 key in the matching setTuning switch) is all it takes to expose a new control.

 `group` drives panel sections: "gates", "med", "focus", "dreamy", "gamma", "quiet".
 Defaults MUST match the code defaults in EEGStateScorer / EEGStateAnalyzer / XvMuse —
 the app treats an untouched parameter as "leave the framework at its code default". */
public struct XvEEGStateTuningParameter {
    public let key: String
    public let label: String
    public let group: String
    public let defaultValue: Double
    public let minValue: Double
    public let maxValue: Double
    public let step: Double

    public init(_ key: String, _ label: String, _ group: String,
                _ defaultValue: Double, _ minValue: Double, _ maxValue: Double, _ step: Double) {
        self.key = key
        self.label = label
        self.group = group
        self.defaultValue = defaultValue
        self.minValue = minValue
        self.maxValue = maxValue
        self.step = step
    }

    public static let all: [XvEEGStateTuningParameter] = [

        //MARK: gates (analyzer-level)
        XvEEGStateTuningParameter("gates.cleanThreshold", "CLEAN GATE", "gates", 60.0, 0.0, 95.0, 5.0),
        XvEEGStateTuningParameter("gates.scoreSmoothing", "SCORE SMOOTH", "gates", 0.18, 0.02, 0.9, 0.01),
        XvEEGStateTuningParameter("gates.blockedFadeSmoothing", "BLOCKED FADE", "gates", 0.05, 0.01, 0.5, 0.01),
        XvEEGStateTuningParameter("gates.stabilityLowSD", "STEADY SD LO", "gates", 0.25, 0.05, 2.0, 0.05),
        XvEEGStateTuningParameter("gates.stabilityHighSD", "STEADY SD HI", "gates", 2.2, 0.3, 5.0, 0.05),

        //MARK: meditation
        XvEEGStateTuningParameter("med.alphaLeadLowDb", "αLEAD LO dB", "med", -2.0, -8.0, 4.0, 0.1),
        XvEEGStateTuningParameter("med.alphaLeadHighDb", "αLEAD HI dB", "med", 0.0, -4.0, 8.0, 0.1),
        XvEEGStateTuningParameter("med.alphaLeadSmoothing", "αLEAD SMOOTH", "med", 0.10, 0.02, 1.0, 0.01),
        XvEEGStateTuningParameter("med.earAlphaLeadLowDb", "EAR αLD LO dB", "med", 1.0, -4.0, 8.0, 0.1),
        XvEEGStateTuningParameter("med.earAlphaLeadHighDb", "EAR αLD HI dB", "med", 5.0, 0.0, 12.0, 0.1),
        XvEEGStateTuningParameter("med.tiltOffsetHz", "TILT CTR Hz", "med", -1.0, -6.0, 2.0, 0.1),
        XvEEGStateTuningParameter("med.tiltRadiusHz", "TILT RAD Hz", "med", 3.0, 0.5, 8.0, 0.1),
        XvEEGStateTuningParameter("med.organizedLowHz", "ORG LO Hz", "med", -0.8, -4.0, 2.0, 0.1),
        XvEEGStateTuningParameter("med.organizedHighHz", "ORG HI Hz", "med", 0.4, -2.0, 4.0, 0.1),
        XvEEGStateTuningParameter("med.supportCentroidWeight", "W CENTROID", "med", 0.35, 0.0, 1.0, 0.05),
        XvEEGStateTuningParameter("med.supportOrganizedWeight", "W ORGANIZED", "med", 0.35, 0.0, 1.0, 0.05),
        XvEEGStateTuningParameter("med.supportSteadyWeight", "W STEADY", "med", 0.30, 0.0, 1.0, 0.05),
        XvEEGStateTuningParameter("med.baseOffset", "BASE", "med", 0.55, 0.0, 1.0, 0.05),
        XvEEGStateTuningParameter("med.supportSpan", "SUPPORT SPAN", "med", 0.60, 0.0, 1.0, 0.05),

        //MARK: focus
        XvEEGStateTuningParameter("focus.tiltLowHz", "FAST TILT LO", "focus", -0.8, -4.0, 6.0, 0.1),
        XvEEGStateTuningParameter("focus.tiltHighHz", "FAST TILT HI", "focus", 1.2, -2.0, 8.0, 0.1),
        XvEEGStateTuningParameter("focus.calmTiltOffsetHz", "CALM CTR Hz", "focus", -1.5, -5.0, 3.0, 0.1),
        XvEEGStateTuningParameter("focus.calmTiltRadiusHz", "CALM RAD Hz", "focus", 1.4, 0.3, 6.0, 0.1),
        XvEEGStateTuningParameter("focus.broadLowHz", "BROAD LO Hz", "focus", -1.2, -4.0, 2.0, 0.1),
        XvEEGStateTuningParameter("focus.broadHighHz", "BROAD HI Hz", "focus", 0.0, -2.0, 4.0, 0.1),
        XvEEGStateTuningParameter("focus.notAlphaLedLowDb", "¬α LO dB", "focus", -1.0, -6.0, 4.0, 0.1),
        XvEEGStateTuningParameter("focus.notAlphaLedHighDb", "¬α HI dB", "focus", 1.0, -4.0, 6.0, 0.1),
        XvEEGStateTuningParameter("focus.supportBroadWeight", "W BROAD", "focus", 0.55, 0.0, 1.0, 0.05),
        XvEEGStateTuningParameter("focus.supportSteadyWeight", "W STEADY", "focus", 0.45, 0.0, 1.0, 0.05),
        XvEEGStateTuningParameter("focus.baseOffset", "BASE", "focus", 0.55, 0.0, 1.0, 0.05),
        XvEEGStateTuningParameter("focus.supportSpan", "SUPPORT SPAN", "focus", 0.45, 0.0, 1.0, 0.05),

        //MARK: dreamy
        XvEEGStateTuningParameter("dreamy.thetaLeadLowDb", "θLEAD LO dB", "dreamy", 0.0, -4.0, 6.0, 0.1),
        XvEEGStateTuningParameter("dreamy.thetaLeadHighDb", "θLEAD HI dB", "dreamy", 3.0, -2.0, 10.0, 0.1),
        XvEEGStateTuningParameter("dreamy.thetaLeadSmoothing", "θLEAD SMOOTH", "dreamy", 0.04, 0.01, 0.5, 0.01),
        XvEEGStateTuningParameter("dreamy.vsFastSmoothing", "VSFAST SMOOTH", "dreamy", 0.15, 0.01, 0.9, 0.01),
        XvEEGStateTuningParameter("dreamy.vsFastLowDb", "VSFAST LO dB", "dreamy", -1.0, -6.0, 4.0, 0.1),
        XvEEGStateTuningParameter("dreamy.vsFastHighDb", "VSFAST HI dB", "dreamy", 2.0, -2.0, 8.0, 0.1),
        XvEEGStateTuningParameter("dreamy.notFastOnsetHz", "¬FAST ON Hz", "dreamy", 0.5, -2.0, 4.0, 0.1),
        XvEEGStateTuningParameter("dreamy.notFastFullHz", "¬FAST FULL Hz", "dreamy", 2.0, 0.0, 6.0, 0.1),
        XvEEGStateTuningParameter("dreamy.prominenceLowDb", "RHYTHM LO dB", "dreamy", 4.0, 0.0, 12.0, 0.5),
        XvEEGStateTuningParameter("dreamy.prominenceHighDb", "RHYTHM HI dB", "dreamy", 7.0, 1.0, 16.0, 0.5),
        XvEEGStateTuningParameter("dreamy.gammaLowDb", "γCALM LO dB", "dreamy", 2.0, -4.0, 8.0, 0.1),
        XvEEGStateTuningParameter("dreamy.gammaHighDb", "γCALM HI dB", "dreamy", 4.0, -2.0, 12.0, 0.1),
        XvEEGStateTuningParameter("dreamy.calmLowEndLowDb", "LOWEND LO dB", "dreamy", -2.0, -8.0, 4.0, 0.1),
        XvEEGStateTuningParameter("dreamy.calmLowEndHighDb", "LOWEND HI dB", "dreamy", 2.0, -4.0, 8.0, 0.1),
        XvEEGStateTuningParameter("dreamy.baseOffset", "BASE", "dreamy", 0.50, 0.0, 1.0, 0.05),
        XvEEGStateTuningParameter("dreamy.supportSpan", "SUPPORT SPAN", "dreamy", 0.50, 0.0, 1.0, 0.05),
        XvEEGStateTuningParameter("dreamy.tensionDampOnset", "TENS DAMP ON", "dreamy", 30.0, 0.0, 80.0, 5.0),
        XvEEGStateTuningParameter("dreamy.tensionDampFull", "TENS DAMP FULL", "dreamy", 80.0, 20.0, 100.0, 5.0),
        XvEEGStateTuningParameter("dreamy.tensionDampFloor", "TENS DAMP FLR", "dreamy", 0.15, 0.0, 1.0, 0.05),

        //MARK: gamma focus
        XvEEGStateTuningParameter("gamma.lowDb", "γ LO dB", "gamma", 1.5, -6.0, 8.0, 0.1),
        XvEEGStateTuningParameter("gamma.highDb", "γ HI dB", "gamma", 4.5, -2.0, 14.0, 0.1),
        XvEEGStateTuningParameter("gamma.smoothing", "SMOOTH", "gamma", 0.10, 0.01, 0.9, 0.01),
        XvEEGStateTuningParameter("gamma.tensionGateOnset", "TENS GATE ON", "gamma", 30.0, 0.0, 90.0, 5.0),
        XvEEGStateTuningParameter("gamma.tensionGateFull", "TENS GATE FULL", "gamma", 70.0, 10.0, 100.0, 5.0),

        //MARK: quiet calibration anchors
        /* NOTE: code defaults are per-device (muse2 0.5/13.0, museS 1.5/10.5, athena -4.5/9.0).
         The descriptor defaults below are the legacy/muse2 anchors; an untouched control leaves
         the per-device calibration in place — it only overrides once the user adjusts it. */
        XvEEGStateTuningParameter("quiet.quietDb", "QUIET dB", "quiet", -0.5, -15.0, 15.0, 0.5),
        XvEEGStateTuningParameter("quiet.loudDb", "LOUD dB", "quiet", 2.5, -5.0, 30.0, 0.5),
    ]
}
