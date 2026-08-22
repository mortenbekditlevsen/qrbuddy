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

    var bluetooth: NimBLE
    do {
        bluetooth = try NimBLE()
    }
    catch {
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
 
        // Estimote iBeacon B9407F30-F5F8-466E-AFF9-25556B57FE6D
        // Major 0x01 Minor 0x01
        guard let uuid = UUID(uuidString: "B9407F30-F5F8-466E-AFF9-25556B57FE6D") else {
            fatalError("Invalid UUID string")
        }
        let beacon = AppleBeacon(uuid: uuid, major: 0x01, minor: 0x01, rssi: -10)
        let flags: GAPFlags = [.lowEnergyGeneralDiscoverableMode, .notSupportedBREDR]
        let advertisement = LowEnergyAdvertisingData(beacon: beacon, flags: flags)
        try bluetooth.gap.setAdvertisement(advertisement)
 
        // set scan response
        let name = GAPShortLocalName(name: "ESP32-C6 " + address.description)
        let scanResponse: LowEnergyAdvertisingData = GAPDataEncoder.encode(name)
        try bluetooth.gap.setScanResponse(scanResponse)
 
        // start advertisement — connectable, so a central can connect and write
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
    }
    catch {
        print("Bluetooth error \(error.rawValue)")
    }
 
    var lastSeenValues: [[UInt8]] = Array(repeating: [0, 0, 0, 0], count: 5)
    let delayMs: UInt32 = 500
 
    while true {
        for index in 0..<5 {
            let current = readPropertyValue(index: index)
            if current != lastSeenValues[index] {
                print("Property \(index) changed to \(current)")
                lastSeenValues[index] = current
            }
        }
        vTaskDelay(delayMs / (1000 / UInt32(configTICK_RATE_HZ)))
    }
    
    // do {
    //     // read address
    //     let address = try bluetooth.hostController.address()
    //     print("Bluetooth address: \(address)")
        
    //     // Estimote iBeacon B9407F30-F5F8-466E-AFF9-25556B57FE6D
    //     // Major 0x01 Minor 0x01
    //     guard let uuid = UUID(uuidString: "B9407F30-F5F8-466E-AFF9-25556B57FE6D") else {
    //         fatalError("Invalid UUID string")
    //     }
    //     let beacon = AppleBeacon(uuid: uuid, major: 0x01, minor: 0x01, rssi: -10)
    //     let flags: GAPFlags = [.lowEnergyGeneralDiscoverableMode, .notSupportedBREDR]
    //     let advertisement = LowEnergyAdvertisingData(beacon: beacon, flags: flags)
    //     try bluetooth.gap.setAdvertisement(advertisement)

    //     // set scan response
    //     let name = GAPShortLocalName(name: "ESP32-C6 " + address.description)
    //     let scanResponse: LowEnergyAdvertisingData = GAPDataEncoder.encode(name)
    //     try bluetooth.gap.setScanResponse(scanResponse)

    //     // start advertisement
    //     try bluetooth.gap.startAdvertising()
    //     print("Advertisement name: \(name)")
    // }
    // catch {
    //     print("Bluetooth error \(error.rawValue)")
    // }

    // let delayMs: UInt32 = 500

    // while true {
    //     vTaskDelay(delayMs / (1000 / UInt32(configTICK_RATE_HZ)))
    // }
}
