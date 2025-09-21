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
    private var N2:UInt
    private var LOG_N:UInt
    
    private var hammingWindow:[Double] = []
    private var enbwBins: Double = 1.0 // ~1.36 for Hamming; 1.0 for rectangular
    
    // Coherent gain (sum(window)/N) and Equivalent Noise Bandwidth in bins
    private var coherentGain: Double = 1.0
    
    
    
    //MARK: - Init
    
    init(bins:Int){
        
        //size of the sample buffer that is being analyzed
        N = bins
        
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
        
        //validate length
        if (samples.count != N){
            print("FFT: Error: incoming epoch array does not have", N, "samples")
            return nil
        }
        
        //MARK: Apply Hamming window
        
        //Muse docs: We use a Hamming window of 256 samples(at 220Hz),
        //init if empty
        if hammingWindow.isEmpty {
            
            //init empty container
            hammingWindow = [Double](repeating: 0.0, count: N)
            
            //apply window
            vDSP_hamm_windowD(&hammingWindow, UInt(N), 0)
            
            // Precompute coherent gain and ENBW for the current window
            coherentGain = vDSP.sum(hammingWindow) / Double(N)
            let sumW2 = vDSP.sum(vDSP.multiply(hammingWindow, hammingWindow))
            enbwBins = (sumW2 / (coherentGain * coherentGain)) / Double(N) // ≈1.36 for Hamming
        }
        
        // Apply the window to incoming samples
        vDSP_vmulD(samples, 1, hammingWindow, 1, &samples, 1, UInt(samples.count))
        
        
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
            let nSquared = Double(N * N)
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
