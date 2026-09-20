//
//  HeadsetOffDetector.swift
//  XvMuse
//
//  Decides whether the headset is on a head or not, and prints one line every
//  2 seconds showing what it sees.
//
//  The adaptive sensor weighting means "every pad reads noisy" no longer separates
//  two very different situations: the headset is ON with a poor fit, or the headset
//  is OFF entirely (on a table, in a hand). The session's validity depends on
//  telling them apart.
//
//  The log line shows, per sensor, the EEG signal size in uV (or MAX when the
//  sensor is maxed out, see below), then the optical heart sensor level, seconds
//  since the last heartbeat, and how much the headset is moving.
//
//  Turn the log off with HeadsetOffDetector.isLogEnabled. The detector keeps running.
//

import Foundation

final class HeadsetOffDetector {

    static var isLogEnabled = true

    private let lock = NSLock()
    private let windowSeconds: TimeInterval = 2.0
    private var windowStart: TimeInterval = 0

    private var eeg: [[Double]] = [[], [], [], []]     //config order TP9, AF7, AF8, TP10
    private var ppg: [Double] = []
    private var accelMagnitude: [Double] = []
    private var accelSum: (x: Double, y: Double, z: Double) = (0, 0, 0)
    private var rawNoise: [Double] = [-1, -1, -1, -1]
    private var lastBeatUptime: TimeInterval = 0

    //MARK: - Detector (live, not just logging)

    /* MAXED OUT: a pad touching nothing picks up stray electricity, and its signal
     swings as far as the headset's electronics can measure and stays pinned there.
     That ceiling is a fixed property of the headset (a swing of 1450 uV on Athena,
     2000 uV on Muse 1/2/S), so a pad whose swing reaches 90% of it is carrying no
     brain signal at all. Measured 20 Sep 2026 on all three headsets: every off-head
     recording maxed out, no well-seated pad did.

     This exists because the ML noise model cannot be trusted here. On Athena and
     Muse S it scores a maxed-out pad as CLEAN (0 to 5), so a headset on a table read
     as four perfect sensors.

     OFF = at least 3 pads maxed out and the remaining one not clearly healthy, for 3
     windows running (6 s). "Not clearly healthy" covers the Muse 2, where one pad on
     the table hovered just under the ceiling. A single healthy pad (swing under half
     the ceiling) means a head is there and this is a bad fit, which the adaptive
     weighting already handles.

     Back ON = 2 healthy pads for 2 windows (4 s), or 1 healthy pad for 5 windows
     (10 s). The slower rule for a single pad is from the Athena in-hand test: a
     finger on one pad made it look healthy for a few seconds and the state flickered
     to ON and back. A badly fitted headset on a real head holds its one good pad. */
    private var maxLevel: Double = 2000
    private(set) var maxedPads: [Bool] = [false, false, false, false]
    private(set) var isOff = false
    private var offWindows = 0
    private var onWindows = 0

    ///Athena's amplifier range differs from the older headsets'.
    func setDevice(isAthena: Bool) {
        lock.lock(); defer { lock.unlock() }
        maxLevel = isAthena ? 1450 : 2000
    }

    ///Thread-safe snapshot for the noise path.
    func snapshot() -> (maxed: [Bool], isOff: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (maxedPads, isOff)
    }

    private func updateDetector(p2p: [Double]) {
        let maxed = p2p.map { $0 >= maxLevel * 0.9 }
        let healthyCount = p2p.filter { $0 > 0 && $0 < maxLevel * 0.5 }.count
        maxedPads = maxed

        let looksOff = maxed.filter { $0 }.count >= 3 && healthyCount == 0
        if looksOff { offWindows += 1; onWindows = 0 } else { onWindows += 1; offWindows = 0 }
        let windowsToTurnOn = healthyCount >= 2 ? 2 : 5

        if !isOff && offWindows >= 3 {
            isOff = true
            print("XvMuse: HEADSET OFF (3 or more sensors maxed out for 6s, none healthy)")
        } else if isOff && onWindows >= windowsToTurnOn {
            isOff = false
            print("XvMuse: HEADSET ON again")
        }
    }

    func addEEG(configSensorIndex index: Int, samples: [Double]) {
        guard index >= 0, index < 4 else { return } //always on: the detector depends on it
        lock.lock(); defer { lock.unlock() }
        eeg[index].append(contentsOf: samples)
        flushIfDue()
    }

    func addPPG(samples: [Double]) {
        guard Self.isLogEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        ppg.append(contentsOf: samples)
    }

    func addAccel(x: Double, y: Double, z: Double) {
        guard Self.isLogEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        accelMagnitude.append((x * x + y * y + z * z).squareRoot())
        accelSum.x += x; accelSum.y += y; accelSum.z += z
    }

    func noteHeartbeat() {
        guard Self.isLogEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        lastBeatUptime = ProcessInfo.processInfo.systemUptime
    }

    ///Raw (unheld) per-sensor ML noise, config order.
    func setRawNoise(_ values: [Double]) {
        guard Self.isLogEnabled, values.count == 4 else { return }
        lock.lock(); defer { lock.unlock() }
        rawNoise = values
    }

    //MARK: - Window

    private func flushIfDue() {
        let now = ProcessInfo.processInfo.systemUptime
        if windowStart == 0 { windowStart = now; return }
        guard now - windowStart >= windowSeconds else { return }
        windowStart = now

        let labels = ["TP9", "AF7", "AF8", "TP10"]
        func fourUp(_ values: [Double], _ format: String) -> String {
            zip(labels, values).map { String(format: "%@ " + format, $0, $1) }.joined(separator: " ")
        }

        let centered = eeg.map { Self.centered($0) }
        let rms = centered.map { Self.rms($0) }
        let p2p = eeg.map { ($0.max() ?? 0) - ($0.min() ?? 0) }

        //mean pairwise correlation across the six sensor pairs
        var correlations: [Double] = []
        for a in 0..<4 {
            for b in (a + 1)..<4 {
                if let r = Self.correlation(centered[a], centered[b]) { correlations.append(r) }
            }
        }
        let corr = correlations.isEmpty ? 0 : correlations.reduce(0, +) / Double(correlations.count)

        let ppgDC = ppg.isEmpty ? 0 : ppg.reduce(0, +) / Double(ppg.count)
        let ppgAC = Self.rms(Self.centered(ppg))
        let beatAge = lastBeatUptime == 0 ? -1 : now - lastBeatUptime

        let n = Double(max(accelMagnitude.count, 1))
        let moveSD = Self.rms(Self.centered(accelMagnitude))

        //MAX marks a maxed-out pad (touching nothing); otherwise the number is the
        //signal size in uV
        updateDetector(p2p: p2p)
        let maxed = maxedPads
        guard Self.isLogEnabled else { resetWindow(); return }
        let pads = zip(labels, zip(rms, maxed)).map { label, pad in
            pad.1 ? "\(label) MAX" : String(format: "%@ %.0f", label, pad.0)
        }.joined(separator: "  ")
        let maxedCount = maxed.filter { $0 }.count
        let guess = isOff ? "OFF" : (maxedCount == 0 ? "on" : "on, \(maxedCount) maxed out")

        print(String(format: "HEADSET | %@ | maxed out %d/4 | ppg %.2f beat %.0fs | move %.3f | %@",
                     pads, maxedCount, ppgDC, beatAge, moveSD, guess))
        _ = (corr, ppgAC, n) //kept computed; drop from the line until they earn a place

        resetWindow()
    }

    private func resetWindow() {
        eeg = [[], [], [], []]
        ppg = []
        accelMagnitude = []
        accelSum = (0, 0, 0)
    }

    //MARK: - Math

    private static func centered(_ values: [Double]) -> [Double] {
        guard !values.isEmpty else { return [] }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.map { $0 - mean }
    }

    private static func rms(_ centeredValues: [Double]) -> Double {
        guard !centeredValues.isEmpty else { return 0 }
        return (centeredValues.reduce(0) { $0 + $1 * $1 } / Double(centeredValues.count)).squareRoot()
    }

    private static func correlation(_ a: [Double], _ b: [Double]) -> Double? {
        let count = min(a.count, b.count)
        guard count > 16 else { return nil }
        var ab = 0.0, aa = 0.0, bb = 0.0
        for i in 0..<count { ab += a[i] * b[i]; aa += a[i] * a[i]; bb += b[i] * b[i] }
        guard aa > 0, bb > 0 else { return nil }
        return ab / (aa * bb).squareRoot()
    }
}
