 //
//  ProcessingLoadGovernor.swift
//  XvMuse
//
//  Created by Jason Snell on 10/13/26.
//  Copyright © 2026 Jason Snell. All rights reserved.
//

import Foundation

/* THE LOAD GOVERNOR (13 Oct 2026).

 Every Bluetooth notification becomes one block on XvMuse.processingQ, and the queue has no
 depth limit. On a machine that cannot keep up, each block starts later than the last and the
 whole app (sound, visuals, states) falls behind the body by that lag. The queue wait of a
 block (now minus the moment it was enqueued) is the one honest measure of the lag, and this
 class turns the series of waits into a level:

   .full      every epoch, every publish. The normal state, and the only state a machine that
              keeps up ever sees.
   .lean(m)   epochs released m times less often, so the FFT work drops to 1/m. Publishes and
              every per-update constant keep stepping exactly as before, so the feel is kept.
   .catchUp   ingest only. Every sample still reaches the raw archive, the off detector and
              the FFT window; no epochs, no analysis, no publishes until the queue is short.

 The level is a pure function of the wait series and the clock, so a run is reproducible, and
 nothing engages while the queue keeps up. All state lives on processingQ. */
internal final class ProcessingLoadGovernor {

    enum Level: Equatable {
        case full
        case lean(multiplier: Int)
        case catchUp

        ///For the log lines.
        var name: String {
            switch self {
            case .full: return "full"
            case .lean(let multiplier): return "lean x\(multiplier)"
            case .catchUp: return "catch-up"
            }
        }

        ///For XvMuse.processingLoadLevel: 0 full, 1 lean x2, 2 lean x4, 3 catch-up.
        var code: Int {
            switch self {
            case .full: return 0
            case .lean(let multiplier): return multiplier >= 4 ? 2 : 1
            case .catchUp: return 3
            }
        }

        ///What the epoch gate is stretched by at this level (1 = normal).
        var epochGateMultiplier: Int {
            if case .lean(let multiplier) = self { return max(1, multiplier) }
            return 1
        }
    }

    //MARK: - Tuning

    var leanWaitSeconds = 0.15        // wait at or above this ...
    var leanSustainSeconds = 0.5      // ... on every block for this long enters lean
    var catchUpWaitSeconds = 0.35     // any block that waited this long switches to catch-up
    var recoveredWaitSeconds = 0.05   // a block that waited less than this is "caught up"
    var leanHoldSeconds = 5.0         // lean -> full after the wait stays under recovered this long; doubles on re-entry within 60 s, max 60
    var graceSeconds = 3.0            // after reset(), nothing engages (connect burst, buffer fill)

    private let maximumHoldSeconds = 60.0
    private let reentrySeconds = 60.0        // leaving lean and coming back within this doubles the hold
    private let fullResetSeconds = 300.0     // this long at full forgets a doubled hold
    private let catchUpShortWindow = 30.0    // 2 catch-ups in here while full -> lean x2
    private let catchUpLongWindow = 60.0     // 3 catch-ups in here while lean x2 -> lean x4

    //MARK: - State

    private(set) var level: Level = .full

    private var graceUntil: Double = 0
    private var rememberedLevel: Level = .full   // where catch-up returns to
    private var levelBeforeCatchUp: Level = .full
    private var overSince: Double? = nil         // full: when the wait first went over lean
    private var underSince: Double? = nil        // lean: when the wait last dropped under recovered
    private var fullSince: Double? = nil         // when full was last entered
    private var leftLeanAt: Double? = nil        // when lean was last left for full
    private var holdSeconds: Double = 5.0        // the current hold; starts at leanHoldSeconds
    private var catchUpEntries: [Double] = []    // when catch-up was entered, last 60 s

    init() {
        holdSeconds = leanHoldSeconds
    }

    //MARK: - API

    ///Connect, disconnect, test data start or stop: back to full, and nothing engages for graceSeconds.
    func reset(now: Double) {
        level = .full
        rememberedLevel = .full
        levelBeforeCatchUp = .full
        graceUntil = now + graceSeconds
        overSince = nil
        underSince = nil
        fullSince = now
        leftLeanAt = nil
        holdSeconds = leanHoldSeconds
        catchUpEntries.removeAll(keepingCapacity: true)
    }

    ///Called once per block, before any work. Returns the level the block should run at.
    ///Every transition returns a different Level than the call before it, so the caller can log it.
    func observe(queueWait wait: Double, now: Double) -> Level {
        //(6) grace: the level is .full since reset, and stays so
        guard now >= graceUntil else { return level }

        //(5) a long stretch at full forgets a doubled hold
        if level == .full, let since = fullSince, now - since >= fullResetSeconds {
            holdSeconds = leanHoldSeconds
            leftLeanAt = nil
        }

        if level == .catchUp {
            //(2) one short wait and the queue is back
            if wait < recoveredWaitSeconds {
                leaveCatchUp(now: now)
            }
            return level
        }

        //(1) a block this late means the queue is long: stop analysing until it is short
        if wait >= catchUpWaitSeconds {
            enterCatchUp(now: now)
            return level
        }

        switch level {
        case .full:
            //(4) sustained lateness, not one late block, enters lean
            if wait >= leanWaitSeconds {
                if overSince == nil { overSince = now }
                if let since = overSince, now - since >= leanSustainSeconds {
                    enterLean(multiplier: 2, now: now)
                }
            } else {
                overSince = nil
            }
        case .lean(let multiplier):
            //(5) one step down after the wait has stayed under recovered for the hold
            if wait < recoveredWaitSeconds {
                if underSince == nil { underSince = now }
                if let since = underSince, now - since >= holdSeconds {
                    stepDown(from: multiplier, now: now)
                }
            } else {
                underSince = nil
            }
        case .catchUp:
            break
        }
        return level
    }

    //MARK: - Transitions

    private func enterCatchUp(now: Double) {
        levelBeforeCatchUp = level
        rememberedLevel = level
        overSince = nil
        underSince = nil

        catchUpEntries.append(now)
        catchUpEntries.removeAll { now - $0 > catchUpLongWindow }

        //(3) repeated catch-ups mean the machine needs less FFT work, not just a pause
        let inShortWindow = catchUpEntries.filter { now - $0 <= catchUpShortWindow }.count
        if rememberedLevel == .full, inShortWindow >= 2 {
            rememberedLevel = .lean(multiplier: 2)
        } else if rememberedLevel == .lean(multiplier: 2), catchUpEntries.count >= 3 {
            rememberedLevel = .lean(multiplier: 4)
        }

        level = .catchUp
    }

    private func leaveCatchUp(now: Double) {
        switch rememberedLevel {
        case .full:
            setFull(now: now)
        case .lean(let multiplier):
            if levelBeforeCatchUp == .full {
                //promoted while away: this is an entry into lean from full
                enterLean(multiplier: multiplier, now: now)
            } else {
                //the lean stay continues; the hold starts counting afresh
                level = .lean(multiplier: multiplier)
                underSince = nil
            }
        case .catchUp:
            setFull(now: now)
        }
    }

    private func enterLean(multiplier: Int, now: Double) {
        //(5) coming back soon after leaving doubles the hold, up to a minute
        if let left = leftLeanAt, now - left <= reentrySeconds {
            holdSeconds = min(holdSeconds * 2.0, maximumHoldSeconds)
        }
        level = .lean(multiplier: multiplier)
        fullSince = nil
        overSince = nil
        underSince = nil
    }

    private func stepDown(from multiplier: Int, now: Double) {
        if multiplier > 2 {
            level = .lean(multiplier: 2)
            underSince = nil
        } else {
            leftLeanAt = now
            setFull(now: now)
        }
    }

    private func setFull(now: Double) {
        level = .full
        fullSince = now
        overSince = nil
        underSince = nil
    }
}
