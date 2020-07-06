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


/*
 
 process()
 .magnitudes
 .decibels
 
 */

class FFTransformer {
    
    //MARK: - Vars
    
    public var magnitudes:[Float] = []
    public var decibels:[Float] = []
    
    fileprivate var fftSetup:FFTSetup
    fileprivate var N:Int
    fileprivate var N2:UInt
    fileprivate var LOG_N:UInt
    fileprivate var hammingWindow:[Float] = []
    
    
    //MARK: - Init
    
    init(){
        
        //size of the sample buffer that is being analyzed
        N = XvMuseConstants.FFT_BINS
        
        //half of N, 128
        N2 = vDSP_Length(N/2)
        
        //log of N, 8
        LOG_N = vDSP_Length(log2(Float(N)))

        //set up FFT
        //The calls are expensive and should be performed rarely.
        fftSetup = vDSP_create_fftsetup(LOG_N, FFTRadix(kFFTRadix2))!
    }
    
    deinit {
        // destroy the fft setup object
        //The destroy calls are expensive and should be performed rarely.
        vDSP_destroy_fftsetup(fftSetup)
    }
    
    //MARK: - FFT Processing
    
    public func transform(epoch:Epoch) -> FFTResult? {
        
        //MARK: Validation
        //validate incoming samples
        var samples:[Float] = validate(samples: epoch.samples)
        
        
        //MARK: Apply Hamming window
        
        //Muse docs: We use a Hamming window of 256 samples(at 220Hz),
        //init if empty
        if hammingWindow.isEmpty {
            hammingWindow = [Float](repeating: 0.0, count: N)
            vDSP_hamm_window(&hammingWindow, UInt(N), 0)
        }
        
        // Apply the window to incoming samples
        vDSP_vmul(samples, 1, hammingWindow, 1, &samples, 1, UInt(samples.count))
        
        
        // MARK: Create the split complex buffer
        
        // one for real numbers (x-axis)
        // and one for imaginary numbere (y-axis)
        var realComplexBuffer:[Float] = [Float](repeating: 0.0, count: N/2)
        var imagComplexBuffer:[Float] = [Float](repeating: 0.0, count: N/2)
        
        var splitComplex:DSPSplitComplex?

        //Safe way to create these is with buffer pointers
        realComplexBuffer.withUnsafeMutableBufferPointer { realBP in
            imagComplexBuffer.withUnsafeMutableBufferPointer { imagBP in
                
                splitComplex = DSPSplitComplex(realp: realBP.baseAddress!, imagp: imagBP.baseAddress!)
            }
        }
        
        if (splitComplex != nil) {
            
            //MARK: Real array to even-odd array
            // This formats the array for the FFT
            
            var valuesAsComplex:UnsafeMutablePointer<DSPComplex>? = nil
            
            samples.withUnsafeMutableBytes {
                valuesAsComplex = $0.baseAddress?.bindMemory(to: DSPComplex.self, capacity: N)
            }
            
            vDSP_ctoz(valuesAsComplex!, 2, &splitComplex!, 1, N2)

            // MARK: Perform forward FFT
            // The Accelerate FFT is packed, meaning that all FFT results after the frequency N/2 are automatically discarded
            // N bins becomes N/2 + 1 bins
            // 256 --> 128 + 1 = 129 bins
            vDSP_fft_zrip(fftSetup, &splitComplex!, 1, LOG_N, FFTDirection(FFT_FORWARD))
            
            //print("")
            magnitudes = [Float](repeating: 0.0, count: N/2)
            
            //Sample-Hold
            //https://github.com/Sample-Hold/SimpleSpectrumAnalyzer
            
            //MARK: Calculate amplitude
            vDSP_zvabs(&splitComplex!, 1, &magnitudes, 1, N2)
            // Note: same as vDSP.absolute(splitComplex!, result: &magnitudes) https://stackoverflow.com/questions/60120842/how-to-use-apples-accelerate-framework-in-swift-in-order-to-compute-the-fft-of
            //print("MAG:", magnitudes[64])
            //range: 0-250,000
            //average: 300-400
            
            //magnitude processing stops here. It's the raw, absolulte FFT values
            //init decibels with the value of the magnitudes, and process this var through the following functions
            decibels = magnitudes
            
            
            vDSP_vsdiv(decibels, 1, [Float(N/2)], &decibels, 1, N2);
            //print("DIV:", magnitudes[64])
            //range: 0-1500
            //average: 2-3
            
            
            //MARK: Convert to DB
            // Converts amplitude values to decibel values
            //Muse docs: Each array contains 129 decimal values with a range of roughly -40.0 to 20.0.
            
            vDSP_vdbcon(decibels, 1, [Float(1)], &decibels, 1, N2, 1);
        
            // db correction considering window
            var fGainOffset:Float = 1.0 //kHammingFactor
            vDSP_vsadd(decibels, 1, &fGainOffset, &decibels, 1, N2);
            
            //print("DB :", magnitudes[64])
            //range: -52 to 64
            //average: -1 to 1 or 2
            
            return FFTResult(
                sensor: epoch.sensor,
                magnitudes: magnitudes,
                decibels: decibels
            )
 
        } else {
            print("FFT: Error: Split Complex object is nil")
            return nil
        }
    }
    
     //MARK: - HELPERS
    
    /*fileprivate func _average(_ x:[Float]) -> [Float] {
        
        let sum = x.reduce(0, +)
        let averageValue:Float = Float(sum) / Float(x.count)
        return x.map { $0-averageValue }
    }*/
    
    fileprivate func validate(samples:[Float]) -> [Float] {
        
        var validSamples:[Float] = samples
        
        //validate length
        if (samples.count != N){
            print("FFT: Error: incoming array does not have", N, "samples")
            return []
        }
        
        //replace any NaN or infinite values with zero
        validSamples = validSamples.map {
            if ($0.isNaN || $0.isInfinite) { return 0 }
            return $0
        }
        
        return validSamples
    }
}

