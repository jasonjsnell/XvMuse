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
        //validate incoming samples
        var samples:[Double] = validate(samples: samples)
        
        //validate length — the epoch is W long, not N; the padding is added below
        if (samples.count != W){
            print("FFT: Error: incoming epoch array does not have", W, "samples")
            return nil
        }
        
        //MARK: Remove mains hum
        if Self.removesMainsHum { removeMainsHum(from: &samples) }

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
        
        // Apply the window to incoming samples
        vDSP_vmulD(samples, 1, hammingWindow, 1, &samples, 1, UInt(samples.count))

        //zero-pad out to the FFT length. Zeros carry no energy, so the amplitude calibration
        //below stays anchored to the window rather than to N.
        if W < N {
            samples.append(contentsOf: [Double](repeating: 0.0, count: N - W))
        }
        
        
        // MARK: Create the split complex buffer
        
        // one for real numbers (x-axis)
        // and one for imaginary numbere (y-axis)
        var realComplexBuffer:[Double] = [Double](repeating: 0.0, count: N/2)
        var imagComplexBuffer:[Double] = [Double](repeating: 0.0, count: N/2)
        
        var splitComplex:DSPDoubleSplitComplex?

        //Safe way to create these is with buffer pointers
        realComplexBuffer.withUnsafeMutableBufferPointer { realBP in
            imagComplexBuffer.withUnsafeMutableBufferPointer { imagBP in
                
                splitComplex = DSPDoubleSplitComplex(realp: realBP.baseAddress!, imagp: imagBP.baseAddress!)
            }
        }
        
        if (splitComplex != nil) {
            
            //MARK: Real array to even-odd array
            // This formats the array for the FFT
        
            var valuesAsComplex:UnsafeMutablePointer<DSPDoubleComplex>? = nil
            
            samples.withUnsafeMutableBytes {
                valuesAsComplex = $0.baseAddress?.bindMemory(to: DSPDoubleComplex.self, capacity: N)
            }
            
            vDSP_ctozD(valuesAsComplex!, 2, &splitComplex!, 1, N2)

            // MARK: Perform forward FFT
            // The Accelerate FFT is packed, meaning that all FFT results after the frequency N/2 are automatically discarded
            // N bins becomes N/2 + 1 bins
            // 256 --> 128 + 1 = 129 bins
            vDSP_fft_zripD(fftSetup, &splitComplex!, 1, LOG_N, FFTDirection(FFT_FORWARD))
            
           
            
            // --- POWER SPECTRUM (one-sided), properly scaled ---
            // 1) Unscaled power = Re^2 + Im^2 per bin
            var power = [Double](repeating: 0.0, count: N/2)
            vDSP_zvmagsD(&splitComplex!, 1, &power, 1, N2)
            
            // 2) Normalize for FFT length (vDSP is unnormalized) and window coherent gain
            //scale against the WINDOW length, so a padded and an un-padded transform of the
            //same epoch report the same amplitude
            let nSquared = Double(W * W)
            let windowPow = coherentGain * coherentGain
            let baseScale = 1.0 / (nSquared * windowPow)
            vDSP.multiply(baseScale, power, result: &power)
            

            // 3) One-sided correction: double interior bins (keep DC at index 0 as-is)
            if N/2 > 1 {
                var interior = Array(power[1..<(N/2)])
                vDSP.multiply(2.0, interior, result: &interior)
                power.replaceSubrange(1..<(N/2), with: interior)
            }
            

            // 4) Save linear power and its dB view (10*log10(power))
            power = validate(samples: power)
            
            return FFTResult(
                sensor: fromSensor,
                power: power
            )
 
        } else {
            print("FFT: Error: Split Complex object is nil")
            return nil
        }
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
    private var humTables: [(cosine: [Double], sine: [Double])] = []

    private func removeMainsHum(from samples: inout [Double]) {
        let count = samples.count
        guard count > 16 else { return }
        if humTables.first?.cosine.count != count {
            humTables = Self.mainsHz.map { hz in
                let step = 2.0 * Double.pi * hz / XvMuseConstants.SAMPLING_RATE
                return (cosine: (0..<count).map { cos(step * Double($0)) },
                        sine: (0..<count).map { sin(step * Double($0)) })
            }
        }
        let mean = vDSP.mean(samples) //the fit ignores the signal's resting offset
        for table in humTables {
            //least squares: the amounts of cosine and sine that best match the epoch
            var cc = 0.0, ss = 0.0, cs = 0.0, xc = 0.0, xs = 0.0
            for index in 0..<count {
                let c = table.cosine[index], s = table.sine[index], x = samples[index] - mean
                cc += c * c; ss += s * s; cs += c * s
                xc += x * c; xs += x * s
            }
            let determinant = cc * ss - cs * cs
            guard abs(determinant) > 1e-9 else { continue }
            let a = (xc * ss - xs * cs) / determinant
            let b = (xs * cc - xc * cs) / determinant
            for index in 0..<count {
                samples[index] -= a * table.cosine[index] + b * table.sine[index]
            }
        }
    }

     //MARK: - HELPERS
    
    private func validate(samples:[Double]) -> [Double] {
        
        var validSamples:[Double] = samples
        
        //replace any NaN or infinite values with zero
        validSamples = validSamples.map {
            if ($0.isNaN || $0.isInfinite) { return 0 }
            return $0
        }
        
        return validSamples
    }
}
