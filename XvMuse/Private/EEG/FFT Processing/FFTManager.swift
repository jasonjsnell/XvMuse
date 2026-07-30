//
//  FFT.swift
//  FFT
//
//  Created by Jason Snell on 6/24/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation

/*

Each time the Muse headband fires off an EEG sensor update (order is: tp10 af8 tp9 af7),
the XvMuse class puts that data into XvMuseEEGPackets
and sends it here to create a streaming buffer, slice out epoch windows, and return Fast Fourier Transformed array of frequency data
       
       ch1     ch2     ch3     ch4  < EEG sensors tp10 af8 tp9 af7
                       ---     ---
0:00    p       p     | p |   | p | < XvMuseEEGPacket is one packet of a 12 sample EEG reading, index, timestamp, channel ID
0:01    p       p     | p |    ---
0:02    p       p     | p |     p
0:03    p       p     | p |     p
0:04    p       p     | p |     p
0:05    p       p     | p |     p
                       ___

                        ^ DataBuffer of streaming samples. Each channel has it's own buffer

*/

 // Flow: Packet --> Buffer --> Epoch --> FFT

/* A circular, updating stream of samples (each sensor has it's own sample array). It includes a corresponding timestamp array, which has fewer slots, since there is one timestamp per every 12 samples. This stream is produced by the Buffer object */

public struct DataStream {
    
    public init(sensor: Int, samplesCapacity: Int, timestampsCapacity: Int) {
        self.sensor = sensor
        self.samples = RingBuffer<Double>(capacity: samplesCapacity)
        self.timestamps = RingBuffer<Double>(capacity: timestampsCapacity)
    }
    
    public var samplesArray: [Double] { samples.toArray() }
    public var timestampsArray: [Double] { timestamps.toArray() }
    
    public var sensor:Int // same as data packet
    public var samples:RingBuffer<Double> // streaming samples of EEG sensor data
    public var timestamps:RingBuffer<Double> //series of recent timestamps
}

/* This is a snapshot of data from the data stream, containing values in a specific window of time. This object is released from the Epoch Manager every X milliseconds and has a bin length equal to the Buffer */

public struct Epoch {
    public var sensor:Int // same as data stream
    public var samples:[Double] = [] // X amount of EEG samples in a specific window of time
}

/* This stores the different FFT result arrays, including magnitudes (above zero, absolute values) and decibels (which the Muse SDK outputs) */

public struct FFTResult {
    public var sensor: Int // same as epoch / channel id
    public var power: [Double] // One-sided linear POWER per bin (|X[k]|^2), scaled for FFT length and window.
}

/* Holds the parallel FFT outputs from the same epoch:
   full = unfiltered full-window spectrum, detail = 5-20 Hz pre-filtered spectrum. */
public struct FFTResultSet {
    public var sensor: Int
    public var full: FFTResult?
    public var detail: FFTResult?
}


public class FFTManager {
    
    /* Instead of doing 2D arrays of 256 samples for each sensor, I'm optmizing the FFT processing by resuing the Epoch Generator and FFT Transformer for all data. The Buffers needs one object per sensor because it is storing an ongoing stream of data from each sensor. The epoch generator is just one object, but has an array of start times, since that's the only var that needs to be sensor-specific. And the FFT transformer processes different data each func call, with no data persisting inbetween calls, so I'm using one object to process the data of all the sensors (they all take turns sending in and processing their samples, getting their returned FFT data) */
    
    private var _buffers:[Buffer] = []
    private var _epochGenerator:EpochGenerator = EpochGenerator()
    private lazy var _fullFFT: FFT = FFT(bins: MuseConstants.EEG_FFT_BINS)
    private lazy var _detailFFT: FFT = FFT(bins: MuseConstants.EEG_FFT_BINS)
    private var _detailFilters:[FFTFilter] = []
    
    internal init() {
        
        //safey check, make sure bin size is power of 2
        precondition(MuseConstants.EEG_FFT_BINS.nonzeroBitCount == 1, "EEG_FFT_BINS must be power-of-two for vDSP")
        
        for i in 0..<MuseConstants.EEG_SENSOR_TOTAL {
            _buffers.append(Buffer(sensor:i))
            _detailFilters.append(
                FFTFilter(
                    sampleRate: MuseConstants.SAMPLING_RATE,
                    lowCutHz: MuseConstants.DETAIL_BANDPASS_LOW_HZ,
                    highCutHz: MuseConstants.DETAIL_BANDPASS_HIGH_HZ
                )
            )
        }
    }
    
    //An eeg data packet is sent in from the XvMuse class
    internal func process(eegPacket:MuseEEGPacket) -> FFTResultSet? {
        
        //make sure this is one of the main 4 sensors (2 forehead, 2 ears, not an AUX)
        let s = eegPacket.sensor
            guard (0..<MuseConstants.EEG_SENSOR_TOTAL).contains(s) else {
                print("Muse: FFTManager - Unknown sensor index: \(s), perhaps an AUX sensor.")
                return nil
            }
        
        // once the buffer is full (it needs a few seconds of data before it can provide a stream)...
        if let dataStream:DataStream = _buffers[eegPacket.sensor].add(packet: eegPacket) {
            
            //send the data stream to the epoch manager
            
            //once the epoch interval is complete...
            if let epoch:Epoch = _epochGenerator.getEpoch(from: dataStream) {
                
                // Full Window: current unfiltered spectrum.
                let fullResult:FFTResult? = _fullFFT.transform(epoch: epoch)

                // Detail Window: forehead-only AF8/AF7 branch, filtered before FFT.
                let detailResult:FFTResult?
                if MuseConstants.DETAIL_EEG_SENSOR_IDS.contains(epoch.sensor) {
                    let detailEpoch:Epoch = _detailFilters[epoch.sensor].process(epoch: epoch)
                    detailResult = _detailFFT.transform(epoch: detailEpoch)
                } else {
                    detailResult = nil
                }

                if fullResult != nil || detailResult != nil {
                    return FFTResultSet(
                        sensor: epoch.sensor,
                        full: fullResult,
                        detail: detailResult
                    )
                }
            }// else {
               // print("epoch error")
            //}
        } //else {
            //print("data stream error")
        //}
        
        return nil
    }
}

final class FFTFilter {
    private let coefficients:[Double]

    init(sampleRate:Double, lowCutHz:Double, highCutHz:Double, tapCount:Int = 101) {
        let oddTapCount = tapCount % 2 == 0 ? tapCount + 1 : tapCount
        coefficients = FFTFilter.makeBandPassCoefficients(
            sampleRate: sampleRate,
            lowCutHz: lowCutHz,
            highCutHz: highCutHz,
            tapCount: oddTapCount
        )
    }

    func process(epoch:Epoch) -> Epoch {
        Epoch(
            sensor: epoch.sensor,
            samples: process(samples: epoch.samples)
        )
    }

    private func process(samples:[Double]) -> [Double] {
        guard !samples.isEmpty else { return [] }

        let half = coefficients.count / 2
        var output:[Double] = Array(repeating: 0.0, count: samples.count)

        for i in 0..<samples.count {
            var y = 0.0
            for tap in 0..<coefficients.count {
                let sampleIndex = i + tap - half
                guard sampleIndex >= 0 && sampleIndex < samples.count else { continue }
                y += samples[sampleIndex] * coefficients[tap]
            }
            output[i] = y
        }

        return output
    }

    private static func makeBandPassCoefficients(
        sampleRate:Double,
        lowCutHz:Double,
        highCutHz:Double,
        tapCount:Int
    ) -> [Double] {
        let low = max(0.0, min(lowCutHz, sampleRate / 2.0))
        let high = max(low, min(highCutHz, sampleRate / 2.0))
        let middle = tapCount / 2

        var coeffs:[Double] = []
        coeffs.reserveCapacity(tapCount)

        for n in 0..<tapCount {
            let m = Double(n - middle)
            let ideal:Double
            if m == 0.0 {
                ideal = 2.0 * (high - low) / sampleRate
            } else {
                ideal = (
                    sin(2.0 * .pi * high * m / sampleRate) -
                    sin(2.0 * .pi * low * m / sampleRate)
                ) / (.pi * m)
            }

            let window = 0.54 - (0.46 * cos(2.0 * .pi * Double(n) / Double(tapCount - 1)))
            coeffs.append(ideal * window)
        }

        return normalize(coefficients: coeffs, sampleRate: sampleRate, centerHz: (low + high) / 2.0)
    }

    private static func normalize(coefficients:[Double], sampleRate:Double, centerHz:Double) -> [Double] {
        let middle = coefficients.count / 2
        var real = 0.0
        var imag = 0.0

        for n in 0..<coefficients.count {
            let m = Double(n - middle)
            let phase = -2.0 * .pi * centerHz * m / sampleRate
            real += coefficients[n] * cos(phase)
            imag += coefficients[n] * sin(phase)
        }

        let gain = sqrt((real * real) + (imag * imag))
        guard gain > 1e-9 else { return coefficients }
        return coefficients.map { $0 / gain }
    }
}
