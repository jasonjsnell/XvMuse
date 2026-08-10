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
    /* Per-frame blend weights at the ~21 Hz publish rate, so 0.45 is a time constant of about
     0.08 s — a cliff, not a fade. That was deliberate when the gate could zero quiet on a blink
     and wanted to react instantly, but it also meant every dip arrived as a hard edge that no
     amount of downstream smoothing could fully round off. Now that only sustained tension can
     pull quiet down, the fall can afford to glide: 0.15 is roughly 0.3 s, close to the recovery
     side, so quiet moves at a similar speed in both directions.

     This is the SOURCE smoothing, ahead of the split to music and visuals, so it is the one place
     that fixes the shape of the signal for both. */
    private let quietFallSmoothing: Double = 0.15
    private let quietRecoverSmoothing: Double = 0.10

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
                XvEEGAnalysis.quietCalibration = .legacy
                _ppg.set(deviceName: .muse1)
            } else if (majorVersion == "MuseS") {
                /* Both the Muse S and the Athena advertise as "MuseS" — same sleep-band housing.
                 This is the provisional guess; if the Athena main characteristic turns up during
                 discovery, discoveredAthena() overwrites both the device and the calibration. */
                deviceName = .museS
                XvEEGAnalysis.quietCalibration = .museS
                _ppg.set(deviceName: .museS)
            }
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
            XvEEGAnalysis.quietCalibration = .muse2
            _ppg.set(deviceName: .muse2)
        }
        print("XvMuse: Version:", majorVersion ?? "unknown", minorVersion ?? "unknown", "| Device", deviceName ?? .unknown)
    }
    func discoveredAthena() {
        minorVersion = "Athena"
        deviceName = .museAthena
        XvEEGAnalysis.quietCalibration = .athena
        _ppg.set(deviceName: .museAthena)
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
                    allowsHeartMetrics: latestNoisePct <= 35.0 && latestTensionPct < heartTensionThreshold,
                    allowsRespMetrics: latestNoisePct <= 35.0
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
        _mlManager.process(linearSpectrum: eeg.linearSpectrum)

        /* Signal quality is emitted from here rather than from the ML callback, because only one
         of its three parts comes from the model. Noise is the model's job; tension and blink are
         measured straight off the spectrum by XvEEGAnalysis, each against its own drifting
         resting level. Publishing all of it on the EEG cadence keeps the three in step.

         Both read the device average across all four sensors. Forehead and brow tension spikes
         the 20-35 Hz window just as hard as jaw tension does, so limiting tension to the ears
         would miss half of what it is there to catch. */
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
            let quiet = gatedQuiet(fromRawQuiet: rawQuiet)
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

    func didReceiveMLNoise(noise: Double, clean: Double) {
        latestNoisePct = noise
        latestCleanPct = clean

        //the combined signal-quality update is published on the EEG cadence, not here

        // Per-sensor noise localization: only when the device-level (averaged) noise is high, run each sensor's spectrum through the same model to see WHICH electrode(s) are noisy. Each sensor judged independently (no peer comparison) so "all loose / headset off" → all high.
        if noise > 10.0 {
            func sensorNoise(_ sensor: XvEEGSensor) -> Double {
                guard sensor.hasValidSpectrum,
                      let p = _mlManager.noiseProbability(forSpectrum: sensor.linearSpectrum) else {
                    return 0.0
                }
                return p
            }

            let tp9Noise = sensorNoise(eeg.TP9)
            let af7Noise = sensorNoise(eeg.AF7)
            let af8Noise = sensorNoise(eeg.AF8)
            let tp10Noise = sensorNoise(eeg.TP10)

            delegate?.didReceiveSensorNoise(tp9: tp9Noise, af7: af7Noise, af8: af8Noise, tp10: tp10Noise)

            //print("SENSOR NOISE | all:\(Int(noise.rounded()))  TP9(L Ear):\(Int(tp9Noise.rounded()))  AF7(L Frnt):\(Int(af7Noise.rounded()))  AF8(R Frnt):\(Int(af8Noise.rounded()))  TP10(R Ear):\(Int(tp10Noise.rounded()))")
        } else {
            delegate?.didReceiveSensorNoise(tp9: 0, af7: 0, af8: 0, tp10: 0)
        }
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

    private func logQuiet(raw: Double, published: Double, faded: Bool, capped: Bool) {
        let now = Date().timeIntervalSince1970

        if _quietWindowStart == 0 { _quietWindowStart = now }
        _quietRawSamples.append(raw)
        _quietPubSamples.append(published)
        if faded { _quietFadedFrames += 1 }
        if capped { _quietCappedFrames += 1 }

        if now - _quietLogTime >= 1.0 {
            _quietLogTime = now
            print(String(
                format: "QUIET  %3.0f (raw %3.0f)%@%@ | tension %3.0f blink %3.0f clean %3.0f noise %3.0f",
                published, raw,
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
            print(String(
                format: "QUIET SUMMARY  | frames %3d | raw med %3.0f p10 %3.0f p90 %3.0f | published med %3.0f p10 %3.0f p90 %3.0f | faded %2.0f%% capped %2.0f%%",
                _quietRawSamples.count,
                pct(sortedRaw, 0.5), pct(sortedRaw, 0.1), pct(sortedRaw, 0.9),
                pct(sortedPub, 0.5), pct(sortedPub, 0.1), pct(sortedPub, 0.9),
                Double(_quietFadedFrames) / count * 100.0,
                Double(_quietCappedFrames) / count * 100.0
            ))
            _quietWindowStart = now
            _quietRawSamples.removeAll(keepingCapacity: true)
            _quietPubSamples.removeAll(keepingCapacity: true)
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

     Anchors (1.5..4.5 dB) were measured on the Muse 2 corpus. Gamma on the Athena runs several
     dB lower at rest (-3.9 median vs the Muse 2's -1.7), so if this pins at 0 on the Athena
     during genuine hard focus, per-device anchors are the fix — same story as quiet's. */
    private var latestPublishedGammaPct: Double = 0.0
    private let gammaFocusSmoothing: Double = 0.10
    private let gammaFocusLowDb: Double = 1.5
    private let gammaFocusHighDb: Double = 4.5

    private func publishGammaFocus(gammaDb: Double) {
        guard gammaDb.isFinite else { return }

        let span = max(gammaFocusHighDb - gammaFocusLowDb, 1e-6)
        let raw = min(max((gammaDb - gammaFocusLowDb) / span, 0.0), 1.0)

        let tensionGateSpan = 70.0 - 30.0
        let tensionAmount = min(max((latestTensionPct - 30.0) / tensionGateSpan, 0.0), 1.0)
        let target = raw * (1.0 - tensionAmount) * 100.0

        latestPublishedGammaPct += gammaFocusSmoothing * (target - latestPublishedGammaPct)
        delegate?.didReceiveGammaFocus(min(max(latestPublishedGammaPct, 0.0), 100.0))
    }

    private func gatedQuiet(fromRawQuiet rawQuiet: Double) -> Double {
        var quiet = rawQuiet

        //an unusable signal can't be called quiet, whatever the numbers say
        let faded = shouldFadeCleanStateValues
        let capped = !faded && latestNoisePct > 70.0
        if faded {
            quiet = 0.0
        } else if capped {
            quiet = min(quiet, 30.0)
        }

        /* Muscle tension is NOT damped here any more — it was being counted twice.

         Quiet is a wideband 2-47 Hz loudness measure, and 20-35 Hz of that range IS the muscle
         band the tension detector reads. A clench already pushes the raw quiet value down on its
         own; multiplying by the tension ramp on top of that applied the same evidence a second
         time and drove quiet toward zero far faster than the signal warranted.

         The blink and noise guards above stay, because those bands are screened rather than
         measured — a blink is a transient the wideband average barely notices. */

        let target = min(max(quiet, 0.0), 100.0)
        let smoothing = target < latestPublishedQuietPct ? quietFallSmoothing : quietRecoverSmoothing
        latestPublishedQuietPct = (smoothing * target) + ((1.0 - smoothing) * latestPublishedQuietPct)
        let published = min(max(latestPublishedQuietPct, 0.0), 100.0)

        logQuiet(raw: rawQuiet, published: published, faded: faded, capped: capped)
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
            allowsHeartMetrics: latestNoisePct <= 35.0 && latestTensionPct < heartTensionThreshold,
            allowsRespMetrics: latestNoisePct <= 35.0
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
            allowsHeartMetrics: latestNoisePct <= 35.0 && latestTensionPct < heartTensionThreshold,
            allowsRespMetrics: latestNoisePct <= 35.0
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
    
    @objc public func generateTestEEGData() {
        //grabs pre-recorded EEG data from muse framework
        processAndPublishEEGData(from: getTestEEG(id: testDataSet))
    }
    @objc func generateTestPPGData() {
        //processes pre-recorded PPG data from muse framework
        //note: delegate callbacks happen inside the processTestPPG func
        processTestPPG(id: testDataSet)
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
            beatStrength: musePPGHeartEvent.pulseStrength
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
