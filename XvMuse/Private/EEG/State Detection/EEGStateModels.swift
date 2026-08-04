//
//  EEGStateModels.swift
//  XvMuse
//

import Foundation

//MARK: - DETAIL WINDOW MEASUREMENTS -

/* Three independent descriptions of one detail-window spectrum.

 Treat the spectrum as a distribution of energy across frequency, then take its moments:
   centroidHz - the balance point. Where the energy sits on the slow-to-fast scale.
   spreadHz   - the width. Is it one organized peak, or smeared across the whole band?
   logPower   - the total mass that got divided out. How much energy there is.
   rhythmicityDb - how much the strongest flattened peak rises above the local mean.
   alphaPaceHz - the strongest 7-13 Hz alpha peak available inside the detail spectrum.

 Centroid and spread describe shape and ignore volume; logPower describes volume and ignores
 shape. That independence is the point: three genuinely separate axes, unlike relative band
 powers which are forced to sum to 1 and therefore cannot move independently. */

struct DetailFeatures {
    let centroidHz: Double
    let spreadHz: Double
    let logPower: Double
    let rhythmicityDb: Double
    let alphaPaceHz: Double
    let timestamp: Date
}

//MARK: - FULL SPECTRUM BAND BALANCE -

/* The five band levels in dB, taken from the full spectrum rather than the detail window.

 Used by the state scorer when a state needs band relationships outside the detail window,
 especially theta for dreamy. Because these are all dB, comparing two of them is a ratio:
 it says which band is louder and by how much, regardless of overall signal strength. */

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
 states in question; practically, EMG smears energy across the spectrum, so a reading taken
 during a clench is not trustworthy anyway.

 Ramped rather than switched at a threshold, so scores ease down instead of stepping. */

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
