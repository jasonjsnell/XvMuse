//
//  EEGStateModels.swift
//  XvMuse
//

import Foundation

//MARK: - DETAIL WINDOW MEASUREMENTS -

/* Three independent descriptions of one detail-window spectrum.

 Treat the spectrum as a distribution of energy across frequency, then take its moments:
   centroidHz - the balance point. WHERE the energy sits on the slow-to-fast scale.
   spreadHz   - the width. Is it one organized peak, or smeared across the whole band?
   logPower   - the total mass that got divided out. HOW MUCH energy there is.

 Centroid and spread describe shape and ignore volume; logPower describes volume and ignores
 shape. That independence is the point: three genuinely separate axes, unlike relative band
 powers which are forced to sum to 1 and therefore can't move independently. */

struct DetailFeatures {
    let centroidHz: Double
    let spreadHz: Double
    let logPower: Double
    let timestamp: Date
}

//MARK: - FULL SPECTRUM BAND BALANCE -

/* The five band levels in dB, taken from the full spectrum rather than the detail window.

 Used only for dreamy, which depends on theta — and theta sits below the detail window's 8 Hz
 floor, so it is simply not there to measure. Because these are all dB, comparing two of them is
 a ratio: it says which band is louder and by how much, regardless of overall signal strength.
 That is what lets dreamy work with no baseline at all, and therefore from the first second. */

struct BandBalance {
    let delta: Double
    let theta: Double
    let alpha: Double
    let beta: Double
    let gamma: Double

    /* Overall stillness across the whole bandwidth, 0-100, ungated. Not a band level — it rides
     along because dreamy needs it as a credibility check. Broadband noise is loud everywhere at
     once, which drives this down, so a low value means the band comparisons above are probably
     describing interference rather than a brain. */
    let quiet: Double
}

//MARK: - RELAXED STATE GATE -

/* Muscle tension scales down the states that claim deep relaxation — dreamy and quiet.

 Two things justify it at once. Physiologically, a clenched jaw or braced forehead rules out the
 states in question; this is the "orientation and relaxation" layer that has to come down before
 anything else is meaningful. And practically, EMG smears energy across the spectrum, so a
 reading taken during a clench is not trustworthy anyway.

 Deliberately NOT applied for blinks, despite them being the other big artifact:
   - dreamy already collapses on a blink by itself, because a blink drives delta above theta and
     that comparison carries 40% of the score. Penalising it again would count it twice.
   - drowsiness comes WITH slow eye movement rather than without it — it is one of the classic
     markers of sleep onset. Suppressing dreamy on eye activity would fight the real signal.
   - blinking is normal and constant. Anything that punished it would make quiet unreachable for
     anyone behaving like a human being.

 Ramped rather than switched at a threshold, so scores ease down instead of stepping. Chronic
 low-level tension is handled upstream: the spike detector measures against a drifting floor, so
 a permanently tight jaw settles into the floor and reads near zero, and only active clenching
 climbs into this ramp. */

enum RelaxedStateGate {

    static let tensionOnset: Double = 30.0
    static let tensionFull: Double = 80.0

    //never quite zero, so the display keeps showing a live value rather than flatlining
    static let floor: Double = 0.15

    static func damping(forTension tension: Double) -> Double {
        let span = max(tensionFull - tensionOnset, 1e-6)
        let amount = min(max((tension - tensionOnset) / span, 0.0), 1.0)
        return 1.0 - (amount * (1.0 - floor))
    }
}

//MARK: - PROGRESSIVE BASELINE -

/* A running mean and standard deviation that is usable from the very first sample.

 Samples carry a weight, so early readings (when electrode contact is still settling) can be
 counted for less without being thrown away. The standard deviation is blended against a prior,
 which is what makes a one-sample baseline safe: with no evidence yet the prior supplies the
 spread, and as real observations accumulate they take over. Scores are therefore available
 immediately and simply get more accurate, rather than being withheld until a timer expires. */

struct WeightedStat {

    private(set) var totalWeight: Double = 0
    private(set) var mean: Double = 0
    private var sumSquares: Double = 0

    var hasData: Bool { totalWeight > 0 }

    //West's weighted incremental variance
    mutating func add(_ value: Double, weight: Double) {
        guard weight > 0, value.isFinite else { return }
        totalWeight += weight
        let deltaFromOldMean = value - mean
        mean += (weight / totalWeight) * deltaFromOldMean
        sumSquares += weight * deltaFromOldMean * (value - mean)
    }

    mutating func reset() {
        totalWeight = 0
        mean = 0
        sumSquares = 0
    }

    /* Observed spread pulled toward a prior. priorWeight is expressed in the same units as the
     accumulated sample weight, so it behaves like "this many samples' worth of assumption". */
    func standardDeviation(priorSD: Double, priorWeight: Double) -> Double {
        guard totalWeight > 0 else { return max(priorSD, 1e-6) }
        let observedVariance = sumSquares / totalWeight
        let blended =
            ((priorWeight * priorSD * priorSD) + (totalWeight * observedVariance)) /
            (priorWeight + totalWeight)
        return max(sqrt(max(0, blended)), 1e-6)
    }

    //how far this value sits from normal, in personal standard deviations
    func z(_ value: Double, priorSD: Double, priorWeight: Double) -> Double {
        guard totalWeight > 0 else { return 0 }
        return (value - mean) / standardDeviation(priorSD: priorSD, priorWeight: priorWeight)
    }
}

//MARK: - ARCHIVED -
/* Everything below supported the previous band-ratio state detection (see
 LegacyEEGStateAnalyzer / LegacyEEGStateScorer). Kept so that code still compiles and can be
 referred back to; nothing in the live path uses it. */

enum BaselinePhase {
    case idle
    case warmup
    case collecting
    case locked
}

struct EpochRel {
    let delta: Double
    let theta: Double
    let alpha: Double
    let beta: Double
    let gamma: Double
    let faa: Double?
    let timestamp: Date
}

struct EpochZ {
    let zDelta: Double
    let zTheta: Double
    let zAlpha: Double
    let zBeta: Double
    let faaShift: Double?
    let timestamp: Date
}

struct LiveBandSample {
    let delta: Double
    let theta: Double
    let alpha: Double
    let beta: Double
    let gamma: Double
    let timestamp: Date
}
