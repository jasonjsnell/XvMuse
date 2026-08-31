//
//  EEGStateScorer.swift
//  XvMuse
//

import Foundation

/* Turns live spectrum measurements into three state scores, 0-100.

 Quiet is not here; it stays an absolute low-activity reading across the whole bandwidth,
 computed in XvEEGAnalysis. */

final class EEGStateScorer {

    private(set) var meditationScore: Double = 0.0
    private(set) var focusScore: Double = 0.0
    private(set) var dreamyScore: Double = 0.0

    /* Last breakdown of each score, for diagnostics only. Each state is gate × support, so the
     log needs both: a low score with a healthy gate means the support was weak, while a zero gate
     means the defining evidence was simply absent. */
    private(set) var focusGate: Double = 0.0
    private(set) var focusSupport: Double = 0.0
    private(set) var medGate: Double = 0.0
    private(set) var medSupport: Double = 0.0
    private(set) var dreamyGate: Double = 0.0
    private(set) var dreamyCredibility: Double = 0.0
    private(set) var dreamySupport: Double = 0.0

    private(set) var focusBroadEnough: Double = 0.0
    private(set) var focusHoldingSteady: Double = 0.0
    private(set) var focusFastCentroid: Double = 0.0
    private(set) var focusCalmCentroid: Double = 0.0
    private(set) var focusNotAlphaLed: Double = 1.0

    /* The RAW Hz numbers behind the focus gates, exposed for tuning.

     The gate values alone cannot tell you where to put a threshold — a fast term reading 0.51 is
     consistent with many different centroid positions depending on where the ramp anchors sit.
     These are the actual measured offsets from the window's null, which is what the FAST TILT and
     BROAD keys are expressed in, so a log carrying them can be read straight off into new values. */
    private(set) var focusTiltOffsetHz: Double = 0.0
    private(set) var focusSpreadOffsetHz: Double = 0.0
    private(set) var focusAlphaLeadDb: Double = 0.0
    private(set) var focusNullCentroidHz: Double = 0.0
    private(set) var meditationAlphaLeadDb: Double = 0.0
    private(set) var meditationAlphaCentroid: Double = 0.0
    private(set) var meditationOrganized: Double = 0.0
    private(set) var meditationHoldingSteady: Double = 0.0
    private(set) var meditationAwakeEnough: Double = 1.0
    private(set) var dreamyThetaLeadDb: Double = 0.0
    private(set) var dreamySmoothedThetaLeadDb: Double = 0.0
    private(set) var dreamyThetaVsFastDb: Double = 0.0
    private(set) var dreamyClearOfFastBands: Double = 0.0
    private(set) var dreamyStillnessPresent: Double = 0.0
    private(set) var dreamyThetaVsDeltaDb: Double = 0.0
    private(set) var dreamyCalmLowEnd: Double = 0.0
    private(set) var dreamyNotRunningFast: Double = 1.0
    private(set) var dreamyLooksLikeRhythm: Double = 1.0
    private(set) var dreamyThetaProminenceDb: Double = 0.0
    //how far the window centroid sits above its 1/f null, in Hz — the raw number behind
    //dreamyNotRunningFast, and the one term that separates drowsy theta from concentration theta
    private(set) var dreamyTiltOffsetHz: Double = 0.0
    private(set) var dreamyCalmGamma: Double = 1.0
    private(set) var dreamyGammaDb: Double = 0.0

    //MARK: - Window reference

    /* What the detail window's centroid and spread read when the spectrum has NO structure in it
     at all — just the 1/f background. Supplied by EEGStateAnalyzer, which derives both from
     whichever bins actually survived the filter-response cut.

     Every centroid and spread threshold below is an OFFSET from these, never an absolute Hz.
     That is what makes them survive a change to the detail window. When the window was widened
     from 10-20 to 8-20 the featureless centroid moved from 13.86 Hz to 12.22 Hz — with absolute
     thresholds, every one of them silently became wrong by 1.6 Hz. The 11.5-14.5 focus ramp had
     already drifted that way: on a 10-20 window it scored a completely featureless spectrum at
     0.79, so focus was mostly measuring the window rather than the brain. */
    private var nullCentroidHz: Double = 12.22
    private var nullSpreadHz: Double = 3.27

    func configureWindow(nullCentroidHz: Double, nullSpreadHz: Double) {
        guard nullCentroidHz.isFinite, nullSpreadHz.isFinite, nullSpreadHz > 0 else { return }
        self.nullCentroidHz = nullCentroidHz
        self.nullSpreadHz = nullSpreadHz
    }

    //MARK: - Tunables

    /* Focus has two valid shapes:
       - fast focus: centroid pulled ABOVE the featureless null, i.e. real high-frequency weight
       - calm focus: a steady, broad, slightly-slow centroid, common for a meditator doing
         engaged reading/coding without much high-beta strain.

     Both are offsets in Hz from nullCentroidHz. Fast focus needs the centroid to have actually
     moved up; sitting at the null earns 0.20, not 0.79. */
    var focusTiltOffsetLowHz: Double = -0.5
    var focusTiltOffsetHighHz: Double = 2.0
    var calmFocusTiltOffsetHz: Double = -1.5
    var calmFocusTiltRadiusHz: Double = 1.4

    /* How long theta has to keep leading before dreamy believes it. At the 0.25s publish cadence
     0.04 works out to roughly a 6 second memory — long enough to reject isolated blips, short
     enough to follow a genuine slide into drowsiness. */
    var thetaLeadSmoothing: Double = 0.04
    private var smoothedThetaLead: Double = 0.0

    /* The same lead, over a much shorter memory — roughly 1.5 s at the 0.25 s publish cadence,
     against 6 s for the persistence gate above.

     Not instantaneous, which is what it used to be. Since thetaLeadDb became a two-point
     extrapolation it swings +-9 dB frame to frame, and feeding that straight into a ramp turned
     the gate into a coin flip: measured on the labeled corpus it slammed fully shut on 36% of
     Clear Mind frames and 30% of the Athena drift frames, zeroing dreamy each time. At 1.5 s
     those drop to about 10-15% while the gate still reacts fast enough to catch a one-second
     noise burst that the 6 s persistence gate would ride straight through. */
    var vsFastSmoothing: Double = 0.15
    private var smoothedVsFast: Double = 0.0

    /* Detrended dB thresholds. Set from the measured distribution on a real late-night session:
     detrended alpha lead ran -8.0 to +2.5 (median -2.7), detrended theta lead -3.8 to +3.6
     (median +0.1). Dreamy's band is deliberately the wider of the two because theta genuinely
     led half the frames in that recording and the score never moved. */
    var meditationAlphaLeadLowDb: Double = -2.0
    var meditationAlphaLeadHighDb: Double = 1.0

    /* Re-anchored 9 Aug 2026 for the alpha-beta-trend version of thetaLeadDb, which reads on a
     different scale from the old residual version. Measured on the drifting-asleep Athena session
     that exposed the delta problem: smoothed lead held at +2.2 dB (old metric: -1.5, gate shut all
     night). Alert-shaped spectra put theta 2.5-4 dB below the trend line, so 0 is the natural
     onset. The alert end is anchored on synthetic frames only so far — worth one waking session to
     confirm the floor holds. */
    var dreamyThetaLeadLowDb: Double = 0.0
    var dreamyThetaLeadHighDb: Double = 3.0

    //alpha pulls the centroid below the null; how far below still counts as alpha-shaped
    var meditationTiltOffsetHz: Double = -2.0
    var meditationTiltRadiusHz: Double = 3.0

    /* Spread thresholds, also offsets — from nullSpreadHz this time.

     The old absolute pair (0.8...2.6 Hz) could never fire: a featureless 1/f spectrum in a 10 Hz
     window has a spread of about 2.8 Hz, so the ramp topped out BELOW the physical floor and
     `organized` read 0.00 in 79 of 81 frames. Being organized means being narrower than the null,
     which is only expressible as an offset. */
    var organizedOffsetLowHz: Double = -0.8
    var organizedOffsetHighHz: Double = 0.0

    var broadOffsetLowHz: Double = -0.6
    var broadOffsetHighHz: Double = 0.8

    /* Was meditation's low-voltage veto; now observation only, logged as `awake` but not
     multiplied into the score. Relaxed states do not gate each other — see scoreMeditation. */
    var meditationQuietOnset: Double = 25.0
    var meditationQuietFull: Double = 60.0

    /* Theta prominence veto. Below the low value the 4-7 Hz peak is flat enough to be genuine
     diffuse slowing; above the high value it is a discrete ring and almost certainly a loose
     electrode. Derived from 46 bad-fit against 103 good frames — see scoreDreamy. */
    var dreamyProminenceLowDb: Double = 4.0
    var dreamyProminenceHighDb: Double = 7.0

    /* Dreamy's active-brain veto, on raw broadband gamma.

     Measured 9 Aug 2026 across the labeled Muse 2 corpus plus a live Athena drift session:
     coding ran gamma at median +4.1 dB (96% of frames above +2), while clear mind (-1.7),
     tired (+0.2), meditation (+1.3) and real sleep drift (-3.9) all sat at or below +1.3.
     Gamma is fast cortical activity plus EMG — the things drowsiness, by definition, lacks —
     and it lives above the detail window, so the tilt veto cannot see it. This is what
     actually separates concentration theta from drowsy theta when the tilt is ambiguous. */
    var dreamyGammaLowDb: Double = 2.0
    var dreamyGammaHighDb: Double = 4.0

    /* Dreamy's not-fast veto, as an offset from the window's null centroid. */
    var dreamyTiltOffsetOnsetHz: Double = 0.5
    var dreamyTiltOffsetFullHz: Double = 2.0

    /* Formerly hardcoded score-shaping literals, promoted to tunables for the live tuning
     panel. Defaults are the exact values that were inlined in the score functions. */

    //focus: brake stopping calm-focus firing on alpha-led meditation (invRamp on alphaLeadDb)
    var focusNotAlphaLedLowDb: Double = -1.0
    var focusNotAlphaLedHighDb: Double = 1.0
    //focus: support = broadWeight*broadEnough + steadyWeight*holdingSteady; score = shape*(base + span*support)
    var focusSupportBroadWeight: Double = 0.55
    var focusSupportSteadyWeight: Double = 0.45
    var focusBaseOffset: Double = 0.45
    var focusSupportSpan: Double = 0.55

    //meditation: support = centroidW*alphaCentroid + organizedW*organized + steadyW*steady
    var medSupportCentroidWeight: Double = 0.35
    var medSupportOrganizedWeight: Double = 0.35
    var medSupportSteadyWeight: Double = 0.30
    var medBaseOffset: Double = 0.40
    var medSupportSpan: Double = 0.60

    //dreamy: short-memory theta-lead ramp (deliberately 1 dB looser than the 6 s gate)
    var dreamyVsFastLowDb: Double = -1.0
    var dreamyVsFastHighDb: Double = 2.0
    //dreamy: theta-vs-delta soft term ramp; enters as (base + span*calmLowEnd)
    var dreamyCalmLowEndLowDb: Double = -2.0
    var dreamyCalmLowEndHighDb: Double = 2.0
    var dreamyBaseOffset: Double = 0.50
    var dreamySupportSpan: Double = 0.50

    //MARK: - Keyed tuning access
    /* String-keyed access for the runtime tuning panel. Keys match
     XvEEGStateTuningParameter.all in XvMuse.swift — keep the two lists in sync. */
    func setTuning(key: String, value: Double) -> Bool {
        guard value.isFinite else { return false }
        switch key {
        case "focus.tiltLowHz": focusTiltOffsetLowHz = value
        case "focus.tiltHighHz": focusTiltOffsetHighHz = value
        case "focus.calmTiltOffsetHz": calmFocusTiltOffsetHz = value
        case "focus.calmTiltRadiusHz": calmFocusTiltRadiusHz = value
        case "focus.broadLowHz": broadOffsetLowHz = value
        case "focus.broadHighHz": broadOffsetHighHz = value
        case "focus.notAlphaLedLowDb": focusNotAlphaLedLowDb = value
        case "focus.notAlphaLedHighDb": focusNotAlphaLedHighDb = value
        case "focus.supportBroadWeight": focusSupportBroadWeight = value
        case "focus.supportSteadyWeight": focusSupportSteadyWeight = value
        case "focus.baseOffset": focusBaseOffset = value
        case "focus.supportSpan": focusSupportSpan = value

        case "med.alphaLeadLowDb": meditationAlphaLeadLowDb = value
        case "med.alphaLeadHighDb": meditationAlphaLeadHighDb = value
        case "med.tiltOffsetHz": meditationTiltOffsetHz = value
        case "med.tiltRadiusHz": meditationTiltRadiusHz = value
        case "med.organizedLowHz": organizedOffsetLowHz = value
        case "med.organizedHighHz": organizedOffsetHighHz = value
        case "med.supportCentroidWeight": medSupportCentroidWeight = value
        case "med.supportOrganizedWeight": medSupportOrganizedWeight = value
        case "med.supportSteadyWeight": medSupportSteadyWeight = value
        case "med.baseOffset": medBaseOffset = value
        case "med.supportSpan": medSupportSpan = value

        case "dreamy.thetaLeadLowDb": dreamyThetaLeadLowDb = value
        case "dreamy.thetaLeadHighDb": dreamyThetaLeadHighDb = value
        case "dreamy.thetaLeadSmoothing": thetaLeadSmoothing = value
        case "dreamy.vsFastSmoothing": vsFastSmoothing = value
        case "dreamy.vsFastLowDb": dreamyVsFastLowDb = value
        case "dreamy.vsFastHighDb": dreamyVsFastHighDb = value
        case "dreamy.notFastOnsetHz": dreamyTiltOffsetOnsetHz = value
        case "dreamy.notFastFullHz": dreamyTiltOffsetFullHz = value
        case "dreamy.prominenceLowDb": dreamyProminenceLowDb = value
        case "dreamy.prominenceHighDb": dreamyProminenceHighDb = value
        case "dreamy.gammaLowDb": dreamyGammaLowDb = value
        case "dreamy.gammaHighDb": dreamyGammaHighDb = value
        case "dreamy.calmLowEndLowDb": dreamyCalmLowEndLowDb = value
        case "dreamy.calmLowEndHighDb": dreamyCalmLowEndHighDb = value
        case "dreamy.baseOffset": dreamyBaseOffset = value
        case "dreamy.supportSpan": dreamySupportSpan = value

        default: return false
        }
        return true
    }

    func reset() {
        meditationScore = 0.0
        focusScore = 0.0
        dreamyScore = 0.0
        focusGate = 0.0
        focusSupport = 0.0
        medGate = 0.0
        medSupport = 0.0
        dreamyGate = 0.0
        dreamyCredibility = 0.0
        dreamySupport = 0.0
        focusBroadEnough = 0.0
        focusHoldingSteady = 0.0
        focusFastCentroid = 0.0
        focusCalmCentroid = 0.0
        focusNotAlphaLed = 1.0
        meditationAlphaLeadDb = 0.0
        meditationAlphaCentroid = 0.0
        meditationOrganized = 0.0
        meditationHoldingSteady = 0.0
        meditationAwakeEnough = 1.0
        dreamyThetaLeadDb = 0.0
        dreamySmoothedThetaLeadDb = 0.0
        dreamyThetaVsFastDb = 0.0
        dreamyClearOfFastBands = 0.0
        dreamyStillnessPresent = 0.0
        dreamyThetaVsDeltaDb = 0.0
        dreamyCalmLowEnd = 0.0
        dreamyNotRunningFast = 1.0
        dreamyLooksLikeRhythm = 1.0
        dreamyThetaProminenceDb = 0.0
        dreamyTiltOffsetHz = 0.0
        dreamyCalmGamma = 1.0
        dreamyGammaDb = 0.0
        smoothedThetaLead = 0.0
        smoothedVsFast = 0.0
    }

    func applyStateScores(
        centroidHz: Double,
        spreadHz: Double,
        logPower: Double,
        stability: Double,
        bands: BandBalance?,
        tension: Double,
        thetaProminenceDb: Double,
        smoothing: Double
    ) -> (meditation: Double, focus: Double, dreamy: Double) {

        //Kept in the API because it is useful for logging/tuning even if not scored yet.
        _ = logPower

        let newFocus = scoreFocus(
            centroidHz: centroidHz,
            spreadHz: spreadHz,
            stability: stability,
            bands: bands
        ) * 100.0

        let newMeditation = scoreMeditation(
            centroidHz: centroidHz,
            spreadHz: spreadHz,
            stability: stability,
            bands: bands
        ) * 100.0

        focusScore = smoothScore(old: focusScore, new: newFocus, factor: smoothing)
        meditationScore = smoothScore(old: meditationScore, new: newMeditation, factor: smoothing)

        //dreamy holds its last value if band data hasn't arrived yet
        if let bands {
            /* Scaled down by muscle tension: a clench rules out drowsy drifting, and it also
             makes the reading untrustworthy. Applied before smoothing so the score eases down
             rather than dropping in one step. */
            let newDreamy = scoreDreamy(
                bands,
                centroidHz: centroidHz,
                thetaProminenceDb: thetaProminenceDb
            ) * 100.0 * RelaxedStateGate.damping(forTension: tension)
            dreamyScore = smoothScore(old: dreamyScore, new: newDreamy, factor: smoothing)
        }

        return (meditationScore, focusScore, dreamyScore)
    }

    func fadeScores(factor: Double, fadeFocus: Bool = true) -> (meditation: Double, focus: Double, dreamy: Double) {
        if fadeFocus {
            focusScore = smoothScore(old: focusScore, new: 0.0, factor: factor)
            focusGate = smoothScore(old: focusGate, new: 0.0, factor: factor)
            focusSupport = smoothScore(old: focusSupport, new: 0.0, factor: factor)
        }

        meditationScore = smoothScore(old: meditationScore, new: 0.0, factor: factor)
        dreamyScore = smoothScore(old: dreamyScore, new: 0.0, factor: factor)

        medGate = smoothScore(old: medGate, new: 0.0, factor: factor)
        medSupport = smoothScore(old: medSupport, new: 0.0, factor: factor)
        dreamyGate = smoothScore(old: dreamyGate, new: 0.0, factor: factor)
        dreamyCredibility = smoothScore(old: dreamyCredibility, new: 0.0, factor: factor)
        dreamySupport = smoothScore(old: dreamySupport, new: 0.0, factor: factor)

        return (meditationScore, focusScore, dreamyScore)
    }

    /* Focus: faster detail-window centroid, broadband enough to feel active, and held steady. */
    private func scoreFocus(
        centroidHz: Double,
        spreadHz: Double,
        stability: Double,
        bands: BandBalance?
    ) -> Double {

        let tiltOffsetHz = centroidHz - nullCentroidHz
        let spreadOffsetHz = spreadHz - nullSpreadHz

        let fastCentroid = ramp(tiltOffsetHz, low: focusTiltOffsetLowHz, high: focusTiltOffsetHighHz)
        let calmCentroid = centered(
            tiltOffsetHz,
            center: calmFocusTiltOffsetHz,
            radius: calmFocusTiltRadiusHz
        )
        let broadEnough = ramp(spreadOffsetHz, low: broadOffsetLowHz, high: broadOffsetHighHz)
        let holdingSteady = clamp01(stability)

        /* The brake on the calm path: calm focus must not be alpha meditation.

         This used to be `activeNotQuiet`, an inverse ramp on quiet across 55...85. Quiet never
         got above 35 in a whole session, so that term read exactly 1.00 in every single frame —
         a guard that had never once engaged. With no working brake, the calm path was firing on
         real meditation: its centre sits in the alpha range, so the moment alpha pulled the
         centroid down, focus went UP. One frame had tilt at 10.58 Hz, calm at 0.99, focus at 37,
         during eyes-closed practice.

         Alpha leading the detrended spectrum is the thing that actually separates the two states,
         so that is what gates it now. An engaged reader with a flat alpha still qualifies; someone
         sitting in strong alpha does not. */
        let notAlphaLed = bands.map { invRamp($0.alphaLeadDb, low: focusNotAlphaLedLowDb, high: focusNotAlphaLedHighDb) } ?? 1.0

        let calmFocus = calmCentroid * broadEnough * notAlphaLed
        let focusShape = max(fastCentroid, calmFocus)

        focusTiltOffsetHz = tiltOffsetHz
        focusSpreadOffsetHz = spreadOffsetHz
        focusAlphaLeadDb = bands?.alphaLeadDb ?? 0.0
        focusNullCentroidHz = nullCentroidHz

        //Keep focus detail-first. Low full-spectrum theta is too noisy to use as support here.
        let support = (focusSupportBroadWeight * broadEnough) + (focusSupportSteadyWeight * holdingSteady)

        focusGate = focusShape
        focusSupport = support
        focusBroadEnough = broadEnough
        focusHoldingSteady = holdingSteady
        focusFastCentroid = fastCentroid
        focusCalmCentroid = calmCentroid
        focusNotAlphaLed = notAlphaLed

        return clamp01(focusShape * (focusBaseOffset + (focusSupportSpan * support)))
    }

    /* Meditation: alpha-led, organized, still activity in the detail window. */
    private func scoreMeditation(
        centroidHz: Double,
        spreadHz: Double,
        stability: Double,
        bands: BandBalance?
    ) -> Double {

        guard let bands else {
            medGate = 0
            medSupport = 0
            return 0
        }

        /* Detrended, so this asks "is alpha oscillating above its own background level" rather
         than "is alpha the loudest band", which it can never be — see BandBalance. */
        let alphaLeadDb = bands.alphaLeadDb
        let alphaLeads = ramp(
            alphaLeadDb,
            low: meditationAlphaLeadLowDb,
            high: meditationAlphaLeadHighDb
        )

        let alphaCentroid = centered(
            centroidHz - nullCentroidHz,
            center: meditationTiltOffsetHz,
            radius: meditationTiltRadiusHz
        )
        let organized = invRamp(
            spreadHz - nullSpreadHz,
            low: organizedOffsetLowHz,
            high: organizedOffsetHighHz
        )
        let holdingSteady = clamp01(stability)

        let support = (medSupportCentroidWeight * alphaCentroid) + (medSupportOrganizedWeight * organized) + (medSupportSteadyWeight * holdingSteady)

        /* QUIET NO LONGER VETOES THIS. Measured but not multiplied in — same arrangement as
         stillness on dreamy, and for a related reason.

         It was added as a low-voltage veto, to stop sleep onset from reading as meditation. On
         the morning Athena session it zeroed all ~130 frames: quiet published 100 throughout, and
         invRamp(100, 25, 60) is 0, so every score was multiplied by zero. Frames with clear alpha
         lead and strong support — ones that would have scored 63, 73, 88, 90 — all published 0.

         The immediate cause was the calibration being far off (see quietLevelDb), but the design
         is wrong independently of that. Meditation, quiet and dreamy are not competing hypotheses
         about one underlying state; they are separate descriptions that genuinely co-occur and
         trade off through a real session. A relaxed state must not gate another relaxed state,
         because "both at once" is the common case, not a contradiction to be resolved.

         The cost is accepted deliberately: meditation can now score during drowsiness. Dreamy
         will generally be scoring at the same time, and telling those two apart is the consumer's
         job with both numbers in hand — not something to force here by suppressing one of them. */
        let awakeEnough = invRamp(bands.quiet, low: meditationQuietOnset, high: meditationQuietFull)

        medGate = alphaLeads
        medSupport = support
        meditationAlphaLeadDb = alphaLeadDb
        meditationAlphaCentroid = alphaCentroid
        meditationOrganized = organized
        meditationHoldingSteady = holdingSteady
        meditationAwakeEnough = awakeEnough

        return clamp01(alphaLeads * (medBaseOffset + (medSupportSpan * support)))
    }

    /* Dreamy: theta-led, quiet, slow activity. Theta remains full-spectrum upstream, but is
     delayed and artifact-screened so blink/tension pre-roll frames do not count. */
    /* WHICH STATE OWNS WHICH RHYTHM — settled 9 Aug 2026, do not "fix" this back.

     Alpha belongs to meditation. Theta belongs to dreamy. That division is deliberate, and it
     means DREAMY DOES NOT FIRE ON ALPHA-RICH DROWSINESS — the early, eyes-closed, relaxed-but-not-
     gone stage where alpha is still strong. Meditation covers that stage, correctly.

     This looks like a bug in one specific place, which is why it is written down here. On the
     labeled Muse 2 "Tired" recording, dreamy sits near 0 for most of the run while meditation
     reads 25-49. An earlier version of thetaLeadDb scored that same recording as high as 87, so
     the natural reading is that something regressed. It did not. That recording is alpha-rich:
     measuring theta against the alpha/beta trend line (see BandBalance.thetaLeadDb) means strong
     alpha lifts the line and theta correctly reads as NOT leading. Dreamy is reserved for the
     deeper stage, where alpha has faded and theta genuinely dominates — which is exactly what the
     live Athena drift session showed, and what dreamy scores 40-60 on.

     So the two recordings are not a measure that works on one and fails on the other. They are two
     different states, and each is being reported under the right name. Jason's call, and the
     states remain free to overlap — no relaxed state gates another. */
    private func scoreDreamy(
        _ bands: BandBalance,
        centroidHz: Double,
        thetaProminenceDb: Double
    ) -> Double {

        /* Theta has to lead for a WHILE, not for an instant.

         Drowsiness is a sustained condition; a one-second theta blip is not falling asleep. In the
         Clear Mind recording theta out-ranked everything else in about a quarter of all frames —
         scattered single frames surrounded by negatives — and each one scored full marks, pushing
         dreamy into the 50s and 60s during an eyes-open resting state.

         Averaged over several seconds the two separate cleanly: Clear Mind sits at about -2.3 dB,
         genuine drowsiness at about +0.3 and holds there. Coding averages -2.3 as well, so this
         cleans up the remaining false positives there too.

         This also repairs a flaw in the stillness gate below. It was added to distinguish real
         drowsiness from theta during hard concentration — but Clear Mind IS still, so the gate
         meant to add skepticism was instead granting full credibility to the one state it cannot
         tell apart from drowsiness. Persistence is what actually separates them. */
        let thetaLeadDb = bands.thetaLeadDb
        smoothedThetaLead += thetaLeadSmoothing * (thetaLeadDb - smoothedThetaLead)
        let thetaLeads = ramp(
            smoothedThetaLead,
            low: dreamyThetaLeadLowDb,
            high: dreamyThetaLeadHighDb
        )

        /* Broadband noise raises beta too, so theta needs to stand clear of it. It used to be the
         residual difference (thetaResidual - betaResidual), but a delta surge rotated the shared
         fit and sent that to -6 dB in the same frame it corrupted everything else; the trend-based
         lead is delta-blind by construction.

         TWO VIEWS OF ONE NUMBER, not two pieces of evidence. Since the estimator changed this is
         the same quantity as the gate above, read over ~1.5 s instead of ~6 s: has theta been
         leading, AND is it still leading right now. Because they are correlated, this one is
         deliberately the looser of the pair — its ramp sits a full dB lower at both ends, so it
         only bites when theta drops genuinely below the alpha/beta line rather than adding a
         second full-strength requirement on the same measurement. */
        smoothedVsFast += vsFastSmoothing * (thetaLeadDb - smoothedVsFast)
        let thetaVsFastDb = smoothedVsFast
        let clearOfFastBands = ramp(thetaVsFastDb, low: dreamyVsFastLowDb, high: dreamyVsFastHighDb)

        /* Stillness is measured and logged but NO LONGER GATES anything.

         It used to multiply into the score via ramp(quiet, 20, 50). On a real late-night session
         quiet had a median of 0 and cleared 20 in only 11% of frames, so this term alone held
         dreamy at zero for the entire recording regardless of what theta did.

         The deeper problem is that it was pointing the wrong way. Quiet measures absolute low
         amplitude, and a drowsy brain is not low amplitude — it is high-amplitude slow waves. So
         the closer the subject got to sleep onset, the harder this gate pushed dreamy down. Quiet
         is a good measurement doing its own job well; it just cannot also serve as evidence for
         the one state that physically contradicts it.

         Credibility now rests on theta standing clear of beta, plus the artifact screening that
         already invalidates bands around blinks and clenches upstream. */
        let stillnessPresent = ramp(bands.quiet, low: 20.0, high: 50.0)

        //A calm low end. A blink drives delta up and pulls this down.
        let thetaVsDeltaDb = bands.thetaResidual - bands.deltaResidual
        let calmLowEnd = ramp(thetaVsDeltaDb, low: dreamyCalmLowEndLowDb, high: dreamyCalmLowEndHighDb)

        /* NOT RUNNING FAST. The one thing theta alone can never do is separate drowsiness from
         concentration — frontal midline theta is a real focus rhythm, and on the sessions measured
         theta lead told the two apart at 0.52, a coin flip. Dreamy was peaking at 61 during focused
         coding as a result.

         What does separate them is where the centroid sits. Drowsy theta rides a slow spectrum;
         Fm theta rides a fast one. Measured: coding centroid +1.7 Hz above the window's null,
         tired +0.1. Vetoing the fast case costs the tired session almost nothing (51 -> 48) and
         removes the coding false positive outright (16 -> 2). */
        let tiltOffsetHz = centroidHz - nullCentroidHz
        let notRunningFast = invRamp(
            tiltOffsetHz,
            low: dreamyTiltOffsetOnsetHz,
            high: dreamyTiltOffsetFullHz
        )

        /* NOT A DISCRETE PEAK. The guard that finally catches a badly-seated headset.

         Every other term here compares theta's LEVEL against another band, and a loose electrode
         defeats all of them at once by raising theta harder than anything else. Measured against a
         well-seated session on the same headset: theta +17.5 dB, delta +8.4, alpha +5.7, beta
         +2.0. So `clearOfFastBands` (theta minus beta) and `calmLowEnd` (theta minus delta) both
         open WIDER during the artifact, and blink gating never fires because the worst frames
         score 0-2 on blink.

         Shape separates them where level cannot, and in the opposite direction to intuition: the
         ARTIFACT is the sharp peak, and real drowsy theta is the flat one. Sleep onset is textbook
         low-voltage mixed frequency — everything slows and fades together, so theta rises relative
         to its neighbours without ever forming a bump. A loose electrode rubbing against skin is a
         mechanical system with a characteristic timescale, so it rings.

         Measured across four recordings, 46 bad-fit frames against 103 good, AUC 0.987:

             Muse 2, just put on      median 14.46 dB      dreamy median 64, peaking at 78
             Muse 2, settled           median  2.79 dB      dreamy median 20
             Muse S, just put on       median  7.44 dB
             Muse 2, genuinely tired   median  1.43 dB      dreamy peaking at 87, correctly

         The Muse 2 numbers are the ones that matter: same headset, same person, same recording,
         an 11.7 dB step as the fit settled. That rules out the device and leaves only the fit.

         The peak's LOCATION says the same thing twice over — during bad fit it pins to exactly
         6.00 Hz on both headsets and essentially never moves (stdev 0.19 Hz), while real drowsy
         theta wanders the whole 4-7 Hz band (stdev 1.06 Hz). A rhythm that never changes frequency
         is not a rhythm.

         Ramped 4->7 dB rather than switched: keeps 99% of the genuinely tired frames while
         suppressing 87% of the bad-fit ones. */
        let looksLikeRhythm = invRamp(
            thetaProminenceDb,
            low: dreamyProminenceLowDb,
            high: dreamyProminenceHighDb
        )

        dreamyGate = thetaLeads
        dreamyCredibility = clearOfFastBands
        dreamySupport = calmLowEnd
        //calm gamma: an active, engaged brain runs its fast bands hot even when its tilt is slow
        let calmGamma = invRamp(bands.gamma, low: dreamyGammaLowDb, high: dreamyGammaHighDb)

        dreamyNotRunningFast = notRunningFast
        dreamyLooksLikeRhythm = looksLikeRhythm
        dreamyThetaProminenceDb = thetaProminenceDb
        dreamyTiltOffsetHz = tiltOffsetHz
        dreamyCalmGamma = calmGamma
        dreamyGammaDb = bands.gamma
        dreamyThetaLeadDb = thetaLeadDb
        dreamySmoothedThetaLeadDb = smoothedThetaLead
        dreamyThetaVsFastDb = thetaVsFastDb
        dreamyClearOfFastBands = clearOfFastBands
        dreamyStillnessPresent = stillnessPresent
        dreamyThetaVsDeltaDb = thetaVsDeltaDb
        dreamyCalmLowEnd = calmLowEnd

        return clamp01(
            thetaLeads * clearOfFastBands * notRunningFast * looksLikeRhythm * calmGamma
                * (dreamyBaseOffset + (dreamySupportSpan * calmLowEnd))
        )
    }

    private func clamp01(_ x: Double) -> Double {
        max(0.0, min(1.0, x))
    }

    private func ramp(_ x: Double, low: Double, high: Double) -> Double {
        guard high > low else { return x >= high ? 1.0 : 0.0 }
        return clamp01((x - low) / (high - low))
    }

    private func invRamp(_ x: Double, low: Double, high: Double) -> Double {
        1.0 - ramp(x, low: low, high: high)
    }

    private func centered(_ x: Double, center: Double, radius: Double) -> Double {
        guard radius > 0 else { return x == center ? 1.0 : 0.0 }
        return clamp01(1.0 - (abs(x - center) / radius))
    }

    private func smoothScore(old: Double, new: Double, factor: Double) -> Double {
        let f = clamp01(factor)
        return (f * new) + ((1.0 - f) * old)
    }
}
