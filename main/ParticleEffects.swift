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
// effect is running, or that morphing/physics exist at all. This file owns
// everything about "what does the screen currently look like."
//
// Embedded Swift has no runtime type metadata, so a `protocol` +
// `any ParticleEffect` existential (the usual way to make this pluggable)
// doesn't compile here:
//
//   error: cannot use a value of protocol type 'any ParticleEffect' in
//   embedded Swift [#EmbeddedRestrictions]
//
// A closed enum stands in for that polymorphism instead. Adding a new effect
// is: write a new struct with its own state + `reset`/`targets`, add a case
// below, add one arm to `tick(_:...)` and `springDampFor(_:)`. No C changes.
//
// Ported from particle_multishape_morph_3.html, with two deliberate
// differences from the JS's own QR handling:
//
//   - Rather than the JS's clone system (temporary particles spawned per
//     module, later merged back into their parent) or clustering the whole
//     ~836-light-module field, particles target only the QR's recognizable
//     "landmarks". Each position (finder) pattern gets two concentric,
//     unfilled square outlines (qrFinderInnerRingLocal + squareRingPoints):
//     its own real inner white ring, plus a second, synthetic ring drawn
//     just past the black border -- roughly where the real separator sits
//     -- together reading as a bold corner marker, rather than a filled
//     blob or a faithful trace of the standard's own (fiddlier,
//     corner-asymmetric) separator shape. Each alignment pattern
//     (qrAlignmentCenters(version:) -- there can be 0, 1, or 6 of them,
//     depending on version) keeps its light ring as individual dots
//     (qrAlignmentRingOffsets) -- small and interior, not a corner the way
//     the finder patterns are. All of this is fixed by the standard for a
//     given version, independent of content, so it's hardcoded (per
//     version, not per URL) rather than recomputed -- and few enough
//     (under 200 points even at the largest supported version) that
//     there's no clustering to do at all.
//   - Once the skeleton has (nearly) settled, particles crossfade into the
//     real, fully-detailed, solid QR (rgb_tile.c's existing renderer, border
//     and all -- see particle_qr_prepare() / particle_qr_set_overlay_opacity()
//     and the crossfade state machine below), which is also where the actual
//     data modules and the true white color come from: it's the solid
//     renderer's own black-on-white rendering, not a particle color. The
//     crossfade starts a little before the skeleton fully settles (see
//     qrEarlyFadeLead) so the two overlap instead of a dead pause between
//     "particles stop moving" and "solid QR appears".
//
// The skeleton particles themselves are desaturated too (`sat: 0` in their
// SlotTarget), for a coherent look during the part of the transition where
// they're still visibly particles.

// MARK: - Physics-facing descriptor each effect produces per particle slot

/// What a shape wants for one particle slot, this tick: where to pull it,
/// how big/bright it should end up, and what hue. `teleport` bypasses the
/// spring entirely for a hard discontinuity (Starfield's depth-wrap) -- see
/// its use there for why chasing a teleport with a spring would look like a
/// streak across the screen instead of a star recycling.
private struct SlotTarget {
    var x: Float = 0
    var y: Float = 0
    var size: Float = 3
    var alpha: Float = 0
    var hue: Float = 210
    var sat: Float = 55   // 0-100 HSV saturation; QR uses 0 for a white look
    var teleport = false
}

// MARK: - Effect selection

enum CurrentParticleEffect {
    case starfield(Starfield)
    case sphere(Sphere)
    case cube(Cube)
    case qr(String)   // the URL to encode; regenerated (cached) only when it changes
}

private var currentEffect: CurrentParticleEffect = .starfield(Starfield())
private var previousEffect: CurrentParticleEffect?   // kept "alive" (still ticking) during a blend-out

// TEST ONLY: cycle through effects every 5s so they're all easy to see
// without wiring up a real trigger yet (a BLE property, a button, ...). This
// counter is driven by the same timer as everything else, so `ticksPerEffect`
// must track PARTICLE_TICK_MS in rgb_tile.c (currently 50 ms -> 20 Hz).
// Remove this block once you've settled on how effects should actually switch.
private let ticksPerEffect: Int32 = 5 * 20  // 5s * 20 Hz
private var ticksUntilSwitch: Int32 = ticksPerEffect

// Crossfade from the particle-formed QR silhouette to the real, fully-
// detailed solid QR (rgb_tile.c's existing renderer) once the particles have
// settled, and back again before the effect moves on. `.faded` (distinct
// from `.none`) marks "finished fading out, just waiting for the scheduled
// switch to actually leave .qr" -- without it, the very next tick would see
// "still in .qr, blend already done" and immediately restart fadingIn.
private enum QRCrossfade: Equatable {
    case none
    case fadingIn(Float)   // 0...1
    case holding
    case fadingOut(Float)  // 1...0
    case faded
}
private var qrCrossfade: QRCrossfade = .none
private let qrFadeDuration: Float = 0.3   // seconds
private let qrFadeLeadTicks = Int32((0.25 / 0.05).rounded())  // start fading out this many ticks before the scheduled switch
private let qrEarlyFadeLead: Float = 0.25  // start solidifying this long before the skeleton would otherwise finish settling

// MARK: - Physics tuning (ported from the JS prototype's constants)

private let tickDt: Float = 0.05           // PARTICLE_TICK_MS in rgb_tile.c, as seconds

// The spring/damping constants below were tuned (in the JS prototype) against
// ~60fps physics steps. Our LVGL timer only ticks at 20Hz, which is too
// coarse a timestep for this stiffness to integrate stably (explicit-Euler
// spring integrators want a small step relative to their natural frequency).
// Sub-stepping the integration 3x per tick, at the original ~60fps step size,
// reproduces the same per-step dynamics as the prototype instead of retuning
// every constant for a coarser step.
private let physicsSubsteps = 3
private let substepDt: Float = 1.0 / 60.0

private let staggerMax: Float = 0.35       // seconds; per-particle random delay before it responds to a new shape
private let blendDuration: Float = 0.55    // seconds; force blends from old shape's pull to new shape's over this long
private let fadeRate: Float = 1 - expf(-0.05 / 0.22)   // size/alpha follow their target with this time constant
private let hueRate: Float = 1 - expf(-0.05 / 0.9)     // hue chases its target hue with this (slower) time constant

// MARK: - Persistent per-particle physical state (dispatcher-owned; effects never see this)

private struct Slot {
    var x: Float = 0, y: Float = 0
    var vx: Float = 0, vy: Float = 0
    var dispSize: Float = 3
    var dispAlpha: Float = 0
    var dispSat: Float = 55
    var hue: Float = 210
    var staggerDelay: Float = 0
}
private var slots = [Slot](repeating: Slot(), count: Int(PARTICLE_MAX_COUNT))
private var transitionElapsed: Float = 1000   // seconds since the last switch; large == "not blending"

// A fixed permutation from persistent particle index -> target-array index,
// applied uniformly no matter which shape generated the target array. Without
// it, particle i always reads target i from every shape in turn, and since
// shapes build targets in systematic order (raster, edge-by-edge, latitude
// band), whole rows/edges would visibly sweep together on every switch
// instead of scattering organically. Computed once at boot.
private let particleOrder: [Int] = Array(0 ..< Int(PARTICLE_MAX_COUNT)).shuffled()

private var scratchNew = [SlotTarget](repeating: SlotTarget(), count: Int(PARTICLE_MAX_COUNT))
private var scratchOld = [SlotTarget](repeating: SlotTarget(), count: Int(PARTICLE_MAX_COUNT))

private func smoothstep(_ t: Float) -> Float { t * t * (3 - 2 * t) }

private func hueLerpShortestPath(_ h: Float, _ target: Float, _ rate: Float) -> Float {
    var diff = (target - h).truncatingRemainder(dividingBy: 360)
    if diff > 180 { diff -= 360 }
    if diff < -180 { diff += 360 }
    var result = (h + diff * rate).truncatingRemainder(dividingBy: 360)
    if result < 0 { result += 360 }
    return result
}

private func springDampFor(_ effect: CurrentParticleEffect) -> (k: Float, damping: Float) {
    switch effect {
    case .starfield: return (Starfield.springK, Starfield.damping)
    case .sphere:    return (Sphere.springK, Sphere.damping)
    case .cube:      return (Cube.springK, Cube.damping)
    case .qr:        return (Sphere.springK, Sphere.damping)  // same "settle into formation" role as sphere/cube
    }
}

/// Advances whichever effect this is (mutating its own per-tick state --
/// Starfield's depth, Sphere/Cube's rotation angle) and fills `out` with its
/// live targets for right now. Used for both the current and (while blending)
/// the outgoing effect, so an outgoing sphere keeps rotating away instead of
/// freezing the instant you switch off it.
private func tick(_ effect: inout CurrentParticleEffect, tileW: Int32, tileH: Int32, into out: inout [SlotTarget]) -> Int32 {
    switch effect {
    case .starfield(var e):
        let n = e.targets(tileW: tileW, tileH: tileH, into: &out)
        effect = .starfield(e)
        return n
    case .sphere(var e):
        let n = e.targets(tileW: tileW, tileH: tileH, into: &out)
        effect = .sphere(e)
        return n
    case .cube(var e):
        let n = e.targets(tileW: tileW, tileH: tileH, into: &out)
        effect = .cube(e)
        return n
    case .qr:
        return qrTargets(tileW: tileW, tileH: tileH, into: &out)
    }
}

/// The fallback target for a slot that the *active* shape on one side of a
/// blend simply has no target for -- e.g. QR's skeleton (152 points) uses
/// slots that Cube (96) or Starfield/Sphere (100) never touch. Placed on a
/// ring safely outside the tile (not "wherever the slot's own last position
/// happens to be" -- the previous approach), so:
///   - entering an effect that needs a previously-idle slot, the blend reads
///     this as the *old* target -- the particle flies in from off-screen.
///   - leaving an effect that needed a slot the next one doesn't, this is
///     the *new* target -- the particle flies back out, instead of just
///     fading in place at its last on-screen spot.
/// Fixed per slot index (not random per call) so an idle particle settles at
/// one resting point rather than drifting every tick.
private func parkedTarget(_ i: Int, tileW: Int32, tileH: Int32) -> SlotTarget {
    let w = Float(tileW), h = Float(tileH)
    let cx = w / 2, cy = h / 2
    let radius = max(w, h)   // comfortably past every edge, whatever the tile's aspect ratio
    let angleIdx = Int32((i * 41) % Int(TrigLUT.steps))   // spread idle particles around, not lockstep
    return SlotTarget(
        x: cx + TrigLUT.cos(angleIdx) * radius,
        y: cy + TrigLUT.sin(angleIdx) * radius,
        alpha: 0
    )
}

/// Resets whichever effect `currentEffect` currently is, and (re)arms the
/// per-particle stagger delays for a fresh transition.
private func beginTransition(tileW: Int32, tileH: Int32) {
    switch currentEffect {
    case .starfield(var e): e.reset(tileW: tileW, tileH: tileH); currentEffect = .starfield(e)
    case .sphere(var e):    e.reset(tileW: tileW, tileH: tileH); currentEffect = .sphere(e)
    case .cube(var e):      e.reset(tileW: tileW, tileH: tileH); currentEffect = .cube(e)
    case .qr(let url):
        // Encode right away (not lazily at crossfade time) so
        // particle_qr_modules() is valid from this effect's very first tick
        // -- qrTargets() needs the actual module count immediately to lay
        // out the skeleton, now that it's no longer a fixed compile-time
        // size. Cheap and idempotent to call again later if the crossfade
        // machinery also calls it (it doesn't need to anymore, but doesn't
        // hurt if it did).
        url.withCString { particle_qr_prepare($0) }
    }
    for i in 0 ..< slots.count {
        slots[i].staggerDelay = Float.random(in: 0...staggerMax)
    }
    transitionElapsed = 0
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
    if reset {
        previousEffect = nil   // fresh activation: nothing to blend from
        qrCrossfade = .none
        particle_qr_set_overlay_opacity(0)
        beginTransition(tileW: tileW, tileH: tileH)
    }

    if ticksUntilSwitch > 0 { ticksUntilSwitch -= 1 }

    // Don't leave .qr mid-crossfade -- wait for a full fade-out first (the
    // .holding case below starts that fade-out on its own, early enough to
    // finish before ticksUntilSwitch would otherwise force the issue).
    let qrGateOpen: Bool = {
        if case .qr = currentEffect { return qrCrossfade == .none || qrCrossfade == .faded }
        return true
    }()

    if ticksUntilSwitch <= 0 && qrGateOpen {
        ticksUntilSwitch = ticksPerEffect
        previousEffect = currentEffect
        switch currentEffect {
        case .starfield: currentEffect = .sphere(Sphere())
        case .sphere:    currentEffect = .cube(Cube())
        case .cube:      currentEffect = .starfield(Starfield())
        // .qr is no longer part of the DemoEffects auto-cycle (dropped per
        // request) -- kept here only for CurrentParticleEffect's switch
        // exhaustiveness. Currently unreachable: nothing else switches
        // *into* .qr anymore, so all the crossfade/skeleton machinery below
        // that exists for it is dead code for now, not deleted in case it
        // gets wired up some other way later (e.g. its own command).
        case .qr:        currentEffect = .starfield(Starfield())
        }
        qrCrossfade = .none
        particle_qr_set_overlay_opacity(0)
        beginTransition(tileW: tileW, tileH: tileH)
    }

    let newCount = tick(&currentEffect, tileW: tileW, tileH: tileH, into: &scratchNew)
    let (newK, newDamping) = springDampFor(currentEffect)

    var oldCount: Int32 = 0
    var oldK: Float = 0, oldDamping: Float = 0
    let blending = previousEffect != nil
    if blending {
        (oldK, oldDamping) = springDampFor(previousEffect!)
        var prev = previousEffect!
        oldCount = tick(&prev, tileW: tileW, tileH: tileH, into: &scratchOld)
        previousEffect = prev
    }

    var written: Int32 = 0
    for i in 0 ..< Int(capacity) {
        let targetIdx = particleOrder[i]

        let newT: SlotTarget = targetIdx < Int(newCount)
            ? scratchNew[targetIdx]
            : parkedTarget(i, tileW: tileW, tileH: tileH)

        var target = newT
        var k = newK, damping = newDamping

        if blending {
            let localT = min(max((transitionElapsed - slots[i].staggerDelay) / blendDuration, 0), 1)
            let ease = smoothstep(localT)
            if ease < 1 {
                let oldT: SlotTarget = targetIdx < Int(oldCount)
                    ? scratchOld[targetIdx]
                    : parkedTarget(i, tileW: tileW, tileH: tileH)

                target.x = oldT.x + (newT.x - oldT.x) * ease
                target.y = oldT.y + (newT.y - oldT.y) * ease
                target.size = oldT.size + (newT.size - oldT.size) * ease
                target.alpha = oldT.alpha + (newT.alpha - oldT.alpha) * ease
                target.sat = oldT.sat + (newT.sat - oldT.sat) * ease
                target.teleport = newT.teleport || oldT.teleport
                k = oldK + (newK - oldK) * ease
                damping = oldDamping + (newDamping - oldDamping) * ease
            }
        }

        if target.teleport {
            // A hard discontinuity (e.g. Starfield recycling a star far away)
            // -- snap straight there instead of springing across the screen.
            slots[i].x = target.x
            slots[i].y = target.y
            slots[i].vx = 0
            slots[i].vy = 0
            slots[i].dispSize = target.size
            slots[i].dispAlpha = target.alpha
            slots[i].dispSat = target.sat
        } else {
            for _ in 0 ..< physicsSubsteps {
                let fx = (target.x - slots[i].x) * k
                let fy = (target.y - slots[i].y) * k
                slots[i].vx += (fx - damping * slots[i].vx) * substepDt
                slots[i].vy += (fy - damping * slots[i].vy) * substepDt
                slots[i].x += slots[i].vx * substepDt
                slots[i].y += slots[i].vy * substepDt
            }
            slots[i].dispSize += (target.size - slots[i].dispSize) * fadeRate
            slots[i].dispAlpha += (target.alpha - slots[i].dispAlpha) * fadeRate
            slots[i].dispSat += (target.sat - slots[i].dispSat) * fadeRate
        }

        slots[i].hue = hueLerpShortestPath(slots[i].hue, target.hue, hueRate)

        if slots[i].dispAlpha > 0.02, Int(written) < Int(capacity) {
            let hue = slots[i].hue < 0 ? slots[i].hue + 360 : slots[i].hue
            particles[Int(written)] = particle_t(
                sx: Int32(slots[i].x.rounded()),
                sy: Int32(slots[i].y.rounded()),
                size: Int32(max(slots[i].dispSize, 1).rounded()),
                hue: UInt16(hue),
                sat: UInt8(min(max(slots[i].dispSat, 0), 100).rounded()),
                opa: UInt8((min(max(slots[i].dispAlpha, 0), 1) * 255).rounded())
            )
            written += 1
        }
    }

    if blending, transitionElapsed >= staggerMax + blendDuration {
        previousEffect = nil
    }
    transitionElapsed += tickDt
    outCount.pointee = written

    // Drive the QR crossfade: solidify into the real QR once the particles
    // have settled into its silhouette, hold, then fade back to particles
    // before the scheduled switch (gated above) actually leaves .qr.
    if case .qr = currentEffect {
        switch qrCrossfade {
        case .none:
            // Start solidifying a little before the skeleton would otherwise
            // finish settling (rather than waiting for `!blending`), so the
            // tail of the particle motion and the start of the crossfade
            // overlap instead of a dead pause in between. Encoding already
            // happened when this effect became current (beginTransition's
            // .qr case) -- particle_qr_modules()/qr_buf are valid already.
            if transitionElapsed >= (staggerMax + blendDuration) - qrEarlyFadeLead {
                qrCrossfade = .fadingIn(0)
            }
        case .fadingIn(let t):
            let nt = min(t + tickDt / qrFadeDuration, 1)
            particle_qr_set_overlay_opacity(UInt8(nt * 255))
            qrCrossfade = nt >= 1 ? .holding : .fadingIn(nt)
        case .holding:
            if ticksUntilSwitch <= qrFadeLeadTicks {
                qrCrossfade = .fadingOut(1)
            }
        case .fadingOut(let t):
            let nt = max(t - tickDt / qrFadeDuration, 0)
            particle_qr_set_overlay_opacity(UInt8(nt * 255))
            qrCrossfade = nt <= 0 ? .faded : .fadingOut(nt)
        case .faded:
            break   // waiting for the gated switch (above, next tick) to actually leave .qr
        }
    } else if qrCrossfade != .none {
        qrCrossfade = .none
        particle_qr_set_overlay_opacity(0)
    }
}

// MARK: - Shared rotation lookup

/// Shared sine/cosine lookup table for effects that need per-tick rotation.
/// No hardware FPU, so trig is precomputed once here (using libm -- fine for
/// a one-time cost) instead of ever being called per-particle, per-frame.
/// `steps` around the circle.
enum TrigLUT {
    static let steps: Int32 = 256
    private static let twoPi: Float = 6.2831853

    static let cosTable: [Float] = (0 ..< Int(steps)).map { i in cosf(Float(i) * twoPi / Float(steps)) }
    static let sinTable: [Float] = (0 ..< Int(steps)).map { i in sinf(Float(i) * twoPi / Float(steps)) }

    private static func wrap(_ index: Int32) -> Int {
        Int(((index % steps) + steps) % steps)
    }
    static func cos(_ index: Int32) -> Float { cosTable[wrap(index)] }
    static func sin(_ index: Int32) -> Float { sinTable[wrap(index)] }
}

// MARK: - Starfield

/// Ambient "starfield" particle effect. Depth `z` (0.02 ... 1.0) shrinks each
/// tick; screen position is one divide per particle: `x = CX + bx/z`, same as
/// the JS prototype. When a star passes the camera or drifts off-tile, it's
/// respawned far away -- flagged `teleport` so the dispatcher snaps it there
/// instead of springing across the screen as a visible streak.
struct Starfield {
    static let count = 100
    static let springK: Float = 260
    static let damping: Float = 30
    static let zSpeedPerSecond: Float = 0.48
    static let edgeMargin: Float = 60

    private struct Point {
        var bx: Float = 0
        var by: Float = 0
        var z: Float = 1
        var hue: Float = 210
    }
    private var points: [Point]

    init() {
        points = Array(repeating: Point(), count: Starfield.count)
    }

    private mutating func spawn(_ i: Int, tileW: Float, tileH: Float) {
        points[i].bx = Float.random(in: -(tileW * 0.7)...(tileW * 0.7))
        points[i].by = Float.random(in: -(tileH * 0.7)...(tileH * 0.7))
        points[i].z = 1
        points[i].hue = 200 + Float.random(in: 0..<60)  // cool blue/cyan band
    }

    /// (Re)initialize every particle, staggering initial depth so they don't
    /// all recycle in lockstep the first time through.
    mutating func reset(tileW: Int32, tileH: Int32) {
        let w = Float(tileW), h = Float(tileH)
        for i in 0 ..< points.count {
            spawn(i, tileW: w, tileH: h)
            points[i].z = Float.random(in: 0.02...1)
        }
    }

    fileprivate mutating func targets(tileW: Int32, tileH: Int32, into out: inout [SlotTarget]) -> Int32 {
        let w = Float(tileW), h = Float(tileH)
        let cx = w / 2, cy = h / 2

        for i in 0 ..< points.count {
            points[i].z -= tickDt * Starfield.zSpeedPerSecond

            var projX = cx + points[i].bx / points[i].z
            var projY = cy + points[i].by / points[i].z
            var teleport = false

            if points[i].z <= 0.02
                || projX < -Starfield.edgeMargin || projX > w + Starfield.edgeMargin
                || projY < -Starfield.edgeMargin || projY > h + Starfield.edgeMargin {
                spawn(i, tileW: w, tileH: h)
                projX = cx + points[i].bx / points[i].z
                projY = cy + points[i].by / points[i].z
                teleport = true
            }

            // Size/alpha floor raised well above the JS original (1px/~25%)
            // so even the farthest stars stay clearly visible on this panel.
            let size = min(max(2 + (1 - points[i].z) * 6, 2), 8)
            let alpha = min(max(0.55 + (1 - points[i].z) * 0.45, 0), 1)

            out[i] = SlotTarget(x: projX, y: projY, size: size, alpha: alpha, hue: points[i].hue, teleport: teleport)
        }
        return Int32(points.count)
    }
}

// MARK: - Sphere

/// Rotating sphere of points, Fibonacci-sphere sampled -- ported from
/// genSphere()/liveTargetFor('sphere'). Per-particle base coordinates
/// (bx, by, bz) are computed once in `reset` using libm (cosf/sinf/sqrtf) --
/// fine, since that's a one-time cost per activation, not per frame. The
/// continuous per-tick rotation then uses only `TrigLUT`.
struct Sphere {
    static let count = 100
    static let springK: Float = 90
    static let damping: Float = 14
    static let angleStep: Int32 = 2   // TrigLUT steps/tick -> ~6.4s per full rotation at 20 fps

    private struct Point {
        var bx: Float = 0
        var by: Float = 0
        var bz: Float = 0
        var hue: Float = 210
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

            points[i].bx = cosf(theta) * radiusAtY
            points[i].by = yy
            points[i].bz = sinf(theta) * radiusAtY
            points[i].hue = 190 + Float.random(in: 0..<40)
        }
        angleIndex = 0
    }

    fileprivate mutating func targets(tileW: Int32, tileH: Int32, into out: inout [SlotTarget]) -> Int32 {
        let w = Float(tileW), h = Float(tileH)
        let cx = w / 2, cy = h / 2
        let radius = min(w, h) * 0.375

        let cosA = TrigLUT.cos(angleIndex)
        let sinA = TrigLUT.sin(angleIndex)
        angleIndex = (angleIndex + Sphere.angleStep) % TrigLUT.steps

        for i in 0 ..< points.count {
            let p = points[i]
            let x = p.bx * cosA + p.bz * sinA
            let z = -p.bx * sinA + p.bz * cosA
            let depth = (z + 1) / 2   // 0 (far side) ... 1 (near side)

            out[i] = SlotTarget(
                x: cx + x * radius, y: cy + p.by * radius,
                size: 1.5 + depth * 3, alpha: 0.35 + depth * 0.65,
                hue: p.hue
            )
        }
        return Int32(points.count)
    }
}

// MARK: - Cube

/// Rotating wireframe cube, points spread along its 12 edges -- ported from
/// genCube()/liveTargetFor('cube'). Rotation around Y uses the shared
/// TrigLUT; the fixed 3/4-view tilt is a single precomputed sin/cos pair
/// (computed once, like the LUT, not per particle).
struct Cube {
    static let count = 96   // 12 edges * 8 points/edge -- divides evenly, unlike 100
    static let springK: Float = 90
    static let damping: Float = 14
    static let angleStep: Int32 = 2
    static let focal: Float = 260

    private static let tiltCos: Float = cosf(0.5)   // fixed radians -- a nice 3/4 view of the cube
    private static let tiltSin: Float = sinf(0.5)

    private struct Point {
        var bx: Float = 0
        var by: Float = 0
        var bz: Float = 0
        var hue: Float = 40
    }
    private var points: [Point]
    private var angleIndex: Int32 = 0

    init() {
        points = Array(repeating: Point(), count: Cube.count)
    }

    mutating func reset(tileW: Int32, tileH: Int32) {
        let corners: [(Float, Float, Float)] = [
            (-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1),
            (-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1),
        ]
        let edges: [(Int, Int)] = [
            (0, 1), (1, 2), (2, 3), (3, 0),
            (4, 5), (5, 6), (6, 7), (7, 4),
            (0, 4), (1, 5), (2, 6), (3, 7),
        ]
        let perEdge = Cube.count / edges.count
        var idx = 0
        for (a, b) in edges {
            let ca = corners[a], cb = corners[b]
            for k in 0 ..< perEdge {
                let t = Float(k) / Float(perEdge - 1)
                points[idx].bx = ca.0 + (cb.0 - ca.0) * t
                points[idx].by = ca.1 + (cb.1 - ca.1) * t
                points[idx].bz = ca.2 + (cb.2 - ca.2) * t
                points[idx].hue = 30 + Float.random(in: 0..<30)
                idx += 1
            }
        }
        angleIndex = 0
    }

    fileprivate mutating func targets(tileW: Int32, tileH: Int32, into out: inout [SlotTarget]) -> Int32 {
        let w = Float(tileW), h = Float(tileH)
        let cx = w / 2, cy = h / 2
        let radius = min(w, h) * 0.3

        let cosA = TrigLUT.cos(angleIndex)
        let sinA = TrigLUT.sin(angleIndex)
        angleIndex = (angleIndex + Cube.angleStep) % TrigLUT.steps

        for i in 0 ..< points.count {
            let p = points[i]

            // Spin around Y, then a fixed tilt around X -- both rigid
            // rotations, so every edge stays the same length.
            let x1 = p.bx * cosA + p.bz * sinA
            let z1 = -p.bx * sinA + p.bz * cosA
            let y1 = p.by

            let y2 = y1 * Cube.tiltCos - z1 * Cube.tiltSin
            let z2 = y1 * Cube.tiltSin + z1 * Cube.tiltCos

            // Perspective divide: points further from the camera shrink.
            let worldZ = z2 * radius
            let scale = Cube.focal / (Cube.focal + worldZ + radius)

            out[i] = SlotTarget(
                x: cx + x1 * radius * scale, y: cy + y2 * radius * scale,
                size: min(max(2.5 * scale, 1), 6),
                alpha: min(max(0.25 + scale * 0.55, 0.15), 1),
                hue: p.hue
            )
        }
        return Int32(points.count)
    }
}

// MARK: - QR (particle silhouette, not the scannable renderer)

/// Each position (finder) pattern gets TWO concentric, unfilled square
/// outlines, not a filled blob:
///   - The real inner white ring -- the standard finder pattern's own
///     built-in 5x5 light ring (between its 7x7 dark border and 3x3 dark
///     center). 16 modules, same relative shape at every corner, so it's a
///     single local (corner-relative) list applied with each corner's offset.
///   - A second, synthetic outer ring drawn just past the 7x7's black
///     border (see qrOuterRingMargin), roughly where the real separator
///     sits, so the two rings together read as concentric squares framing a
///     bold corner marker -- rather than trying to match the standard's own
///     (corner-asymmetric) separator shape exactly.
/// (corner.x, corner.y) is each finder pattern's own top-left corner (the
/// pure 7x7, not including the separator) -- always (0,0), (modules-7,0),
/// (0,modules-7) regardless of version, so this is computed in qrTargets()
/// from the actual (runtime) module count rather than stored here.
private let qrFinderInnerRingLocal: [(x: Float, y: Float)] = [
    (1, 1), (2, 1), (3, 1), (4, 1), (5, 1),
    (1, 2), (5, 2),
    (1, 3), (5, 3),
    (1, 4), (5, 4),
    (1, 5), (2, 5), (3, 5), (4, 5), (5, 5),
]
private let qrFinderHalfWidth: Float = 3.5        // pure 7x7 finder pattern, half-width in modules
private let qrOuterRingMargin: Float = 1          // just past the black 7x7 border -- roughly the separator's own width
private let qrOuterRingHalfSize: Float = qrFinderHalfWidth + qrOuterRingMargin
// 8 points/side: at this ring's radius (halfSize 4.5 modules) that's ~5.6px
// between points, just under the 5.5px dot size (cellPx * 1.1) -- dots
// touch almost exactly, reading as a solid outline instead of dashes.
private let qrOuterRingPointsPerSide = 8

/// The 8 cells surrounding an alignment pattern's center -- same relative
/// shape at every alignment pattern, every version (a 3x3 block's light
/// ring, center excluded), so -- like qrFinderInnerRingLocal -- it's one
/// constant applied at each center's own offset.
private let qrAlignmentRingOffsets: [(x: Int32, y: Int32)] = [
    (-1, -1), (0, -1), (1, -1),
    (-1, 0), (1, 0),
    (-1, 1), (0, 1), (1, 1),
]

/// Alignment-pattern centers by QR version (1-10; version 1 has none).
/// Unlike the finder pattern (fixed 7x7 shape, corner position only depends
/// on module count) the alignment pattern's *count* and positions genuinely
/// vary by version -- versions 2-6 have exactly one, versions 7-10 have six
/// (the standard's own position table, minus the three combinations that
/// would sit on top of a finder pattern).
///
/// These are NOT copied from the spec's table by hand -- verified instead by
/// an exhaustive host-side scan of qrcodegen's own output at each forced
/// version (find every position whose 5x5 neighborhood is both the standard
/// ring/ring/center-dot shape AND identical between two very different
/// payloads, i.e. content-independent). Worth doing: two of the positions
/// recalled from memory for versions 9-10 were wrong (46/50, not 48/54).
private func qrAlignmentCenters(version: Int32) -> [(x: Int32, y: Int32)] {
    switch version {
    case 1: return []
    case 2: return [(18, 18)]
    case 3: return [(22, 22)]
    case 4: return [(26, 26)]
    case 5: return [(30, 30)]
    case 6: return [(34, 34)]
    case 7: return [(22, 6), (6, 22), (22, 22), (38, 22), (22, 38), (38, 38)]
    case 8: return [(24, 6), (6, 24), (24, 24), (42, 24), (24, 42), (42, 42)]
    case 9: return [(26, 6), (6, 26), (26, 26), (46, 26), (26, 46), (46, 46)]
    case 10: return [(28, 6), (6, 28), (28, 28), (50, 28), (28, 50), (50, 50)]
    default: return []   // shouldn't happen -- qr_generate() is capped at version 10
    }
}

/// Evenly spaced points around a square's perimeter, walking clockwise from
/// the top-left corner -- `pointsPerSide` per edge, no corner counted twice.
/// Continuous module-coordinate space (not module indices), since this ring
/// is a decorative shape, not real QR data.
private func squareRingPoints(centerX: Float, centerY: Float, halfSize: Float, pointsPerSide: Int) -> [(x: Float, y: Float)] {
    let n = Float(pointsPerSide)
    let span = 2 * halfSize
    var points: [(x: Float, y: Float)] = []
    points.reserveCapacity(pointsPerSide * 4)
    for i in 0 ..< pointsPerSide {
        let t = Float(i) / n
        points.append((centerX - halfSize + t * span, centerY - halfSize))   // top, left -> right
    }
    for i in 0 ..< pointsPerSide {
        let t = Float(i) / n
        points.append((centerX + halfSize, centerY - halfSize + t * span))   // right, top -> bottom
    }
    for i in 0 ..< pointsPerSide {
        let t = Float(i) / n
        points.append((centerX + halfSize - t * span, centerY + halfSize))   // bottom, right -> left
    }
    for i in 0 ..< pointsPerSide {
        let t = Float(i) / n
        points.append((centerX - halfSize, centerY + halfSize - t * span))   // left, bottom -> top
    }
    return points
}

/// Maps the finder rings + alignment dots into pixel-space SlotTargets.
/// Reads the actual (runtime, dynamic-version) module count and per-module
/// pixel size from rgb_tile.c -- particle_qr_modules()/
/// particle_qr_px_per_module() -- so the particle silhouette lines up with
/// whatever size the solid QR it crossfades into actually draws at. Doesn't
/// touch qrcodegen itself; encoding already happened when this effect became
/// current (beginTransition's .qr case), which is what makes those two
/// getters valid here.
private func qrTargets(tileW: Int32, tileH: Int32, into out: inout [SlotTarget]) -> Int32 {
    let modules = particle_qr_modules()
    guard modules > 0 else { return 0 }   // not encoded yet (shouldn't happen post-beginTransition, but stay defensive)

    let cellPx = Float(particle_qr_px_per_module(tileW, tileH))
    let qrPx = Float(modules) * cellPx
    let originX = (Float(tileW) - qrPx) / 2
    // Matches draw_qr's own top-aligned vertical placement (rgb_tile.c) --
    // flush to the tile's top edge, quiet-zone margin and all, rather than
    // centered, so the crossfade lines up with what it settles into.
    let originY = Float(QR_LAYOUT_QUIET_MODULES) * cellPx
    let dotSize = cellPx * 1.1

    // modules = 4*version + 17 exactly, for every version -- integer
    // division is exact here, never truncating a real fraction away.
    let version = (modules - 17) / 4

    var written = 0

    let corners: [(x: Float, y: Float)] = [
        (0, 0), (Float(modules) - 7, 0), (0, Float(modules) - 7),
    ]
    for corner in corners {
        // Real inner white ring -- module indices, so +0.5 to each cell's center.
        for local in qrFinderInnerRingLocal {
            guard written < out.count else { return Int32(written) }
            out[written] = SlotTarget(
                x: originX + (corner.x + local.x + 0.5) * cellPx,
                y: originY + (corner.y + local.y + 0.5) * cellPx,
                size: dotSize, alpha: 1, hue: 0, sat: 0
            )
            written += 1
        }

        // Synthetic outer ring -- already continuous module-coordinate
        // space (qrFinderHalfWidth is the finder pattern's true center
        // offset, not an index), so no extra +0.5 here.
        let centerX = corner.x + qrFinderHalfWidth
        let centerY = corner.y + qrFinderHalfWidth
        for p in squareRingPoints(centerX: centerX, centerY: centerY, halfSize: qrOuterRingHalfSize, pointsPerSide: qrOuterRingPointsPerSide) {
            guard written < out.count else { return Int32(written) }
            out[written] = SlotTarget(
                x: originX + p.x * cellPx,
                y: originY + p.y * cellPx,
                size: dotSize, alpha: 1, hue: 0, sat: 0
            )
            written += 1
        }
    }

    for center in qrAlignmentCenters(version: version) {
        for offset in qrAlignmentRingOffsets {
            guard written < out.count else { return Int32(written) }
            out[written] = SlotTarget(
                x: originX + (Float(center.x + offset.x) + 0.5) * cellPx,
                y: originY + (Float(center.y + offset.y) + 0.5) * cellPx,
                size: dotSize, alpha: 1, hue: 0, sat: 0
            )
            written += 1
        }
    }

    return Int32(written)
}
