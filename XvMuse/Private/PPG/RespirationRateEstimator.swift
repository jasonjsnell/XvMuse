//
//  RespirationRateEstimator.swift
//  XvMuse
//
//  Breaths per minute from the respiration waveform that RespiratorySignalProcessor
//  already extracts from the optical pulse. The waveform arrives band-passed and
//  normalized, so this stage only has to find breath peaks and time them.
//
//  Approach: keep a trailing 60 second window of the waveform, smooth it lightly,
//  find local maxima that clear a prominence floor and a 2 second refractory
//  (30 breaths/min ceiling), then report 60 / median peak-to-peak interval. The
//  median is deliberate: one missed or doubled peak shifts a mean badly but barely
//  moves a median.
//
//  Reports nil rather than a guess until there is enough signal, because a wrong
//  breath rate on a results chart is worse than a gap.
//

import Foundation

internal struct RespirationRateReading {
    ///Breaths per minute, or nil when the window is too short or too messy to trust.
    internal let rateBpm: Double?
    ///0-1. How much of the window produced usable, regularly spaced breaths.
    internal let quality: Double
}

internal class RespirationRateEstimator {

    //MARK: - Tuning

    ///Trailing window. Long enough to hold 3+ breaths at a slow 6 per minute.
    private let windowSeconds: Double = 60.0
    ///No reading until this much waveform has arrived.
    private let minimumSecondsForReading: Double = 30.0
    ///Fastest breathing we will report: 30 per minute means peaks 2 s apart.
    private let refractorySeconds: Double = 2.0
    ///Slowest believable breathing, used to reject absurd intervals: 4 per minute.
    private let maximumIntervalSeconds: Double = 15.0
    ///Need this many peaks before the intervals mean anything.
    private let minimumPeakCount: Int = 3
    ///Smoothing window for the waveform, in seconds. Kills sample-level jitter
    ///without touching the breath rhythm itself.
    private let smoothingSeconds: Double = 0.5
    ///A peak must rise this fraction of the window's peak-to-trough range above
    ///its neighbouring troughs to count.
    private let prominenceFraction: Double = 0.15

    //MARK: - State

    private var samples: [(t: Double, x: Double)] = []
    private var peakTimes: [Double] = []
    private var lastReading = RespirationRateReading(rateBpm: nil, quality: 0)

    //MARK: - Input

    ///One respiration waveform sample, with the device-clock time it arrived.
    ///Call once per appended sample; the estimator tracks its own effective rate,
    ///so it does not care that Athena feeds it faster than the legacy headsets.
    internal func add(sample: Double, atDeviceTime time: Double) {
        guard sample.isFinite, time.isFinite else { return }

        //out-of-order or repeated timestamps would corrupt the interval math
        if let last = samples.last, time <= last.t { return }

        samples.append((t: time, x: sample))
        trim(before: time - windowSeconds)
        recompute(now: time)
    }

    ///Latest reading. Safe to call at any cadence, including once per bundle.
    internal var current: RespirationRateReading { lastReading }

    ///Wipes the window. Call when the wearer changes or the stream is interrupted
    ///long enough that old breaths say nothing about the current ones.
    internal func reset() {
        samples.removeAll(keepingCapacity: true)
        peakTimes.removeAll(keepingCapacity: true)
        lastReading = RespirationRateReading(rateBpm: nil, quality: 0)
    }

    //MARK: - Estimation

    private func trim(before cutoff: Double) {
        if let firstKept = samples.firstIndex(where: { $0.t >= cutoff }), firstKept > 0 {
            samples.removeFirst(firstKept)
        }
        peakTimes.removeAll { $0 < cutoff }
    }

    private func recompute(now: Double) {
        guard let first = samples.first else { return }
        let span = now - first.t
        guard span >= minimumSecondsForReading, samples.count > 8 else {
            lastReading = RespirationRateReading(rateBpm: nil, quality: 0)
            return
        }

        let smoothed = smooth(samples)
        guard let range = amplitudeRange(smoothed), range > 0 else {
            //a flat line means no breathing signal, not slow breathing
            lastReading = RespirationRateReading(rateBpm: nil, quality: 0)
            return
        }

        peakTimes = findPeaks(in: smoothed, minimumProminence: range * prominenceFraction)
        guard peakTimes.count >= minimumPeakCount else {
            lastReading = RespirationRateReading(rateBpm: nil, quality: 0)
            return
        }

        //intervals between consecutive breaths, with impossible ones dropped
        var intervals: [Double] = []
        for index in 1..<peakTimes.count {
            let interval = peakTimes[index] - peakTimes[index - 1]
            if interval >= refractorySeconds, interval <= maximumIntervalSeconds {
                intervals.append(interval)
            }
        }
        guard intervals.count >= minimumPeakCount - 1 else {
            lastReading = RespirationRateReading(rateBpm: nil, quality: 0)
            return
        }

        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        guard median > 0 else {
            lastReading = RespirationRateReading(rateBpm: nil, quality: 0)
            return
        }
        let rate = 60.0 / median

        /* Quality has two halves, multiplied.
         Coverage: how much of the window the detected breaths actually span, so a
         burst of peaks in the last 10 s of a 60 s window is not passed off as a
         reading for the whole minute.
         Consistency: how tightly the intervals cluster around their median. Real
         breathing is regular; noise peaks are not. */
        let coverage = min(1.0, (peakTimes[peakTimes.count - 1] - peakTimes[0]) / span)
        let spread = sorted.map { abs($0 - median) / median }.reduce(0, +) / Double(sorted.count)
        let consistency = max(0.0, 1.0 - spread * 2.0)

        lastReading = RespirationRateReading(
            rateBpm: rate,
            quality: max(0.0, min(1.0, coverage * consistency))
        )
    }

    private func smooth(_ input: [(t: Double, x: Double)]) -> [(t: Double, x: Double)] {
        guard input.count > 2 else { return input }
        //estimate the sample rate from the window itself rather than assuming one
        let span = input[input.count - 1].t - input[0].t
        guard span > 0 else { return input }
        let sampleRate = Double(input.count - 1) / span
        let width = max(1, Int((smoothingSeconds * sampleRate).rounded()))
        guard width > 1, width < input.count else { return input }

        var output: [(t: Double, x: Double)] = []
        output.reserveCapacity(input.count)
        var runningSum = 0.0
        for index in 0..<input.count {
            runningSum += input[index].x
            if index >= width { runningSum -= input[index - width].x }
            let divisor = Double(min(index + 1, width))
            output.append((t: input[index].t, x: runningSum / divisor))
        }
        return output
    }

    private func amplitudeRange(_ input: [(t: Double, x: Double)]) -> Double? {
        guard let low = input.map(\.x).min(), let high = input.map(\.x).max() else { return nil }
        return high - low
    }

    private func findPeaks(in input: [(t: Double, x: Double)], minimumProminence: Double) -> [Double] {
        guard input.count > 4 else { return [] }
        var peaks: [Double] = []
        var lastPeakTime = -Double.greatestFiniteMagnitude
        var troughSinceLastPeak = input[0].x

        for index in 1..<(input.count - 1) {
            let value = input[index].x
            troughSinceLastPeak = min(troughSinceLastPeak, value)

            let isLocalMaximum = value >= input[index - 1].x && value > input[index + 1].x
            guard isLocalMaximum else { continue }
            guard value - troughSinceLastPeak >= minimumProminence else { continue }
            guard input[index].t - lastPeakTime >= refractorySeconds else { continue }

            peaks.append(input[index].t)
            lastPeakTime = input[index].t
            troughSinceLastPeak = value
        }
        return peaks
    }
}
