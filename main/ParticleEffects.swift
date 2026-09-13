//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors.
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

// Particle-effect simulation for the idle screen. rgb_tile.c (C/LVGL) owns
// the tile, the timer, the backlight, and drawing -- it has no idea which
// effect is running. This file owns the "what does the screen currently look
// like" question entirely.
//
// Embedded Swift has no runtime type metadata, so a `protocol` +
// `any ParticleEffect` existential (the usual way to make this pluggable)
// doesn't compile here:
//
//   error: cannot use a value of protocol type 'any ParticleEffect' in
//   embedded Swift [#EmbeddedRestrictions]
//
// A closed enum stands in for that polymorphism instead. Adding a new effect
// is: write a new struct with its own state + `tick`, add a case below, add
// one arm to the switch in `particle_effect_tick`. No C changes.

enum CurrentParticleEffect {
    case starfield(Starfield)
    case sphere(Sphere)
    // case flock(Flock), case qr(...), ... go here later
}

private var currentEffect: CurrentParticleEffect = .starfield(Starfield())

// TEST ONLY: cycle through effects every 5s so both are easy to see without
// wiring up a real trigger yet (a BLE property, a button, ...). This ticks
// counter is driven by the same timer as everything else, so `ticksPerEffect`
// must track PARTICLE_TICK_MS in rgb_tile.c (currently 50 ms -> 20 Hz).
// Remove this block once you've settled on how effects should actually switch.
private let ticksPerEffect: Int32 = 5 * 20  // 5s * 20 Hz
private var ticksUntilSwitch: Int32 = ticksPerEffect

// Cross-effect morph: when switching, ease every particle slot from wherever
// it last was (`lastOutputBuffer`) to the newly-selected effect's live output
// for *this* tick, rather than snapping. Lives entirely at the dispatcher
// level -- Starfield/Sphere/etc. only ever need to produce "where am I right
// now", never anything morph-aware.
private let morphDurationTicks = MorphEase.steps   // ~1.4s at 20 Hz
private var morphElapsedTicks: Int32 = MorphEase.steps  // start "not morphing"
private let scratchBuffer = UnsafeMutablePointer<particle_t>.allocate(capacity: Int(PARTICLE_MAX_COUNT))
private let lastOutputBuffer = UnsafeMutablePointer<particle_t>.allocate(capacity: Int(PARTICLE_MAX_COUNT))
private var lastOutputCount: Int32 = 0

private func lerp(_ a: Int32, _ b: Int32, _ e1000: Int32) -> Int32 {
    a + ((b - a) * e1000) / 1000
}

/// Called by rgb_tile.c's particle timer (~20 Hz) while a particle effect is
/// active. `reset` is true on exactly the first tick after
/// rgb_tile_show_particles() is called.
@_cdecl("particle_effect_tick")
func particle_effect_tick(
    _ particles: UnsafeMutablePointer<particle_t>!,
    _ capacity: Int32,
    _ outCount: UnsafeMutablePointer<Int32>!,
    _ tileW: Int32,
    _ tileH: Int32,
    _ reset: Bool
) {
    var needsReset = reset

    ticksUntilSwitch -= 1
    if ticksUntilSwitch <= 0 {
        ticksUntilSwitch = ticksPerEffect
        switch currentEffect {
        case .starfield: currentEffect = .sphere(Sphere())
        case .sphere:    currentEffect = .starfield(Starfield())
        }
        needsReset = true
        morphElapsedTicks = 0   // start easing from whatever's in lastOutputBuffer
    }

    // This tick's "live" target from whichever effect is now current -- always
    // computed fresh, morphing or not, since e.g. Sphere keeps rotating and
    // Starfield keeps flying *during* the transition too.
    let scratch = UnsafeMutableBufferPointer(start: scratchBuffer, count: Int(capacity))
    var liveCount: Int32 = 0
    switch currentEffect {
    case .starfield(var effect):
        if needsReset { effect.reset(tileW: tileW, tileH: tileH) }
        liveCount = effect.tick(tileW: tileW, tileH: tileH, into: scratch)
        currentEffect = .starfield(effect)
    case .sphere(var effect):
        if needsReset { effect.reset(tileW: tileW, tileH: tileH) }
        liveCount = effect.tick(tileW: tileW, tileH: tileH, into: scratch)
        currentEffect = .sphere(effect)
    }

    guard morphElapsedTicks < morphDurationTicks else {
        // Not morphing: pass the live output straight through.
        for i in 0 ..< Int(liveCount) {
            particles[i] = scratch[i]
            lastOutputBuffer[i] = scratch[i]
        }
        lastOutputCount = liveCount
        outCount.pointee = liveCount
        return
    }

    // Morphing: blend each slot from its last drawn value toward this tick's
    // live target. A slot missing on one side (the old or new effect has
    // fewer particles) fades in/out in place instead of popping.
    let e1000 = MorphEase.progress(atTick: morphElapsedTicks)
    let slotCount = min(max(liveCount, lastOutputCount), capacity)

    for i in 0 ..< Int(slotCount) {
        let hasStart = i < Int(lastOutputCount)
        let hasTarget = i < Int(liveCount)

        let target = hasTarget ? scratch[i]
            : particle_t(sx: lastOutputBuffer[i].sx, sy: lastOutputBuffer[i].sy,
                         size: lastOutputBuffer[i].size, hue: lastOutputBuffer[i].hue, opa: 0)
        let start = hasStart ? lastOutputBuffer[i]
            : particle_t(sx: target.sx, sy: target.sy, size: target.size, hue: target.hue, opa: 0)

        let blended = particle_t(
            sx: lerp(start.sx, target.sx, e1000),
            sy: lerp(start.sy, target.sy, e1000),
            size: lerp(start.size, target.size, e1000),
            hue: MorphEase.hueLerp(start.hue, target.hue, e1000),
            opa: UInt8(lerp(Int32(start.opa), Int32(target.opa), e1000))
        )
        particles[i] = blended
        lastOutputBuffer[i] = blended
    }
    morphElapsedTicks += 1
    lastOutputCount = slotCount
    outCount.pointee = slotCount
}

/// Fixed-point (Q10, `scale` = 1000) easeInOutCubic, precomputed per tick
/// index instead of computed per particle -- and shortest-path hue blending,
/// matching the JS prototype's `hueLerp`. Shared by the dispatcher above.
enum MorphEase {
    static let steps: Int32 = 28   // ~1.4s at 20 Hz, matching the JS MORPH_DURATION

    static let table: [Int32] = (0...Int(steps)).map { i in
        let t = Float(i) / Float(steps)
        let e: Float
        if t < 0.5 {
            e = 4 * t * t * t
        } else {
            let f = -2 * t + 2
            e = 1 - (f * f * f) / 2
        }
        return Int32(e * 1000)
    }

    static func progress(atTick tick: Int32) -> Int32 {
        var clamped = tick
        if clamped < 0 { clamped = 0 }
        if clamped > steps { clamped = steps }
        return table[Int(clamped)]
    }

    static func hueLerp(_ a: UInt16, _ b: UInt16, _ e1000: Int32) -> UInt16 {
        let ai = Int32(a), bi = Int32(b)
        let diff = ((bi - ai + 540) % 360) - 180   // shortest path around the wheel
        let blended = ai + (diff * e1000) / 1000
        return UInt16((blended % 360 + 360) % 360)
    }
}

/// Shared sine/cosine lookup table for effects that need per-tick rotation.
/// No hardware FPU, so trig is precomputed once here (using libm -- fine for
/// a one-time cost) instead of ever being called per-particle, per-frame.
/// `steps` around the circle, fixed-point Q12 (`scale` represents 1.0).
enum TrigLUT {
    static let steps: Int32 = 256
    static let scale: Int32 = 4096
    private static let twoPi: Float = 6.2831853

    static let cosTable: [Int32] = (0 ..< Int(steps)).map { i in
        Int32(cosf(Float(i) * twoPi / Float(steps)) * Float(scale))
    }
    static let sinTable: [Int32] = (0 ..< Int(steps)).map { i in
        Int32(sinf(Float(i) * twoPi / Float(steps)) * Float(scale))
    }

    private static func wrap(_ index: Int32) -> Int {
        Int(((index % steps) + steps) % steps)
    }
    static func cos(_ index: Int32) -> Int32 { cosTable[wrap(index)] }
    static func sin(_ index: Int32) -> Int32 { sinTable[wrap(index)] }
}

/// Ambient "starfield" particle effect -- pure integer math (Embedded Swift
/// has no hardware FPU). Ported from particle_multishape_morph.html's
/// starfield: depth `z` is scaled by `zScale` and stepped down each tick;
/// screen position is one integer divide per particle, the same shape as the
/// JS `x = CX + bx/z` projection.
struct Starfield {
    static let count = 100
    static let zScale: Int32 = 1000
    static let zMin: Int32 = 20   // recycle threshold (matches the JS z <= 0.02)
    static let zStep: Int32 = 24  // depth/tick -> ~2s per particle's "flight" at 20 fps
    static let edgeMargin: Int32 = 60

    private struct Point {
        var bx: Int32 = 0
        var by: Int32 = 0
        var z: Int32 = Starfield.zScale
        var hue: UInt16 = 210
    }

    private var points: [Point]

    init() {
        points = Array(repeating: Point(), count: Starfield.count)
    }

    private static func randomOffset(within halfRange: Int32) -> Int32 {
        guard halfRange > 0 else { return 0 }
        return Int32.random(in: -halfRange...halfRange)
    }

    private mutating func spawn(_ i: Int, tileW: Int32, tileH: Int32) {
        // matches genStarfield()'s `(rand-0.5)*W*1.4`
        let halfW = (tileW * 7) / 10
        let halfH = (tileH * 7) / 10
        points[i].bx = Starfield.randomOffset(within: halfW)
        points[i].by = Starfield.randomOffset(within: halfH)
        points[i].z = Starfield.zScale
        points[i].hue = UInt16(200 + Int32.random(in: 0..<60))  // cool blue/cyan band
    }

    /// (Re)initialize every particle, staggering initial depth so they don't
    /// all recycle in lockstep the first time through.
    mutating func reset(tileW: Int32, tileH: Int32) {
        for i in 0 ..< points.count {
            spawn(i, tileW: tileW, tileH: tileH)
            points[i].z = Int32.random(in: Starfield.zMin..<Starfield.zScale)
        }
    }

    private func project(_ p: Point, cx: Int32, cy: Int32) -> (x: Int32, y: Int32) {
        (cx + (p.bx * Starfield.zScale) / p.z, cy + (p.by * Starfield.zScale) / p.z)
    }

    mutating func tick(tileW: Int32, tileH: Int32, into buffer: UnsafeMutableBufferPointer<particle_t>) -> Int32 {
        let cx = tileW / 2
        let cy = tileH / 2
        var written: Int32 = 0

        for i in 0 ..< points.count {
            points[i].z -= Starfield.zStep
            if points[i].z < 1 { points[i].z = 1 }  // guard the divide; the threshold below recycles first anyway

            var (sx, sy) = project(points[i], cx: cx, cy: cy)
            let offscreen = sx < -Starfield.edgeMargin || sx > tileW + Starfield.edgeMargin
                         || sy < -Starfield.edgeMargin || sy > tileH + Starfield.edgeMargin
            if points[i].z <= Starfield.zMin || offscreen {
                spawn(i, tileW: tileW, tileH: tileH)
                (sx, sy) = project(points[i], cx: cx, cy: cy)
            }

            var size = 2 + ((Starfield.zScale - points[i].z) * 5) / Starfield.zScale
            if size < 2 { size = 2 }
            if size > 8 { size = 8 }

            // Opacity floor kept high (~55%) -- even the farthest stars stay visible.
            var opa = 140 + ((Starfield.zScale - points[i].z) * (255 - 140)) / Starfield.zScale
            if opa < 0 { opa = 0 }
            if opa > 255 { opa = 255 }

            guard Int(written) < buffer.count else { break }
            buffer[Int(written)] = particle_t(sx: sx, sy: sy, size: size, hue: points[i].hue, opa: UInt8(opa))
            written += 1
        }
        return written
    }
}

/// Rotating sphere of points, Fibonacci-sphere sampled -- ported from
/// genSphere()/liveTargetFor('sphere') in particle_multishape_morph.html.
/// Per-particle base coordinates (bx, by, bz) are computed once in `reset`
/// using libm (cosf/sinf/sqrtf) -- fine, since that's a one-time cost per
/// activation, not per frame. The continuous per-tick rotation then uses only
/// `TrigLUT` (integer lookups) and integer math, no floats in the hot path.
struct Sphere {
    static let count = 100
    static let baseScale: Int32 = 1000   // fixed-point scale for bx/by/bz (represents -1.0...1.0)
    static let angleStep: Int32 = 2      // TrigLUT steps/tick -> ~6.4s per full rotation at 20 fps

    private struct Point {
        var bx: Int32 = 0
        var by: Int32 = 0
        var bz: Int32 = 0
        var hue: UInt16 = 210
    }

    private var points: [Point]
    private var angleIndex: Int32 = 0

    init() {
        points = Array(repeating: Point(), count: Sphere.count)
    }

    /// Fibonacci sphere sampling: evenly distributes `count` points over a
    /// unit sphere using the golden angle, same formula as the JS original.
    mutating func reset(tileW: Int32, tileH: Int32) {
        let n = Sphere.count
        for i in 0 ..< n {
            let yy = 1 - (Float(i) / Float(n - 1)) * 2         // 1 ... -1
            let radiusAtY = sqrtf(max(0, 1 - yy * yy))
            let theta: Float = 2.399963 * Float(i)             // golden angle

            points[i].bx = Int32(cosf(theta) * radiusAtY * Float(Sphere.baseScale))
            points[i].by = Int32(yy * Float(Sphere.baseScale))
            points[i].bz = Int32(sinf(theta) * radiusAtY * Float(Sphere.baseScale))
            points[i].hue = UInt16(190 + Int32.random(in: 0..<40))
        }
        angleIndex = 0
    }

    mutating func tick(tileW: Int32, tileH: Int32, into buffer: UnsafeMutableBufferPointer<particle_t>) -> Int32 {
        let cx = tileW / 2
        let cy = tileH / 2
        let radius = min(tileW, tileH) * 3 / 8   // scales with whatever tile size we're given

        let cosA = TrigLUT.cos(angleIndex)
        let sinA = TrigLUT.sin(angleIndex)
        angleIndex = (angleIndex + Sphere.angleStep) % TrigLUT.steps

        var written: Int32 = 0
        for i in 0 ..< points.count {
            guard Int(written) < buffer.count else { break }
            let p = points[i]

            // Rigid rotation around Y -- bx/bz mix, by is untouched.
            let x1 = (p.bx * cosA + p.bz * sinA) / TrigLUT.scale
            let z1 = (-p.bx * sinA + p.bz * cosA) / TrigLUT.scale

            var depth = (z1 + Sphere.baseScale) / 2   // 0 (far side) ... baseScale (near side)
            if depth < 0 { depth = 0 }
            if depth > Sphere.baseScale { depth = Sphere.baseScale }

            let sx = cx + (x1 * radius) / Sphere.baseScale
            let sy = cy + (p.by * radius) / Sphere.baseScale

            var size = (1500 + depth * 3 + 500) / 1000   // ~1.5...4.5px, rounded
            if size < 1 { size = 1 }

            var opa = 89 + (depth * 166) / 1000          // ~35%...100%
            if opa < 0 { opa = 0 }
            if opa > 255 { opa = 255 }

            buffer[Int(written)] = particle_t(sx: sx, sy: sy, size: size, hue: p.hue, opa: UInt8(opa))
            written += 1
        }
        return written
    }
}
