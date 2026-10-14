//
//  FFTransformer.swift
//  XvFFT
//
//  Created by Jason Snell on 6/29/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//
// https://github.com/christopherhelf/Swift-FFT-Example/blob/master/ffttest/fft.swift


import Foundation
import Accelerate





class FFT {
    
    //MARK: - Vars
    
    // One-sided linear POWER per bin (|X[k]|^2), scaled for FFT length and window.
    public var power: [Double] = []
    
    private var fftSetup:FFTSetup
    
    private var N:Int
    private var W:Int   //real samples per epoch; N - W is zero-padding
    private var N2:UInt
    private var LOG_N:UInt
    
    private var hammingWindow:[Double] = []
    private var enbwBins: Double = 1.0 // ~1.36 for Hamming; 1.0 for rectangular
    
    // Coherent gain (sum(window)/N) and Equivalent Noise Bandwidth in bins
    private var coherentGain: Double = 1.0
    
    /* SCRATCH BUFFERS (13 Oct 2026). Owned by the instance and reused on every transform, so a
     transform no longer allocates the padded input, the split-complex pair and the power array,
     and no longer copies the epoch to validate it. One FFT object serves one queue
     (XvMuse.processingQ), so nothing contends for them. The maths runs in the same order on the
     same routines as before, so the spectrum is bit for bit what it was. */
    private var paddedInput:[Double]   // N: the validated, hum-cleaned, windowed epoch, then zeros
    private var realScratch:[Double]   // N/2
    private var imagScratch:[Double]   // N/2
    private var powerScratch:[Double]  // N/2

    
    
    //MARK: - Init
    
    /* `bins` is the FFT length; `windowLength` is how many real samples arrive.

     When windowLength < bins the incoming epoch is windowed at its own length and the remainder
     zero-padded, which interpolates the spectrum onto a finer frequency grid without changing
     how much time each estimate covers. Passing neither, or equal values, is the classic
     un-padded behaviour. */
    init(bins:Int, windowLength:Int? = nil){
        
        //size of the sample buffer that is being analyzed
        N = bins
        W = min(windowLength ?? bins, bins)
        
        //half of N, 128
        N2 = vDSP_Length(N/2)
        
        //log of N, 8
        LOG_N = vDSP_Length(log2(Double(N)))

        //set up FFT
        //The calls are expensive and should be performed rarely.
        fftSetup = vDSP_create_fftsetupD(LOG_N, FFTRadix(kFFTRadix2))!

        paddedInput = [Double](repeating: 0.0, count: N)
        realScratch = [Double](repeating: 0.0, count: N/2)
        imagScratch = [Double](repeating: 0.0, count: N/2)
        powerScratch = [Double](repeating: 0.0, count: N/2)
    }
    
    deinit {
        // destroy the fft setup object
        //The destroy calls are expensive and should be performed rarely.
        vDSP_destroy_fftsetupD(fftSetup)
    }
    
    //MARK: - FFT Processing
    public func transform(epoch:Epoch) -> FFTResult? {
        
        return transform(
            samples: epoch.samples,
            fromSensor: epoch.sensor
        )        
    }
    
    public func transform(samples:[Double], fromSensor:Int) -> FFTResult? {
        
        //MARK: Validation
        //validate length — the epoch is W long, not N; the padding is added below
        if (samples.count != W){
            print("FFT: Error: incoming epoch array does not have", W, "samples")
            return nil
        }
        
        //copy the epoch into the scratch input, replacing any NaN or infinite value with zero
        //(what validate() did on a copy of the array)
        paddedInput.withUnsafeMutableBufferPointer { input in
            samples.withUnsafeBufferPointer { source in
                for index in 0..<W {
                    let value = source[index]
                    input[index] = (value.isNaN || value.isInfinite) ? 0 : value
                }
            }
        }

        //MARK: Remove mains hum
        if Self.removesMainsHum { removeMainsHum(from: &paddedInput, count: W) }

        //MARK: Apply Hamming window
        
        //Muse docs: We use a Hamming window of 256 samples(at 220Hz),
        //init if empty
        if hammingWindow.isEmpty {
            
            //sized to the REAL samples, not the padded length — a window stretched across the
            //zeros would taper the actual data with the rising half of a longer curve
            hammingWindow = [Double](repeating: 0.0, count: W)
            
            //apply window
            vDSP_hamm_windowD(&hammingWindow, UInt(W), 0)
            
            // Precompute coherent gain and ENBW for the current window
            coherentGain = vDSP.sum(hammingWindow) / Double(W)
            let sumW2 = vDSP.sum(vDSP.multiply(hammingWindow, hammingWindow))
            enbwBins = (sumW2 / (coherentGain * coherentGain)) / Double(W) // ≈1.36 for Hamming
        }
        
        // Apply the window to the real samples in place, then zero-pad out to the FFT length.
        // Zeros carry no energy, so the amplitude calibration below stays anchored to the
        // window rather than to N.
        let realCount = W
        let paddedCount = N
        paddedInput.withUnsafeMutableBufferPointer { input in
            vDSP_vmulD(input.baseAddress!, 1, hammingWindow, 1, input.baseAddress!, 1, UInt(realCount))
            if realCount < paddedCount {
                for index in realCount..<paddedCount { input[index] = 0.0 }
            }
        }
        
        // 2) Normalize for FFT length (vDSP is unnormalized) and window coherent gain
        //scale against the WINDOW length, so a padded and an un-padded transform of the
        //same epoch report the same amplitude
        let nSquared = Double(W * W)
        let windowPow = coherentGain * coherentGain
        let baseScale = 1.0 / (nSquared * windowPow)
        let half = N / 2
            
        // MARK: Split complex, forward FFT, power spectrum
        // The pointers live only inside these closures (the old code kept them past the end of
        // the closure that made them).
        paddedInput.withUnsafeBufferPointer { input in
            realScratch.withUnsafeMutableBufferPointer { real in
                imagScratch.withUnsafeMutableBufferPointer { imag in
                    powerScratch.withUnsafeMutableBufferPointer { out in
        
                        // one for real numbers (x-axis) and one for imaginary numbers (y-axis)
                        var splitComplex = DSPDoubleSplitComplex(realp: real.baseAddress!, imagp: imag.baseAddress!)
            
                        //MARK: Real array to even-odd array
                        // This formats the array for the FFT
                        input.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self, capacity: half) { asComplex in
                            vDSP_ctozD(asComplex, 2, &splitComplex, 1, N2)
                        }

                        // MARK: Perform forward FFT
                        // The Accelerate FFT is packed, meaning that all FFT results after the frequency N/2 are automatically discarded
                        // N bins becomes N/2 + 1 bins
                        // 256 --> 128 + 1 = 129 bins
                        vDSP_fft_zripD(fftSetup, &splitComplex, 1, LOG_N, FFTDirection(FFT_FORWARD))

                        // --- POWER SPECTRUM (one-sided), properly scaled ---
                        // 1) Unscaled power = Re^2 + Im^2 per bin
                        vDSP_zvmagsD(&splitComplex, 1, out.baseAddress!, 1, N2)

                        // 2) scale (vDSP_vsmulD, as vDSP.multiply(scalar, vector) called before)
                        var scale = baseScale
                        vDSP_vsmulD(out.baseAddress!, 1, &scale, out.baseAddress!, 1, N2)

                        // 3) One-sided correction: double interior bins (keep DC at index 0 as-is).
                        // In place; multiplying by 2.0 is exact.
                        if half > 1 {
                            var two = 2.0
                            vDSP_vsmulD(out.baseAddress! + 1, 1, &two, out.baseAddress! + 1, 1, vDSP_Length(half - 1))
                        }

                        // 4) validate in place: any NaN or infinite bin becomes zero
                        for index in 0..<half {
                            let value = out[index]
                            if value.isNaN || value.isInfinite { out[index] = 0 }
                        }
                    }
                }
            }
        }
            
        /* NEW STORAGE ON EVERY TRANSFORM. XvEEG tells whether a sensor's spectrum changed by
         array identity (Swift's == takes an O(1) fast path when two arrays share a buffer), so
         the result must never alias the scratch buffer or a previous result. */
        let power = [Double](unsafeUninitializedCapacity: half) { buffer, initializedCount in
            initializedCount = 0
            guard half > 0, let destination = buffer.baseAddress else { return }
            powerScratch.withUnsafeBufferPointer { source in
                guard let origin = source.baseAddress else { return }
                destination.initialize(from: origin, count: half)
                initializedCount = half
            }
        }

        return FFTResult(
            sensor: fromSensor,
            power: power
        )
    }
    
    //MARK: - MAINS HUM

    /* A NOTCH AT 50 AND 60 Hz (30 Sep 2026). A body near anything plugged in picks up the
     wall socket's hum, and on the raw signal it can be a hundred times larger than the
     brainwaves. The spectrum stops at 47 Hz, but the Hamming window lets a tone that
     large leak into the bins just under it: on 30 Sep 2026 touching a laptop sent the
     gamma score from 0 to 80 with 50 Hz at 99% of the raw signal.

     So before the window, each epoch has its 50 Hz and its 60 Hz tone measured (the best
     fitting sine and cosine at exactly that frequency) and subtracted. Unlike a running
     filter this has no memory and no ringing: every epoch is treated by itself, and an
     epoch with no hum has almost nothing taken from it. Both frequencies are always
     removed, so it works in any country without a setting.

     What it cannot do: bring back a signal the hum has already pushed into the
     amplifier's ceiling. Set false to switch it off. */
    public static var removesMainsHum = true
    private static let mainsHz: [Double] = [50.0, 60.0]

    /* One tone's tables plus the sums that depend only on the tables (13 Oct 2026). cc, ss, cs
     and the determinant used to be re-summed on every epoch; they are summed once here, in
     the same index order the per-epoch loop used, so the values are identical. */
    private struct HumTable {
        let cosine: [Double]
        let sine: [Double]
        let cc: Double
        let ss: Double
        let cs: Double
        let determinant: Double
    }
    private var humTables: [HumTable] = []

    //operates on the first `count` entries of `buffer` (the real samples ahead of the padding)
    private func removeMainsHum(from buffer: inout [Double], count: Int) {
        guard count > 16, count <= buffer.count else { return }
        if humTables.first?.cosine.count != count {
            humTables = Self.mainsHz.map { hz in
                let step = 2.0 * Double.pi * hz / XvMuseConstants.SAMPLING_RATE
                let cosine = (0..<count).map { cos(step * Double($0)) }
                let sine = (0..<count).map { sin(step * Double($0)) }
                var cc = 0.0, ss = 0.0, cs = 0.0
                for index in 0..<count {
                    let c = cosine[index], s = sine[index]
                    cc += c * c; ss += s * s; cs += c * s
                }
                return HumTable(cosine: cosine, sine: sine, cc: cc, ss: ss, cs: cs, determinant: cc * ss - cs * cs)
            }
        }
        //the fit ignores the signal's resting offset (vDSP_meanvD, as vDSP.mean called before)
        var mean = 0.0
        buffer.withUnsafeBufferPointer { p in
            vDSP_meanvD(p.baseAddress!, 1, &mean, vDSP_Length(count))
        }
        for table in humTables {
            guard abs(table.determinant) > 1e-9 else { continue }
            //least squares: the amounts of cosine and sine that best match the epoch
            var xc = 0.0, xs = 0.0
            for index in 0..<count {
                let c = table.cosine[index], s = table.sine[index], x = buffer[index] - mean
                xc += x * c; xs += x * s
            }
            let a = (xc * table.ss - xs * table.cs) / table.determinant
            let b = (xs * table.cc - xc * table.cs) / table.determinant
            for index in 0..<count {
                buffer[index] -= a * table.cosine[index] + b * table.sine[index]
            }
        }
    }
}
