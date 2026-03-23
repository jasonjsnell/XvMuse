//
//  EEGStateModels.swift
//  XvMuse
//

import Foundation

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
