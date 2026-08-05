//
//  ParserAthena.swift
//  XvMuse
//
//  Created by Jason Snell on 12/1/25.
//  Copyright © 2025 Jason Snell. All rights reserved.
//

// from: https://github.com/DominiqueMakowski/OpenMuse/

/*
 Athena Muse BLE Message Parser
 ============================================

 Implementation that follows the actual message structure:
 MESSAGE → PACKET → DATA SUBPACKETS

 Message Structure:
 ------------------
 Each BLE MESSAGE contains one or more PACKETS. Each PACKET has a 14-byte header
 followed by a data section containing multiple DATA SUBPACKETS:

 MESSAGE (BLE transmission with timestamp)
   └─ PACKET (14-byte header + data section)
        ├─ First Subpacket: Raw sensor data (no TAG, no header)
        └─ Additional Subpackets: [TAG (1 byte)][Header (4 bytes)][Data (variable)]
             ├─ TAG: Sensor type identifier (e.g., 0x47=ACCGYRO, 0x12=EEG8)
             ├─ subpacket_index: Per-sensor-type sequence counter (0-255, wraps)
             ├─ Unknown bytes: 3 metadata bytes (purpose unknown)
             └─ Sensor data: Variable length depending on sensor type

 Timestamp Calculation & Device Timing:
 ---------------------------------------
 Device timestamps (packet_time) are derived from a 256 kHz hardware clock with 3.906 µs resolution.
 Multiple packets often share identical packet_time values (~11-30% are duplicates).

 Timestamp generation per message:
   1. Sort packets by (packet_time, packet_index, subpacket_index)
      - packet_index: Packet sequence counter (0-255), ensures correct ordering of duplicates
      - Analysis: 100% sequential in duplicate groups (1871/1871 tested)
   2. Use first packet's packet_time as anchor
   3. Generate uniform timestamps: anchor + (sample_index / sampling_rate)

 Hardware Timing Artifacts:
   - ~4% of packet_time values have timing inversions (timestamps go backwards)
   - packet_index remains sequential (100% accurate for packet order)
   - Inversions likely due to async sensor buffering and clock jitter
   - Final monotonicity ensured by stream.py buffering/sorting before LSL output
 */

import Foundation
import XvSensors

protocol ParserAthenaDelegate:AnyObject {
    func didReceiveAthena(accelPacket:MuseAccelPacket)
    func didReceiveAthena(batteryPacket:XvBatteryPacket)
    func didReceiveAthenaEEGBuffer(
        packetIndex:UInt8,
        timestamp:TimeInterval,
        sensor: Int,
        samples: [Float]
    )
    func didReceiveAthena(ppgPacket:MusePPGPacket)
}

class ParserAthena {
    
    init(){}
    public weak var delegate:ParserAthenaDelegate?
    
    
    // Buffer one shared EEG window size, mirroring legacy Muse
    private let eegWindowSize = 12
    
    // Per-channel EEG buffers. FIFO arrays (not ring buffers): samples are consumed in
    // non-overlapping eegWindowSize chunks so the FFT is fed fresh data once — exactly like the
    // legacy 12-sample EEG packets. (The old RingBuffer re-emitted last(12) every packet, feeding
    // the FFT overlapping/duplicate samples → distorted spectrum + chunky/plateaued chart.)
    private var tp9Buffer:  [Float] = []
    private var af7Buffer:  [Float] = []
    private var af8Buffer:  [Float] = []
    private var tp10Buffer: [Float] = []

    // MARK: Protocol diagnostics

    private var diagnosticCurrentRXSequence: UInt64 = 0
    private var diagnosticNotificationTotal: UInt64 = 0
    private var diagnosticWindowStartUptime = ProcessInfo.processInfo.systemUptime
    private var diagnosticWindowNotifications = 0
    private var diagnosticWindowPackets = 0
    private var diagnosticWindowAcceptedPackets = 0
    private var diagnosticWindowRejectedPackets = 0
    private var diagnosticWindowEEGSamples = 0
    private var diagnosticWindowPacketIndexAnomalies = 0
    private var diagnosticWindowSubpacketIndexAnomalies = 0
    private var diagnosticWindowByte13Nonzero = 0
    private var diagnosticWindowIngressGaps = 0
    private var diagnosticWindowTagCounts: [UInt8: Int] = [:]
    private var diagnosticWindowDropCounts: [String: Int] = [:]
    private var diagnosticDropTotals: [String: Int] = [:]
    private var diagnosticLastPacketIndex: UInt8?
    private var diagnosticLastSubpacketIndex: [UInt8: UInt8] = [:]
    
    private enum AthenaSensorType {
        case eeg
        case accgyro
        case optics
        case battery
        case unknown
    }
    
    private struct AthenaSensorConfig {
        let type: AthenaSensorType
        let nChannels: Int
        let nSamples: Int
        let rate: Double
        let dataLen: Int
    }
    
    private enum Athena {
        static let packetHeaderSize = 14
        static let subpacketHeaderSize = 5
        static let deviceClockHz: Double = 256_000.0
        
        // TAG / packet_id config (mirrors Python SENSORS dict)
        static let sensors: [UInt8: AthenaSensorConfig] = [
            0x11: .init(type: .eeg,     nChannels: 4,  nSamples: 4, rate: 256.0, dataLen: 28),
            0x12: .init(type: .eeg,     nChannels: 8,  nSamples: 2, rate: 256.0, dataLen: 28),
            0x34: .init(type: .optics,  nChannels: 4,  nSamples: 3, rate:  64.0, dataLen: 30),
            0x35: .init(type: .optics,  nChannels: 8,  nSamples: 2, rate:  64.0, dataLen: 40),
            0x36: .init(type: .optics,  nChannels: 16, nSamples: 1, rate:  64.0, dataLen: 40),
            0x47: .init(type: .accgyro, nChannels: 6,  nSamples: 3, rate:  52.0, dataLen: 36),
            0x53: .init(type: .unknown, nChannels: 0,  nSamples: 0, rate:   0.0, dataLen: 24),
            0x98: .init(type: .battery, nChannels: 1,  nSamples: 1, rate:   1.0, dataLen: 20),

            /* New in firmware 3.1.29. Its payload is almost entirely constant from packet to
             packet — 63B600B800 ... FFFF F602BF72 recurs verbatim with only a few bytes moving —
             so it reads as status or telemetry rather than sensor data. It arrives rarely, about
             eight times in two thousand packets. Registered as known-but-unused so it stops being
             reported as an unrecognised tag; revisit if the constant bytes turn out to encode
             something worth having. */
            /* dataLen 20, read off the drop log: "need:29 available:25" — 29 was 5 header bytes
             plus a wrong 24, and only 25 bytes exist, so the payload is 20. */
            0x88: .init(type: .unknown, nChannels: 0,  nSamples: 0, rate:   0.0, dataLen: 20),
        ]
        
        // scales
        static let eegScale: Double = 1450.0 / 16383.0

        //14-bit samples are unsigned 0...16383, so zero volts sits at the midpoint, not at 0
        static let eegMidpoint: Double = 8192.0
        static let accScale: Float  = 0.0000610352
        static let gyroScale: Float = -0.0074768
        static let opticsScale: Double = 1.0 / 32768.0
    }
    
    func parse(
        bytes: [UInt8],
        timestamp: Double,
        rxSequence: UInt64 = 0,
        ingressDeltaMS: Double = 0
    ) {
        diagnosticCurrentRXSequence = rxSequence
        diagnosticNotificationTotal &+= 1
        diagnosticWindowNotifications += 1
        if ingressDeltaMS > 100.0 { diagnosticWindowIngressGaps += 1 }
        defer { emitDiagnosticSummaryIfNeeded() }

        var offset = 0
        let count = bytes.count
        
        while offset < count {
            // Need at least a header
            guard offset + Athena.packetHeaderSize <= count else {
                recordDiagnosticDrop(
                    "short-packet-header",
                    offset: offset,
                    detail: "need:\(Athena.packetHeaderSize) available:\(count - offset)"
                )
                break
            }
            
            let packetLen = Int(bytes[offset]) // first byte = declared packet length
            
            guard packetLen >= Athena.packetHeaderSize else {
                recordDiagnosticDrop(
                    "invalid-packet-length",
                    offset: offset,
                    detail: "declared:\(packetLen) minimum:\(Athena.packetHeaderSize)"
                )
                break
            }

            guard offset + packetLen <= count else {
                recordDiagnosticDrop(
                    "packet-length-overrun",
                    offset: offset,
                    detail: "declared:\(packetLen) available:\(count - offset)"
                )
                break
            }
            
            let packetBytes = Array(bytes[offset ..< offset + packetLen])
            
            // Parse header
            let packetIndex: UInt8 = packetBytes[1]
            let packetTimeRaw = UInt32(packetBytes[2])
                | (UInt32(packetBytes[3]) << 8)
                | (UInt32(packetBytes[4]) << 16)
                | (UInt32(packetBytes[5]) << 24)
            let packetTimeSec = Double(packetTimeRaw) / Athena.deviceClockHz
            
            // Unknown1: bytes[6...8]
            // packet_id: sensor type for the first subpacket
            let packetId: UInt8 = packetBytes[9]
            let packetConfig = Athena.sensors[packetId]
            let packetType = packetConfig?.type
            // Unknown2: bytes[10...12]
            let byte13: UInt8 = packetBytes[13]
            
            /* Byte 13 is NOT a validity marker.

             Older Athena firmware left it as padding, always zero, so the original reverse
             engineering treated a non-zero value as a malformed packet. Firmware 3.1.29
             (Athena_RevF) began putting data there — values climbing by a few per packet and
             wrapping around 40 — and this check started rejecting roughly 95% of all traffic.

             The give-away in the logs was that rejected exactly equalled byte13Nonzero every
             single second, while the two or three packets per second that happened to land on
             zero parsed perfectly and produced EEG samples. Nothing else about the format changed:
             length, packet index, timestamp and packet_id all still decode correctly.

             Validity now rests on the checks that actually mean something — a recognised sensor
             tag and a sane length. */
            let packetValid = (packetType != nil
                            && packetLen >= Athena.packetHeaderSize)

            diagnosticWindowPackets += 1
            if packetValid {
                diagnosticWindowAcceptedPackets += 1
            } else {
                diagnosticWindowRejectedPackets += 1
            }
            if byte13 != 0 { diagnosticWindowByte13Nonzero += 1 }

            if let lastPacketIndex = diagnosticLastPacketIndex {
                let delta = Int(packetIndex &- lastPacketIndex)
                if delta != 1 {
                    diagnosticWindowPacketIndexAnomalies += 1
                }
            }
            diagnosticLastPacketIndex = packetIndex

            if packetType == nil {
                recordDiagnosticDrop(
                    "unknown-primary-tag",
                    offset: offset,
                    detail: "tag:\(diagnosticTag(packetId)) idx:\(packetIndex) byte13:\(byte13)"
                )
            }
            /* No longer recorded as a drop — byte 13 carrying data is normal on firmware 3.1.29
             and later. The counter above still tracks it, since its behaviour is worth watching
             while we work out what the field actually is. */
            
            let dataSection: [UInt8]
            if packetBytes.count > Athena.packetHeaderSize {
                dataSection = Array(packetBytes[Athena.packetHeaderSize ..< packetBytes.count])
            } else {
                dataSection = []
            }
            
            // Now parse subpackets within this packet
            parseAthenaDataSubpackets(
                packetValid: packetValid,
                packetType: packetType,
                packetId: packetId,
                packetConfig: packetConfig,
                packetIndex: packetIndex,
                packetTimeRaw: packetTimeRaw,
                packetTimeSec: packetTimeSec,
                data: dataSection,
                timestamp: timestamp,
                packetByte13: byte13
            )
            
            offset += packetLen
        }
    }
    
    private func parseAthenaDataSubpackets(
        packetValid: Bool,
        packetType: AthenaSensorType?,
        packetId: UInt8,
        packetConfig: AthenaSensorConfig?,
        packetIndex: UInt8,
        packetTimeRaw: UInt32,
        packetTimeSec: Double,
        data: [UInt8],
        timestamp: Double,
        packetByte13: UInt8
    ) {
        var offset = 0
        let count = data.count
       
        // 1. First subpacket: raw data only, type = packetType, length from packetConfig.dataLen
        if packetValid, let type = packetType, let cfg = packetConfig {
            let len = cfg.dataLen
            if len > 0, offset + len <= count {
                let firstDataBytes = Array(data[offset ..< offset + len])
                handleAthenaSubpacket(
                    sensorType: type,
                    tagByte: packetId,
                    subpacketIndex: nil,
                    dataBytes: firstDataBytes,
                    packetIndex: packetIndex,
                    packetTimeRaw: packetTimeRaw,
                    packetTimeSec: packetTimeSec,
                    timestamp: timestamp,
                    packetId: packetId,
                    packetByte13: packetByte13,
                    origin: "primary",
                    dataOffset: Athena.packetHeaderSize
                )
                offset += len
            } else {
                recordDiagnosticDrop(
                    "short-primary-data",
                    offset: Athena.packetHeaderSize,
                    detail: "tag:\(diagnosticTag(packetId)) need:\(len) available:\(count)"
                )
            }
        } else if !data.isEmpty {
            recordDiagnosticDrop(
                "primary-skipped-tag-scan-at-zero",
                offset: Athena.packetHeaderSize,
                detail: "parent:\(diagnosticTag(packetId)) firstDataByte:\(diagnosticTag(data[0])) byte13:\(packetByte13)"
            )
        }
        
        // 2. Additional subpackets: TAG + 4-byte header + data
        while offset + Athena.subpacketHeaderSize <= count {
            let tagByte = data[offset]
            
            guard let cfg = Athena.sensors[tagByte] else {
                // Unknown tag → stop parsing this packet
                recordDiagnosticDrop(
                    "unknown-subpacket-tag",
                    offset: Athena.packetHeaderSize + offset,
                    detail: "parent:\(diagnosticTag(packetId)) tag:\(diagnosticTag(tagByte))"
                )
                break
            }
            
            let dataLen = cfg.dataLen
            if dataLen == 0 {
                recordDiagnosticDrop(
                    "zero-subpacket-length",
                    offset: Athena.packetHeaderSize + offset,
                    detail: "tag:\(diagnosticTag(tagByte))"
                )
                break
            }
            
            // Make sure we have header + data
            guard offset + Athena.subpacketHeaderSize + dataLen <= count else {
                recordDiagnosticDrop(
                    "short-subpacket-data",
                    offset: Athena.packetHeaderSize + offset,
                    detail: "tag:\(diagnosticTag(tagByte)) need:\(Athena.subpacketHeaderSize + dataLen) available:\(count - offset)"
                )
                break
            }
            
            let subpacketIndex = data[offset + 1]
            if let lastSubpacketIndex = diagnosticLastSubpacketIndex[tagByte] {
                let delta = Int(subpacketIndex &- lastSubpacketIndex)
                if delta != 1 {
                    diagnosticWindowSubpacketIndexAnomalies += 1
                }
            }
            diagnosticLastSubpacketIndex[tagByte] = subpacketIndex
            // bytes [offset+2 ..< offset+5] are "unknown" metadata
            
            let start = offset + Athena.subpacketHeaderSize
            let end = start + dataLen
            let dataBytes = Array(data[start ..< end])
            
            handleAthenaSubpacket(
                sensorType: cfg.type,
                tagByte: tagByte,
                subpacketIndex: subpacketIndex,
                dataBytes: dataBytes,
                packetIndex: packetIndex,
                packetTimeRaw: packetTimeRaw,
                packetTimeSec: packetTimeSec,
                timestamp: timestamp,
                packetId: packetId,
                packetByte13: packetByte13,
                origin: "tagged",
                dataOffset: Athena.packetHeaderSize + start
            )
            
            offset = end
        }
    }
    
    // MARK: Athena decoding helpers

    private func athenaBytesToBits(_ data: [UInt8], maxBytes: Int) -> [UInt8] {
        var bits: [UInt8] = []
        bits.reserveCapacity(maxBytes * 8)
        
        for i in 0..<min(maxBytes, data.count) {
            let b = data[i]
            for bitPos in 0..<8 {
                let bit = (b >> bitPos) & 0x01
                bits.append(bit)
            }
        }
        return bits
    }

    private func athenaExtractPackedInt(bits: [UInt8], bitStart: Int, bitWidth: Int) -> Int {
        var value = 0
        for bitIdx in 0..<bitWidth {
            if bits[bitStart + bitIdx] != 0 {
                value |= (1 << bitIdx)
            }
        }
        return value
    }
    
    private func decodeAthenaEEG(dataBytes: [UInt8], nChannels: Int) -> [[Float]]? {
        // EEG4: 4 samples × 4 channels = 28 bytes
        // EEG8: 2 samples × 8 channels = 28 bytes
        guard dataBytes.count >= 28 else { return nil }
        
        let nSamples = (nChannels == 4) ? 4 : 2
        
        let bits = athenaBytesToBits(dataBytes, maxBytes: 28)
        //let totalValues = nSamples * nChannels
        var rows: [[Float]] = Array(repeating: Array(repeating: 0, count: nChannels), count: nSamples)
        
        for sampleIdx in 0..<nSamples {
            for chIdx in 0..<nChannels {
                let valueIndex = sampleIdx * nChannels + chIdx
                let bitStart = valueIndex * 14
                let intValue = athenaExtractPackedInt(bits: bits, bitStart: bitStart, bitWidth: 14)
                
                /* Centre on the 14-bit midpoint before scaling, exactly as the legacy parser
                 centres on 2048 for its 12-bit samples.

                 This was missing, and it mattered more than it looks. An uncentred sample sits
                 around 8192 counts, which after scaling is roughly 725 units of constant offset
                 riding on every epoch. The FFT path never removes a mean either, so the Hamming
                 window smeared that DC term into the lowest bins on every frame.

                 It also made the two devices incomparable. Measured on the 21 recorded Muse 2
                 sets, the broadband level that `quiet` is calibrated against sits about 9.5 dB
                 above the same measurement on Athena — and the fixed 2.5...6.0 calibration that
                 works on Athena reads 0 on 100% of Muse 2 frames. Some of that gap is this. */
                let centred = Double(intValue) - Athena.eegMidpoint
                let scaled = centred * Athena.eegScale
                rows[sampleIdx][chIdx] = Float(scaled)
            }
        }
        
        return rows
    }
    
    //p1035
    //4 sensors
    //Optics4: 3 samples × 4 channels = 30 bytes – Channels:
    //LI_NIR, RI_NIR, LI_IR, RI_IR (inner sensors only).”
    
    //p1034, p1043, p1044, p1045, p1046
    //8 sensors
    //“Optics8: 2 samples × 8 channels = 40 bytes Channels:
    //LO_NIR, RO_NIR, LO_IR, RO_IR, LI_NIR, RI_NIR, LI_IR, RI_IR
    /*
     0: LO_NIR ~10
     1: RO_NIR ~10
     2: LO_IR ~1
     3: RO_IR ~1
     4: LI_NIR ~10
     5: RI_NIR ~10
     6: LI_IR
     7: RI_IR
     */
    
    //16 sensors
    //p1041 p1042
    /*
     0.    LO_NIR
     1.    RO_NIR
     2.    LO_IR
     3.    RO_IR
     4.    LI_NIR
     5.    RI_NIR
     6.    LI_IR
     7.    RI_IR
     8.    LO_RED
     9.    RO_RED
     10.    LO_AMB
     11.    RO_AMB
     12.    LI_RED
     13.    RI_RED
     14.    LI_AMB
     15.    RI_AMB
     */
    
    
    private func decodeAthenaOptics(dataBytes: [UInt8], nChannels: Int) -> [[Double]]? {
        // Match Python behavior:
        // Optics4:  3 samples × 4 channels = 30 bytes
        // Optics8:  2 samples × 8 channels = 40 bytes
        // Optics16: 1 sample  × 16 channels = 40 bytes
        
        let nSamples: Int
        let bytesNeeded: Int
        
        switch nChannels {
        case 4:
            nSamples = 3
            bytesNeeded = 30
        case 8:
            nSamples = 2
            bytesNeeded = 40
        case 16:
            nSamples = 1
            bytesNeeded = 40
        default:
            return nil
        }
        
        guard dataBytes.count >= bytesNeeded else { return nil }
        
        // Convert bytes to bit array (LSB first), same as Python _bytes_to_bits
        let bits = athenaBytesToBits(dataBytes, maxBytes: bytesNeeded)
        
        // Allocate samples × channels
        var rows: [[Double]] = Array(
            repeating: Array(repeating: 0.0, count: nChannels),
            count: nSamples
        )
        
        // Parse 20-bit packed values
        for sampleIdx in 0..<nSamples {
            for channelIdx in 0..<nChannels {
                let bitStart = (sampleIdx * nChannels + channelIdx) * 20
                let intValue = athenaExtractPackedInt(bits: bits, bitStart: bitStart, bitWidth: 20)
                let scaled = Double(intValue) * Athena.opticsScale // 1.0 / 32768.0
                rows[sampleIdx][channelIdx] = scaled
            }
        }
        
        return rows
    }

    private func decodeAthenaAccGyro(dataBytes: [UInt8]) -> [[Float]]? {
        // 36 bytes → 3 samples × 6 channels (int16)
        guard dataBytes.count >= 36 else { return nil }
        
        var rows: [[Float]] = []
        rows.reserveCapacity(3)
        
        // 18 Int16
        for sampleIdx in 0..<3 {
            var row: [Float] = []
            row.reserveCapacity(6)
            for ch in 0..<6 {
                let index = (sampleIdx * 6 + ch) * 2
                let lo = UInt16(dataBytes[index])
                let hi = UInt16(dataBytes[index + 1]) << 8
                let value = Int16(bitPattern: lo | hi)
                var f = Float(value)
                if ch < 3 {
                    f *= Athena.accScale  // ACC
                } else {
                    f *= Athena.gyroScale // GYRO
                }
                row.append(f)
            }
            rows.append(row)
        }
        
        return rows
    }

    private func decodeAthenaBattery(dataBytes: [UInt8]) -> Float? {
        // First 2 bytes = SOC
        guard dataBytes.count >= 2 else { return nil }
        let lo = UInt16(dataBytes[0])
        let hi = UInt16(dataBytes[1]) << 8
        let rawSoc = lo | hi
        let percent = Float(rawSoc) / 256.0
        return percent
    }
    
    private func handleAthenaSubpacket(
        sensorType: AthenaSensorType,
        tagByte: UInt8,
        subpacketIndex: UInt8?,
        dataBytes: [UInt8],
        packetIndex: UInt8,
        packetTimeRaw: UInt32,
        packetTimeSec: Double,
        timestamp: Double,
        packetId: UInt8,
        packetByte13: UInt8,
        origin: String,
        dataOffset: Int
    ) {
        diagnosticWindowTagCounts[tagByte, default: 0] += 1

        switch sensorType {
            
        case .eeg:
            guard let cfg = Athena.sensors[tagByte] else { return }
            guard let rows = decodeAthenaEEG(dataBytes: dataBytes, nChannels: cfg.nChannels) else { return }
            diagnosticWindowEEGSamples += rows.count
            
            // rows: [sample][channel] in scaled units
            // Channel mapping for EEG8 (TP9, AF7, AF8, TP10, AUX1..4) matches python EEG_CHANNELS
            
            for sample in rows {
                // Ensure we have at least the four main EEG channels
                guard sample.count >= 4 else { continue }
                
                tp9Buffer.append(sample[0])
                af7Buffer.append(sample[1])
                af8Buffer.append(sample[2])
                tp10Buffer.append(sample[3])
            }
            
            // Emit FRESH, non-overlapping eegWindowSize chunks (consume them) so each sample
            // reaches the FFT exactly once — mirroring legacy's 12-sample EEG packets. The while
            // loop drains every complete chunk that has accumulated (in case a burst arrived),
            // keeping the publish rate locked to the true sample rate (256 Hz / 12 ≈ 21/sec).
            while tp9Buffer.count >= eegWindowSize &&
                  af7Buffer.count >= eegWindowSize &&
                  af8Buffer.count >= eegWindowSize &&
                  tp10Buffer.count >= eegWindowSize {

                let tp9Window  = Array(tp9Buffer.prefix(eegWindowSize))
                let af7Window  = Array(af7Buffer.prefix(eegWindowSize))
                let af8Window  = Array(af8Buffer.prefix(eegWindowSize))
                let tp10Window = Array(tp10Buffer.prefix(eegWindowSize))

                tp9Buffer.removeFirst(eegWindowSize)
                af7Buffer.removeFirst(eegWindowSize)
                af8Buffer.removeFirst(eegWindowSize)
                tp10Buffer.removeFirst(eegWindowSize)

                // Emit one buffer at a time in the same sensor order used by legacy Muse:
                // 0 TP10, 1 AF8, 2 TP9, 3 AF7. XvMuse publishes after AF7.
                delegate?.didReceiveAthenaEEGBuffer(
                    packetIndex: packetIndex,
                    timestamp: timestamp,
                    sensor: 0,
                    samples: tp10Window
                )
                delegate?.didReceiveAthenaEEGBuffer(
                    packetIndex: packetIndex,
                    timestamp: timestamp,
                    sensor: 1,
                    samples: af8Window
                )
                delegate?.didReceiveAthenaEEGBuffer(
                    packetIndex: packetIndex,
                    timestamp: timestamp,
                    sensor: 2,
                    samples: tp9Window
                )
                delegate?.didReceiveAthenaEEGBuffer(
                    packetIndex: packetIndex,
                    timestamp: timestamp,
                    sensor: 3,
                    samples: af7Window
                )
            }
            
        case .accgyro:
            guard let rows = decodeAthenaAccGyro(dataBytes: dataBytes) else { return }
            if let last = rows.last {
                delegate?.didReceiveAthena(
                    accelPacket: MuseAccelPacket(
                        x: Double(last[0]),
                        y: Double(last[1]),
                        z: Double(last[2]),
                    )
                )
            }
            
        case .battery:
            //grab pct and send to main
            if let pct: Float = decodeAthenaBattery(dataBytes: dataBytes) {
                delegate?.didReceiveAthena(
                    batteryPacket: XvBatteryPacket(percentage: Int16(pct))
                )
            }
            
        case .optics:
            
            // Decode packed optics data (20-bit values)
            guard let cfg = Athena.sensors[tagByte] else { return }
            guard let rows = decodeAthenaOptics(dataBytes: dataBytes, nChannels: cfg.nChannels) else {
                print("ParserAthena: optics decode failed for tag \(tagByte)")
                return
            }
            
            //loop through samples in rows
            for (_, sample) in rows.enumerated() {
                
                
              //debuggingin console
                //let roundedSample = sample.map { Double(round($0 * 100) / 100) }
//                print(
//                    """
//                    Athena OPTICS:
//                      packetTimeSec: \(packetTimeSec)
//                      nChannels: \(cfg.nChannels)
//                      full sample: \(roundedSample)
//                    """
//                )
                
                if cfg.nChannels == 4 {
                    // sample is [ch0, ch1, ch2, ch3] each is a PPG
                    //Left Inner A, Right Inner A, Left Inner B, Right Inner B
                    let avgPPGSample:Double = (sample[0] + sample[1] + sample[2] + sample[3]) / 4.0

                    let ppgPacket:MusePPGPacket = MusePPGPacket(
                        packetIndex: UInt16(packetIndex),
                        sensor: 0,
                        timestamp: timestamp,
                        samples: [avgPPGSample]
                    )
                    
                    delegate?.didReceiveAthena(ppgPacket: ppgPacket)
                }
                
                
            }
            
        case .unknown:
            break
            //print("ParserAthena: Error: Unknown sensor type", sensorType)
        }
        
        
    }

    private func recordDiagnosticDrop(_ reason: String, offset: Int, detail: String) {
        diagnosticWindowDropCounts[reason, default: 0] += 1
        diagnosticDropTotals[reason, default: 0] += 1

        _ = offset
        _ = detail
    }

    private func emitDiagnosticSummaryIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - diagnosticWindowStartUptime
        guard elapsed >= 1.0 else { return }

        diagnosticWindowStartUptime = now
        diagnosticWindowNotifications = 0
        diagnosticWindowPackets = 0
        diagnosticWindowAcceptedPackets = 0
        diagnosticWindowRejectedPackets = 0
        diagnosticWindowEEGSamples = 0
        diagnosticWindowPacketIndexAnomalies = 0
        diagnosticWindowSubpacketIndexAnomalies = 0
        diagnosticWindowByte13Nonzero = 0
        diagnosticWindowIngressGaps = 0
        diagnosticWindowTagCounts.removeAll(keepingCapacity: true)
        diagnosticWindowDropCounts.removeAll(keepingCapacity: true)
    }

    private func diagnosticTag(_ tag: UInt8) -> String {
        String(format: "0x%02X", Int(tag))
    }
}
