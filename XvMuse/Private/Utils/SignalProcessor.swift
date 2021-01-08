
//  SignalProcessor.swift
//  XvDataMapping
//
//  https://stackoverflow.com/questions/43583302/peak-detection-for-growing-time-series-using-swift/43607179#43607179
//  Created by Jean Paul
//  https://stackoverflow.com/users/2431885/jean-paul
//  Edited by Jason Snell on 10/16/20

import Foundation

public class SignalProcessorPacket {
    
    init(raw:[Double], averagedValues:[Double], deviationValues:[Double], peaks:[Int]) {
        self.raw = raw
        self.averagedValues = averagedValues
        self.deviationValues = deviationValues
        self.peaks = peaks
    }
    public let raw:[Double]
    public let peaks:[Int]
    public let averagedValues:[Double]
    public let deviationValues:[Double]
    
}

public class SignalProcessor {
    
    fileprivate let _bins:Int
    fileprivate var _peaks:[Int] = []
    fileprivate var _filteredYavg:[Double] = []
    fileprivate var _filteredYdev:[Double] = []
    fileprivate var _avgFilter:[Double] = []
    fileprivate var _devFilter:[Double] = []
    fileprivate var _buffer:[Double] = []
    
    public init(
        bins:Int,
        threshold:Double,
        lag:Int,
        influence:Double
    ) {
        
        //capture vars
        _bins = bins
        _threshold = threshold
        _averagingLag = lag
        _deviationLag = lag
        _averagingInfluence = influence
        _deviationInfluence = influence
        
        _initArrays()
    }
    
    public init(
        bins:Int,
        threshold:Double,
        averagingLag:Int,
        deviationLag:Int,
        averagingInfluence:Double,
        deviationInfluence:Double
    ){
        
        //capture vars
        _bins = bins
        _threshold = threshold
        _averagingLag = averagingLag
        _deviationLag = deviationLag
        _averagingInfluence = averagingInfluence
        _deviationInfluence = deviationInfluence
        
        _initArrays()
    }
    
    
    
    //MARK: - Process value
    //process one value at a time
    //this adds to buffer, then buffer is passed into the peak detection method
    public func process(value:Double) -> SignalProcessorPacket? {
        
        //build buffer
        _buffer.append(value)
        
        //trim buffer
        if (_updateBuffer()){
            
            //then detect peaks
            return _process(rawSamples: _buffer)
        }
        
        return nil
    }
    
    //MARK: Process packet
    //this is a small array of several values, often used in device communication
    //this adds to buffer, then buffer is passed into the peak detection method
    public func process(packet:[Double]) -> SignalProcessorPacket? {
        
        //append entire packet
        _buffer += packet
        
        //trim buffer
        if (_updateBuffer()){
            
            //then detect peaks
            return _process(rawSamples: _buffer)
        }
        
        return nil
    }
    
    //MARK: Process signal
    //this is an array the same length as the bins
    public func process(stream:[Double]) -> SignalProcessorPacket? {
        
        //MARK: Error checking
        //data set needs to match bin length
        if (stream.count != _bins){
            print("SignalProcessor: Error: Data set length", stream.count, "doesn't match bin length", _bins)
        
        } else {
            
            //assign entire array to buffer
            _buffer = stream
            
            //check the buffer for errors
            if (_updateBuffer()) {
                return _process(rawSamples: stream)
            
            }
        }
        
        return nil
    }
    
    
    //MARK: - Peak detection -
    
    fileprivate func _process(rawSamples:[Double]) -> SignalProcessorPacket? {

        //grab count
        let N:Int = rawSamples.count
        
        //MARK: Compare lagtime and buffer length
        //buffer needs to be bigger than the lag times
        if (_averagingLag > N || _deviationLag > N){
            return nil
        }
        
        // MARK: Examination range
        // copy raw data from oldest part of buffer into filteredY arrays
        // the average and deviation will be calculated from this section of the data
        for i in 0..._averagingLag-1 {
            _filteredYavg[i] = rawSamples[i]
        }
        for i in 0..._deviationLag-1 {
            _filteredYdev[i] = rawSamples[i]
        }

        //MARK: Filters - first bin
        // Calcuate first bin of filters by getting the average and deviation from the examination range
        _avgFilter[_averagingLag-1] = getMedian(
            array: subArray(array: rawSamples, s: 0, e: _averagingLag-1)
        )
        
        _devFilter[_deviationLag-1] = getMeanAbsoluteDeviation(
            array: subArray(array: rawSamples, s: 0, e: _deviationLag-1)
        )
        
        //loop from the highest lag value to the end of the raw samples
        for i in max(_averagingLag,_deviationLag)...N-1 {
            
            //if absolute difference between the raw data and the avg filter
            //is more than the threshold x the deviation filter
            if ( abs(rawSamples[i] - _avgFilter[i-1]) > _threshold * _devFilter[i-1] ) {
                
                //if difference is postive...
                if ( rawSamples[i] > _avgFilter[i-1] ) {
                    _peaks[i] = 1  // then peak is positive
                } else {
                    _peaks[i] = -1 // else peak is negative
                }
                
                //populate filtered y's by adding the raw sample x influence, and the previous filtered y x influence
                _filteredYavg[i] = (_averagingInfluence * rawSamples[i]) + ((1-_averagingInfluence) * _filteredYavg[i-1])
                
                _filteredYdev[i] = (_deviationInfluence * rawSamples[i]) + ((1-_deviationInfluence) * _filteredYdev[i-1])
                
            } else {
                
                //else the raw data didn't break past the calculated threshold
                _peaks[i] = 0     //so no peak
                
                // make the filtered arrays the raw data
                _filteredYavg[i] = rawSamples[i]
                _filteredYdev[i] = rawSamples[i]
            }
            
            /* Update the filters with the newly transformed filter array values, getting the average and deviation calculations from a moving window that trails behind the i value
            */
            
            _avgFilter[i] = getMedian(
                array: subArray(array: _filteredYavg, s: i-_averagingLag, e: i)
            )
            
            _devFilter[i] = getMeanAbsoluteDeviation(
                array: subArray(array: _filteredYdev, s: i-_deviationLag, e: i)
            )
        }
        
        
        
        //package the peaks, averaged filter, and deviation filter
        return SignalProcessorPacket(
            raw: rawSamples,
            averagedValues: _avgFilter,
            deviationValues: _devFilter,
            peaks: _peaks
        )
    }
    
    //MARK: - Helpers -
    // Function to calculate the arithmetic mean
    fileprivate func getMean(array:[Double]) -> Double {
        
        let total:Double = array.reduce(0, +)
        return total / Double(array.count)
    }
    
    fileprivate func getMedian(array: [Double]) -> Double {
        
        let sorted:[Double] = array.sorted()
        if (sorted.count % 2 != 0) {
            return Double(sorted[sorted.count / 2])
        } else {
            return Double(sorted[sorted.count / 2] + sorted[sorted.count / 2 - 1]) / 2.0
        }
    }
    
    // Function to calculate the standard deviation
    fileprivate func getStandardDeviation(array:[Double]) -> Double {
        
        let length:Double = Double(array.count)
        let avg:Double = array.reduce(0, {$0 + $1}) / length
        let sumOfSquaredAvgDiff:Double = array.map { pow($0 - avg, 2.0)}.reduce(0, {$0 + $1})
        return sqrt(sumOfSquaredAvgDiff / length)
    }
    
    fileprivate func getMeanAbsoluteDeviation(array:[Double]) -> Double {
        
        //get mean of the array
        let mean:Double = getMean(array: array)
        
        //calculate distance between each number in area from the mean
        //but make all values positive (absolute value)
        let absoluteDeviations:[Double] = array.map { abs($0-mean) }
        
        //get the average (mean) absolute deviation
        return absoluteDeviations.reduce(0, +) / Double(absoluteDeviations.count)
    }
    
    // Function to extract some range from an array
    fileprivate func subArray<T>(array: [T], s: Int, e: Int) -> [T] {
        if e > array.count {
            return []
        }
        return Array(array[s..<min(e, array.count)])
    }
    
    fileprivate func _updateBuffer() -> Bool{
        
        if (_buffer.count < _bins) {
            print("SignalProcessor: Building buffer", _buffer.count, "/", _bins)
            return false
        }
        
        //if signal goes above bin length
        if (_buffer.count > _bins) {
            
            //remove the excess from the beginning of the array
            _buffer.removeFirst(_buffer.count-_bins)
        }
        
        //remove nans
        _buffer = _buffer.map { $0.isNaN ? 0 : $0 }
        
        return true
    }
    
    fileprivate func _initArrays(){
        
        //buffer starts empty
        _buffer = []
        
        //analysis arrays start flat
        _peaks = Array(repeating: 0, count: _bins)
        _filteredYavg = Array(repeating: 0.0, count: _bins)
        _filteredYdev = Array(repeating: 0.0, count: _bins)
        _avgFilter = Array(repeating: 0.0, count: _bins)
        _devFilter = Array(repeating: 0.0, count: _bins)
        
        //error checking
        if (_averagingLag > _bins || _deviationLag > _bins) {
            print("SignalProcessor: Error: Lags (", _averagingLag, _deviationLag, ") can't be more than the bin length", _bins)
            fatalError()
        }
    }
    
    //MARK: - Acccessors -

    fileprivate var _threshold:Double
    public var threshold:Double {
        get { return _threshold }
        set { _threshold = newValue }
    }
    
    fileprivate var _averagingLag:Int
    public var averagingLag:Int {
        get { return _averagingLag }
        set { _averagingLag = newValue }
    }
    
    fileprivate var _deviationLag:Int
    public var deviationLag:Int {
        get { return _deviationLag }
        set { _deviationLag = newValue }
    }
    
    fileprivate var _averagingInfluence:Double
    public var averagingInfluence:Double {
        get { return _averagingInfluence }
        set { _averagingInfluence = newValue }
    }
    
    fileprivate var _deviationInfluence:Double
    public var deviationInfluence:Double {
        get { return _deviationInfluence }
        set { _deviationInfluence = newValue }
    }
}



