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

 Centroid and spread describe shape and ignore volume; logPower describes volume and ignores
 shape. That independence is the point: three genuinely separate axes, unlike relative band
 powers which are forced to sum to 1 and therefore cannot move independently. */

struct DetailFeatures {
    let centroidHz: Double
    let spreadHz: Double
    let logPower: Double
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

    /* Overall stillness across the whole bandwidth, 0-100, ungated. Not a band level, and no
     longer a gate on anything — see the note on dreamy in EEGStateScorer. Kept because it is
     still published and still useful to read in the diagnostic log. */
    let quiet: Double

    /* The unscaled trimmed-mean dB behind `quiet`, carried through so the log can show it next to
     the percentage it produced. Scores nothing — it exists to make the calibration measurable
     rather than guessable, since `quiet` itself clips at both ends. */
    let quietDb: Double

    //MARK: - 1/f detrended residuals

    /* Each band's level minus what the 1/f slope alone predicts for it, in dB.

     WHY THIS EXISTS. Brain signals are big-and-slow / small-and-fast: power falls off roughly as
     1/f^2. Across delta (2.4 Hz) to beta (20 Hz) that is about 18 dB of tilt present in every
     recording, awake or asleep, brain or artifact. So comparing raw band levels does not ask
     "which rhythm is dominant" — it asks "which band sits lowest in frequency", and delta wins
     that by construction.

     Measured on a real session: raw `alpha - strongest rival` never once exceeded -2.3 dB across
     81 frames, so a gate opening at -2.0 could not fire in ANY frame. Not rare. Impossible. The
     same held for theta once smoothed. Both meditation and dreamy were structurally pinned at 0.

     Fitting log-power against log-frequency and subtracting the fit removes that built-in tilt.
     What is left is the part of each band that is not explained by the background slope — an
     actual oscillation. Because the fit is recomputed per frame from that frame's own bands, it
     is a within-instant ratio: no baseline, no reference period, and a naturally strong-alpha
     person reads high from the first second.

     GAMMA IS EXCLUDED from the fit. Real EEG is not a single power law all the way up; the
     aperiodic slope flattens above roughly 30 Hz, so one line fitted through gamma over-predicts
     how far gamma should have fallen and gamma then shows a large positive residual in almost
     every frame. On the session above, including gamma made it the "winning" band in 46% of
     frames — that is EMG and the slope model failing, not a brain rhythm. Gamma stays available
     as a raw level for noise work; it takes no part in the state comparisons. */

    let deltaResidual: Double
    let thetaResidual: Double
    let alphaResidual: Double
    let betaResidual: Double

    /* Geometric band centres, from the XvEEG bandRanges (delta 2...3, theta 4...7, alpha 8...12,
     beta 14...30). Geometric rather than arithmetic because for a 1/f^2 spectrum the average power
     across [a,b] works out to 1/(ab), whose equivalent single frequency is exactly sqrt(ab). */
    private static let deltaCentreHz = (2.0 * 3.0).squareRoot()
    private static let thetaCentreHz = (4.0 * 7.0).squareRoot()
    private static let alphaCentreHz = (8.0 * 12.0).squareRoot()
    private static let betaCentreHz  = (14.0 * 30.0).squareRoot()

    init(delta: Double, theta: Double, alpha: Double, beta: Double, gamma: Double, quiet: Double, quietDb: Double) {
        self.delta = delta
        self.theta = theta
        self.alpha = alpha
        self.beta = beta
        self.gamma = gamma
        self.quiet = quiet
        self.quietDb = quietDb

        let levels = [delta, theta, alpha, beta]
        let logFreqs = [
            log10(Self.deltaCentreHz),
            log10(Self.thetaCentreHz),
            log10(Self.alphaCentreHz),
            log10(Self.betaCentreHz)
        ]

        guard levels.allSatisfy({ $0.isFinite }) else {
            deltaResidual = 0
            thetaResidual = 0
            alphaResidual = 0
            betaResidual = 0
            return
        }

        let n = Double(levels.count)
        let meanLogF = logFreqs.reduce(0, +) / n
        let meanLevel = levels.reduce(0, +) / n

        var covariance = 0.0
        var varianceF = 0.0
        for i in 0..<levels.count {
            let dF = logFreqs[i] - meanLogF
            covariance += dF * (levels[i] - meanLevel)
            varianceF += dF * dF
        }

        let slope = varianceF > 1e-12 ? (covariance / varianceF) : 0.0
        func residual(_ i: Int) -> Double {
            (levels[i] - meanLevel) - (slope * (logFreqs[i] - meanLogF))
        }

        deltaResidual = residual(0)
        thetaResidual = residual(1)
        alphaResidual = residual(2)
        betaResidual  = residual(3)
    }

    /* How far alpha stands above the best of the other three, after detrending.

     Alpha sits almost exactly on the regression's pivot (its log-frequency is within 0.02 of the
     mean of the four), which means an error in the fitted slope barely moves alpha's residual at
     all. That makes this the most robust of the four comparisons — a useful accident. */
    var alphaLeadDb: Double {
        alphaResidual - max(max(deltaResidual, thetaResidual), betaResidual)
    }

    /* Theta measured against the alpha-beta trend alone — NOT the same construction as alphaLead,
     and delta's absence is the whole point.

     The residual version required theta to out-shout delta, which is physically backwards for the
     state dreamy detects: sleep onset is diffuse slowing, so delta rises WITH theta — and on the
     frontal pair, slow eye rolls under closed lids land squarely in the delta band while sitting
     below the blink detector's 2-4 Hz window. Worse, a delta surge rotated the shared 1/f fit,
     crashing theta's residual and inflating beta's in the same frame — one artifact corrupted
     every term of the score at once. Measured on a real drifting-asleep Athena session: the old
     metric held at -1.5 dB (gate shut, dreamy 0) for the entire session; this one holds at +2.2.

     So the fast side gets to define the trend: a line through alpha and beta (in log-frequency),
     extrapolated down to theta's centre, and theta's height above that line is the lead. Alert
     spectra put theta 2.5-4 dB BELOW the line, so the sign flips cleanly between states. A
     two-point extrapolation is noisier frame to frame than the fitted version — the scorer's
     multi-second smoothing is what makes it usable, and matters more now, not less.

     ALPHA IS IN THE TREND ON PURPOSE, unlike delta. Strong alpha lifts the line and suppresses
     this lead, so alpha-rich (early, eyes-closed) drowsiness reads as meditation rather than
     dreamy. That is the intended division of labour, not a side effect — see the note above
     scoreDreamy in EEGStateScorer for the evidence and the decision. */
    var thetaLeadDb: Double {
        let logThetaF = log10(Self.thetaCentreHz)
        let logAlphaF = log10(Self.alphaCentreHz)
        let logBetaF = log10(Self.betaCentreHz)
        let slope = (beta - alpha) / (logBetaF - logAlphaF)
        let predictedTheta = alpha + slope * (logThetaF - logAlphaF)
        return theta - predictedTheta
    }
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
