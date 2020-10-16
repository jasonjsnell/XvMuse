//
//  DCT.swift
//  XvMuse
//
//  Created by Jason Snell on 7/26/20.
//  Copyright © 2020 Jason Snell. All rights reserved.
//

import Foundation
import Accelerate

class DCT{
    
    fileprivate var _bins:Int
    
    fileprivate var forwardDCTSetup:vDSP.DCT
    //fileprivate var inverseDCTSetup:vDSP.DCT
    
    init(bins:Int) {
        
        self._bins = bins
        
        forwardDCTSetup = vDSP.DCT(
            count: _bins,
            transformType: vDSP.DCTTransformType.II
        )!
        
        
        /*inverseDCTSetup = vDSP.DCT(
            count: _bins,
            transformType: vDSP.DCTTransformType.III
        )!*/
    }
    
    public func transform(signal:[Double], threshold:Float! = nil) -> [Double] {
        
        //convert double to float array
        let floatSignal:[Float] = signal.map { Float($0) }
        
        //get forward cosine transform
        var forwardDCT:[Float] = forwardDCTSetup.transform(floatSignal)
        
        //Remove the noise from the signal by zeroing all values in the frequency domain data that are below a specified threshold.
        if (threshold != nil) {
            vDSP.threshold(forwardDCT,
                to: threshold!,
                with: .zeroFill,
                result: &forwardDCT)
        }
        
        let divisor:Float = Float(_bins)
        
        vDSP.divide(forwardDCT,
                    divisor,
                    result: &forwardDCT)
        
        return forwardDCT.map { Double($0) }
        
        /*
        //Use an inverse DCT to generate a new signal using the cleaned-up frequency domain data:
    
        var inverseDCT:[Float] = inverseDCTSetup.transform(forwardDCT)
        
        // Now scale the inverse DCT. The scaling factor for the forward transform is 2, and the scaling factor for the inverse transform is the number of samples (in this case, 1024). Use divide(_:_:) to divide the inverse DCT result by count / 2 to return a signal with the correct amplitude.
        
        let inverseDivisor:Float = Float(_bins / 2)
        
        vDSP.divide(inverseDCT,
                    inverseDivisor,
                    result: &inverseDCT)
        
        //convert array back into a double and return
        return inverseDCT.map { Double($0) }
        */
    }

}
