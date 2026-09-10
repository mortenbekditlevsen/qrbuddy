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

@_cdecl("app_main")
func app_main() {
    print("Hello from Swift on ESP32-C6!")
    initialize()

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

    // Seed from current storage so we don't report a spurious change on boot.
    var lastSeenValues: [[UInt8]] = (0..<5).map { readPropertyValue(index: $0) }

    while true {
        for index in 0..<5 {
            let current = readPropertyValue(index: index)
            if current != lastSeenValues[index] {
                if index == 0 {
                    // Property 6E400011 is the UTF-8 URL to encode.
                    let url = String(decoding: current, as: UTF8.self)
                    guard !url.isEmpty else { continue }
                    print("Property 0 changed, showing QR for: \(url)")
                    url.withCString { show_qr($0) }
                } else {
                    print("Property \(index) changed to \(current)")
                }
                if index == 2 {
                    // switch current[0] {
                    //     case 0:
                    //       state = .stopped
                    //     case 1:
                    //       state = .singleStep
                    //       updatePropertyValue(index: 2, value: [0, 0, 0, 0])

                    //       case 2:
                    //       state = .homing

                    //       case 3:
                    //       state = .cycling

                    //     default:
                    //       ()

                    // }
                    //                    led.setLed(value: current[0] == 0)
                }

                lastSeenValues[index] = current
            }
        }

        ets_delay_us(500)
    }

}
