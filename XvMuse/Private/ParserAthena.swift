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
             ├─ subpkt_index: Per-sensor-type sequence counter (0-255, wraps)
             ├─ Unknown bytes: 3 metadata bytes (purpose unknown)
             └─ Sensor data: Variable length depending on sensor type

 Timestamp Calculation & Device Timing:
 ---------------------------------------
 Device timestamps (pkt_time) are derived from a 256 kHz hardware clock with 3.906 µs resolution.
 Multiple packets often share identical pkt_time values (~11-30% are duplicates).

 Timestamp generation per message:
   1. Sort packets by (pkt_time, pkt_index, subpkt_index)
      - pkt_index: Packet sequence counter (0-255), ensures correct ordering of duplicates
      - Analysis: 100% sequential in duplicate groups (1871/1871 tested)
   2. Use first packet's pkt_time as anchor
   3. Generate uniform timestamps: anchor + (sample_index / sampling_rate)

 Hardware Timing Artifacts:
   - ~4% of pkt_time values have timing inversions (timestamps go backwards)
   - pkt_index remains sequential (100% accurate for packet order)
   - Inversions likely due to async sensor buffering and clock jitter
   - Final monotonicity ensured by stream.py buffering/sorting before LSL output
 */

import XvSensors

public protocol ParserAthenaDelegate:AnyObject {
    func didReceiveAthena(accelPacket:XvAccelPacket)
    func didReceiveAthena(batteryPacket:XvBatteryPacket)
    func didReceiveAthenaEEGSampleBuffers(
        tp9: [Float],
        af7: [Float],
        af8: [Float],
        tp10: [Float]
    )
}

class ParserAthena {
    
    init(){}
    public weak var delegate:ParserAthenaDelegate?
    
    
    // Buffer one shared EEG window size, mirroring legacy Muse
    private let eegWindowSize = 12
    
    // Per-channel EEG buffers
    private var tp9Buffer:  [Float] = []
    private var af7Buffer:  [Float] = []
    private var af8Buffer:  [Float] = []
    private var tp10Buffer: [Float] = []
    
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
        
        // TAG / pkt_id config (mirrors Python SENSORS dict)
        static let sensors: [UInt8: AthenaSensorConfig] = [
            0x11: .init(type: .eeg,     nChannels: 4,  nSamples: 4, rate: 256.0, dataLen: 28),
            0x12: .init(type: .eeg,     nChannels: 8,  nSamples: 2, rate: 256.0, dataLen: 28),
            0x34: .init(type: .optics,  nChannels: 4,  nSamples: 3, rate:  64.0, dataLen: 30),
            0x35: .init(type: .optics,  nChannels: 8,  nSamples: 2, rate:  64.0, dataLen: 40),
            0x36: .init(type: .optics,  nChannels: 16, nSamples: 1, rate:  64.0, dataLen: 40),
            0x47: .init(type: .accgyro, nChannels: 6,  nSamples: 3, rate:  52.0, dataLen: 36),
            0x53: .init(type: .unknown, nChannels: 0,  nSamples: 0, rate:   0.0, dataLen: 24),
            0x98: .init(type: .battery, nChannels: 1,  nSamples: 1, rate:   1.0, dataLen: 20),
        ]
        
        // scales
        static let eegScale: Double = 1450.0 / 16383.0
        static let accScale: Float  = 0.0000610352
        static let gyroScale: Float = -0.0074768
        static let opticsScale: Float = 1.0 / 32768.0
    }
    
    func handleAthenaMain(bytes: [UInt8], systemTimestamp: Double) {
        var offset = 0
        let count = bytes.count
        
        while offset < count {
            // Need at least a header
            guard offset + Athena.packetHeaderSize <= count else { break }
            
            let pktLen = Int(bytes[offset]) // first byte = declared packet length
            
            guard pktLen > 0, offset + pktLen <= count else { break }
            
            let pktBytes = Array(bytes[offset ..< offset + pktLen])
            
            // Parse header
            let pktIndex: UInt8 = pktBytes[1]
            let pktTimeRaw = UInt32(pktBytes[2])
                | (UInt32(pktBytes[3]) << 8)
                | (UInt32(pktBytes[4]) << 16)
                | (UInt32(pktBytes[5]) << 24)
            let pktTimeSec = Double(pktTimeRaw) / Athena.deviceClockHz
            
            // Unknown1: bytes[6...8]
            // pkt_id: sensor type for the first subpacket
            let pktId: UInt8 = pktBytes[9]
            let pktConfig = Athena.sensors[pktId]
            let pktType = pktConfig?.type
            // Unknown2: bytes[10...12]
            let byte13: UInt8 = pktBytes[13]
            
            let pktValid = (pktType != nil
                            && byte13 == 0
                            && pktLen >= Athena.packetHeaderSize)
            
            let dataSection: [UInt8]
            if pktBytes.count > Athena.packetHeaderSize {
                dataSection = Array(pktBytes[Athena.packetHeaderSize ..< pktBytes.count])
            } else {
                dataSection = []
            }
            
            // Now parse subpackets within this packet
            parseAthenaDataSubpackets(
                pktValid: pktValid,
                pktType: pktType,
                pktId: pktId,
                pktConfig: pktConfig,
                pktIndex: pktIndex,
                pktTimeRaw: pktTimeRaw,
                pktTimeSec: pktTimeSec,
                data: dataSection,
                systemTimestamp: systemTimestamp
            )
            
            offset += pktLen
        }
    }
    
    private func parseAthenaDataSubpackets(
        pktValid: Bool,
        pktType: AthenaSensorType?,
        pktId: UInt8,
        pktConfig: AthenaSensorConfig?,
        pktIndex: UInt8,
        pktTimeRaw: UInt32,
        pktTimeSec: Double,
        data: [UInt8],
        systemTimestamp: Double
    ) {
        var offset = 0
        let count = data.count
       
        // 1. First subpacket: raw data only, type = pktType, length from pktConfig.dataLen
        if pktValid, let type = pktType, let cfg = pktConfig {
            let len = cfg.dataLen
            if len > 0, offset + len <= count {
                let firstDataBytes = Array(data[offset ..< offset + len])
                handleAthenaSubpacket(
                    sensorType: type,
                    tagByte: pktId,
                    subpktIndex: nil,
                    dataBytes: firstDataBytes,
                    pktIndex: pktIndex,
                    pktTimeRaw: pktTimeRaw,
                    pktTimeSec: pktTimeSec,
                    systemTimestamp: systemTimestamp
                )
                offset += len
            }
        }
        
        // 2. Additional subpackets: TAG + 4-byte header + data
        while offset + Athena.subpacketHeaderSize <= count {
            let tagByte = data[offset]
            
            guard let cfg = Athena.sensors[tagByte] else {
                // Unknown tag → stop parsing this packet
                break
            }
            
            let dataLen = cfg.dataLen
            if dataLen == 0 { break }
            
            // Make sure we have header + data
            guard offset + Athena.subpacketHeaderSize + dataLen <= count else { break }
            
            let subpktIndex = data[offset + 1]
            // bytes [offset+2 ..< offset+5] are "unknown" metadata
            
            let start = offset + Athena.subpacketHeaderSize
            let end = start + dataLen
            let dataBytes = Array(data[start ..< end])
            
            handleAthenaSubpacket(
                sensorType: cfg.type,
                tagByte: tagByte,
                subpktIndex: subpktIndex,
                dataBytes: dataBytes,
                pktIndex: pktIndex,
                pktTimeRaw: pktTimeRaw,
                pktTimeSec: pktTimeSec,
                systemTimestamp: systemTimestamp
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
                
                // Decode and rescale to roughly match the legacy 0.48828125 factor
                let scaled = Double(intValue) * Athena.eegScale
                rows[sampleIdx][chIdx] = Float(scaled)
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
        subpktIndex: UInt8?,
        dataBytes: [UInt8],
        pktIndex: UInt8,
        pktTimeRaw: UInt32,
        pktTimeSec: Double,
        systemTimestamp: Double
    ) {
        switch sensorType {
            
        case .eeg:
            guard let cfg = Athena.sensors[tagByte] else { return }
            guard let rows = decodeAthenaEEG(dataBytes: dataBytes, nChannels: cfg.nChannels) else { return }
            
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
            
            // When we have enough samples, emit a window per channel
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
                
                delegate?.didReceiveAthenaEEGSampleBuffers(
                    tp9: tp9Window,
                    af7: af7Window,
                    af8: af8Window,
                    tp10: tp10Window
                )
            }
            
        case .accgyro:
            guard let rows = decodeAthenaAccGyro(dataBytes: dataBytes) else { return }
            if let last = rows.last {
                delegate?.didReceiveAthena(
                    accelPacket: XvAccelPacket(
                        x: Double(last[0]),
                        y: Double(last[1]),
                        z: Double(last[2])
                    )
                )
            }
            
        case .battery:
            if let pct: Float = decodeAthenaBattery(dataBytes: dataBytes) {
                delegate?.didReceiveAthena(
                    batteryPacket: XvBatteryPacket(percentage: Int16(pct))
                )
            }
            
        case .optics, .unknown:
            break
        }
    }
}
