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

/// The buttons on this unit are hard to physically reach, so re-pairing is
/// triggered by a held gesture instead: hold the unit upside-down while
/// powering it up. Checked once at boot, before anything BLE-related, so it
/// works independent of whether pairing/advertising even come up
/// successfully. Exits immediately (no delay) if the unit isn't upside-down
/// the very first time it checks -- this only costs boot time when the
/// gesture is actually being performed.
private func checkUpsideDownPairingReset() {
    let pollIntervalTicks: UInt32 = 10   // 100ms at CONFIG_FREERTOS_HZ=100
    let requiredGoodPolls = 50           // 50 * 100ms = 5s of (tolerantly) continuous upside-down
    let maxBadStreak = 3                 // ~300ms of consecutive contrary readings before giving up

    // Physically flipping the device by hand adds real rotational/dynamic
    // acceleration on top of gravity, easily enough to briefly saturate the
    // accelerometer's +-4g range right as the flip happens (a genuine
    // reading, not sensor noise -- confirmed on a real unit: one flip
    // produced a saturated -32768 sample before settling). Aborting on the
    // very first non-matching sample would make the gesture fail on nearly
    // every real attempt, so a short streak of contrary readings is
    // tolerated (without resetting the accumulated good time) rather than
    // treated as "gesture abandoned."
    var goodPolls = 0
    var badStreak = 0
    while goodPolls < requiredGoodPolls {
        if qmi8658_is_upside_down() {
            goodPolls += 1
            badStreak = 0
        } else {
            badStreak += 1
            guard badStreak < maxBadStreak else { return }   // exits with no delay on the very first check
        }
        vTaskDelay(pollIntervalTicks)
    }

    // Held upside-down for the full 5 seconds -- clear the stored trust and
    // let the normal startup path (pairingStartupCheck(), called once the
    // BLE address is available below) notice there's none and open a fresh
    // pairing window / show its QR, rather than duplicating that here.
    print("Held upside-down for 5s at boot -- resetting pairing")
    pairing_clear_trust()
}

// MARK: - Pairing screen alternation

// While a pairing window is open, the display alternates between the QR
// and a plain-language helper screen every few seconds, rather than
// leaving the QR up indefinitely with no context for what it's for.
private var pairingQRPayload: String?
private var pairingAlternateShowingQR = true
private var pairingAlternateTicksElapsed: UInt32 = 0
private let pairingAlternateIntervalTicks: UInt32 = 500   // 5s at 10ms/tick
private let pairingHelperText = "Scan the code under Settings -> CFDs in Ka-ching POS to pair"

/// Called every main-loop tick (~10ms). A no-op once pairingQRPayload is
/// nil (nothing to alternate) or the window has closed (paired, timed out,
/// or locked out) -- pairingTick()/handleClientConfirm already put the
/// right thing back on screen in those cases, this just stops interfering.
private func pairingAlternateTick() {
    guard pairingQRPayload != nil, pairing_window_is_open() else { return }

    pairingAlternateTicksElapsed += 1
    guard pairingAlternateTicksElapsed >= pairingAlternateIntervalTicks else { return }
    pairingAlternateTicksElapsed = 0

    pairingAlternateShowingQR.toggle()
    if pairingAlternateShowingQR {
        pairingQRPayload?.withCString { show_qr_persistent($0) }
    } else {
        pairingHelperText.withCString { show_message_persistent($0) }
    }
}

@_cdecl("app_main")
func app_main() {
    print("Hello from Swift on ESP32-C6!")
    initialize()
    checkUpsideDownPairingReset()

    var bluetooth: NimBLE
    do {
        bluetooth = try NimBLE()
    } catch {
        print("Bluetooth init failed \(error)")
        return
    }

    do {
        // read address
        let address = try bluetooth.hostController.address()
        print("Bluetooth address: \(address)")

        // register the control service — must happen before advertising starts
        try setupGATTServer()
        print("GATT server registered")

        // First boot ever (or right after a re-pair reset): no trusted
        // client stored, so show the pairing QR immediately instead of the
        // usual idle particle effect. See docs/ble-provisioning.md.
        if let pop = pairingStartupCheck() {
            let name = "Ka-ching " + address.description
            let payload = "{\"v\":1,\"name\":\"\(name)\",\"svc\":\"\(controlServiceUUIDString)\",\"pop\":\"\(pop)\"}"
            print("Awaiting pairing. POP: \(pop)")
            pairingQRPayload = payload
            pairingAlternateShowingQR = true
            pairingAlternateTicksElapsed = 0
            payload.withCString { show_qr_persistent($0) }
        }

        // Advertise the control service UUID so a central (e.g. an iOS app doing
        // scanForPeripherals(withServices:)) can discover and filter for us.
        guard let controlServiceUUID = UUID(uuidString: controlServiceUUIDString) else {
            fatalError("Invalid control service UUID")
        }
        let flags: GAPFlags = [.lowEnergyGeneralDiscoverableMode, .notSupportedBREDR]
        let serviceUUIDs = GAPCompleteListOf128BitServiceUUIDs(uuids: [controlServiceUUID])
        let advertisement: LowEnergyAdvertisingData = GAPDataEncoder.encode(flags, serviceUUIDs)
        try bluetooth.gap.setAdvertisement(advertisement)

        // set scan response
        let name = GAPShortLocalName(name: "Ka-ching " + address.description)
        let scanResponse: LowEnergyAdvertisingData = GAPDataEncoder.encode(name)
        try bluetooth.gap.setScanResponse(scanResponse)

        // start advertisement - connectable, so a central can connect and write
        // the control characteristics (the default parameters advertise as
        // BLE_GAP_CONN_MODE_NON, which never accepts connections)
        let advertisingParameters = ble_gap_adv_params(
            conn_mode: UInt8(BLE_GAP_CONN_MODE_UND),
            disc_mode: UInt8(BLE_GAP_DISC_MODE_GEN),
            itvl_min: 0,
            itvl_max: 0,
            channel_map: 0,
            filter_policy: 0,
            high_duty_cycle: 0
        )
        try bluetooth.gap.startAdvertising(parameters: advertisingParameters)
        print("Advertisement name: \(name)")
    } catch {
        print("Bluetooth error \(error.rawValue)")
    }

    while true {
        // Expires a stale pairing window (docs/ble-provisioning.md §7) --
        // cheap (a timer comparison), fine to call every loop tick rather
        // than throttling it separately.
        pairingTick()
        pairingAlternateTick()

        // ets_delay_us is a busy-wait (it spins on a cycle counter, never
        // yielding to the scheduler) -- using it to pace this loop meant the
        // main task was effectively always "ready" and never blocked, which
        // starves the IDLE task of CPU time on this single-core chip whenever
        // nothing preempts main. vTaskDelay actually blocks/yields, letting
        // IDLE (and everything else) run. 1 tick == 10ms here
        // (CONFIG_FREERTOS_HZ=100) -- still effectively instant for a
        // human-facing BLE property poll.
        vTaskDelay(1)
    }

}
