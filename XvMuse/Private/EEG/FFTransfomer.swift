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
    
    public var magnitudes:[Double] = []
    public var decibels:[Double] = []
    
    fileprivate var fftSetup:FFTSetup
    fileprivate var N:Int
    fileprivate var N2:UInt
    fileprivate var LOG_N:UInt
    fileprivate var hammingWindow:[Double] = []
    
    
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
    public func transform(epoch:Epoch, noiseFloor:Double? = nil) -> FFTResult? {
        
        return transform(
            samples: epoch.samples,
            fromSensor: epoch.sensor,
            noiseFloor: noiseFloor
        )        
    }
    
    public func transform(samples:[Double], fromSensor:Int, noiseFloor:Double? = nil) -> FFTResult? {
        
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
            hammingWindow = [Double](repeating: 0.0, count: N)
            vDSP_hamm_windowD(&hammingWindow, UInt(N), 0)
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
            
            //init array
            magnitudes = [Double](repeating: 0.0, count: N/2)
            
            //Sample-Hold
            //https://github.com/Sample-Hold/SimpleSpectrumAnalyzer
            
            //MARK: Calculate amplitude
            vDSP_zvabsD(&splitComplex!, 1, &magnitudes, 1, N2)
            // Note: same as vDSP.absolute(splitComplex!, result: &magnitudes) https://stackoverflow.com/questions/60120842/how-to-use-apples-accelerate-framework-in-swift-in-order-to-compute-the-fft-of
            //print("MAG:", magnitudes[64])
            //range: 0-250,000
            //average: 300-400
            
            //remove signals underneath the incoming noise flood value
            if (noiseFloor != nil) {
                vDSP.threshold(
                    magnitudes,
                    to: noiseFloor!,
                    with: .zeroFill,
                    result: &magnitudes
                )
            }
            
            
            //validate
            magnitudes = validate(samples: magnitudes)
            
            //magnitude processing stops here. It's the raw, absolulte FFT values
            //init decibels with the value of the magnitudes, and process this var through the following functions
            decibels = magnitudes
            
            
            vDSP_vsdivD(decibels, 1, [Double(N/2)], &decibels, 1, N2);
            //print("DIV:", magnitudes[64])
            //range: 0-1500
            //average: 2-3
            
            
            //MARK: Convert to DB
            // Converts amplitude values to decibel values
            //Muse docs: Each array contains 129 decimal values with a range of roughly -40.0 to 20.0.
            
            vDSP_vdbconD(decibels, 1, [Double(1)], &decibels, 1, N2, 1);
        
            // db correction considering window
            var fGainOffset:Double = 1.0 //kHammingFactor
            vDSP_vsaddD(decibels, 1, &fGainOffset, &decibels, 1, N2);
            
            //print("DB :", magnitudes[64])
            //range: -52 to 64
            //average: -1 to 1 or 2
            
            decibels = validate(samples: decibels)
            
            return FFTResult(
                sensor: fromSensor,
                magnitudes: magnitudes,
                decibels: decibels
            )
 
        } else {
            print("FFT: Error: Split Complex object is nil")
            return nil
        }
    }
    
     //MARK: - HELPERS
    
    /*fileprivate func _average(_ x:[Double]) -> [Double] {
        
        let sum = x.reduce(0, +)
        let averageValue:Double = Double(sum) / Double(x.count)
        return x.map { $0-averageValue }
    }*/
    
    fileprivate func validate(samples:[Double]) -> [Double] {
        
        var validSamples:[Double] = samples
        
        //replace any NaN or infinite values with zero
        validSamples = validSamples.map {
            if ($0.isNaN || $0.isInfinite) { return 0 }
            return $0
        }
        
        return validSamples
    }
}

