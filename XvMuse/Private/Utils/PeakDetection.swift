//
//  PeakDetection.swift
//  XvMuse
//
//  https://stackoverflow.com/questions/43583302/peak-detection-for-growing-time-series-using-swift/43607179#43607179
//  Created by Jean Paul
//  https://stackoverflow.com/users/2431885/jean-paul
//  Edited by Jason Snell on 10/16/20

import Foundation

/*
public class PeakDetection {
    
    public init(){
        
        
    }
    
    // Smooth z-score thresholding filter
    func ThresholdingAlgo(y: [Double], lagMean: Int, lagStd: Int, threshold: Double, influenceMean: Double, influenceStd: Double) -> ([Int],[Double],[Double]) {

        // Create arrays
        var signals   = Array(repeating: 0, count: y.count)
        var filteredYmean = Array(repeating: 0.0, count: y.count)
        var filteredYstd = Array(repeating: 0.0, count: y.count)
        var avgFilter = Array(repeating: 0.0, count: y.count)
        var stdFilter = Array(repeating: 0.0, count: y.count)

        // Initialise variables
        for i in 0...lagMean-1 {
            signals[i] = 0
            filteredYmean[i] = y[i]
            filteredYstd[i] = y[i]
        }

        // Start filter
        avgFilter[lagMean-1] = arithmeticMean(array: subArray(array: y, s: 0, e: lagMean-1))
        stdFilter[lagStd-1] = standardDeviation(array: subArray(array: y, s: 0, e: lagStd-1))

        for i in max(lagMean,lagStd)...y.count-1 {
            if abs(y[i] - avgFilter[i-1]) > threshold*stdFilter[i-1] {
                if y[i] > avgFilter[i-1] {
                    signals[i] = 1      // Positive signal
                } else {
                    signals[i] = -1       // Negative signal
                }
                filteredYmean[i] = influenceMean*y[i] + (1-influenceMean)*filteredYmean[i-1]
                filteredYstd[i] = influenceStd*y[i] + (1-influenceStd)*filteredYstd[i-1]
            } else {
                signals[i] = 0          // No signal
                filteredYmean[i] = y[i]
                filteredYstd[i] = y[i]
            }
            // Adjust the filters
            avgFilter[i] = arithmeticMean(array: subArray(array: filteredYmean, s: i-lagMean, e: i))
            stdFilter[i] = standardDeviation(array: subArray(array: filteredYstd, s: i-lagStd, e: i))
        }

        return (signals,avgFilter,stdFilter)
    }
    
    //MARK: - Helpers -
    // Function to calculate the arithmetic mean
    fileprivate func arithmeticMean(array:[Double]) -> Double {
        
        let total:Double = array.reduce(0, +)
        return total / Double(array.count)
    }
    
    // Function to calculate the standard deviation
    fileprivate func standardDeviation(array:[Double]) -> Double {
        
        let length:Double = Double(array.count)
        let avg:Double = array.reduce(0, {$0 + $1}) / length
        let sumOfSquaredAvgDiff:Double = array.map { pow($0 - avg, 2.0)}.reduce(0, {$0 + $1})
        return sqrt(sumOfSquaredAvgDiff / length)
    }
    
    // Function to extract some range from an array
    fileprivate func subArray<T>(array: [T], s: Int, e: Int) -> [T] {
        if e > array.count {
            return []
        }
        return Array(array[s..<min(e, array.count)])
    }
    
}
*/
