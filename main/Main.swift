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

enum MotorState {
    case stopped
    case homing
    case cycling
    case singleStep
}

@_cdecl("app_main")
func app_main() {
    print("Hello from Swift on ESP32-C6!")

    var ledValue: Bool = false
    let blinkDelayMs: UInt32 = 50
    let enable = Led(gpioPin: 2)
    let direction = Led(gpioPin: 0)
    let step = Led(gpioPin: 1)
    let led = Led(gpioPin: 15)

    let hall = Button(gpioPin: 21)


    enable.setLed(value: false)
    direction.setLed(value: true)
    step.setLed(value: true)

    var cycles: Double = 0
    let fullCycle: Double = 400
    let digits: Double = 11
    let stepsPerDigit = fullCycle / digits
    let kStepDelay: UInt32 = 1_000_000
    let kZeroFoundDelay: UInt32 = 2_000_000
    var kMotorDriveDelay: UInt32 = 2_000 // 1_500

    var state: MotorState = .stopped

    let digitPositions = (0 ... 10).map { Double($0) * stepsPerDigit}
    
    let sequence = [3, 1, 4, 1, 5, 9, 10]
    var nextTargetIndex = 0


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
        var delay: UInt32 = kMotorDriveDelay
        let hallTrigger = hall.trigger()

        if hallTrigger {
            if state == .homing {
                state = .cycling
            } else if state == .cycling {
                state = .homing
            }

            if state != .homing {
                delay = kZeroFoundDelay
                cycles = 0
                nextTargetIndex = 0
                led.setLed(value: true)
                
            } else {
                delay = kStepDelay
            }
        }

        switch state {
            case .stopped:
                led.setLed(value: false)
            case .homing:
                stepOnce()
                cycles += 1
                led.setLed(value: true)
                if fmod(cycles, stepsPerDigit) < 1 {
                    delay = kStepDelay
                }

            case .cycling:
                stepOnce()
                cycles += 1
                led.setLed(value: true)

                let nextTarget = sequence[nextTargetIndex]
                let nextPosition = digitPositions[nextTarget]

                let currentPosition = fmod(cycles, fullCycle)
                let distanceToNext = nextPosition - currentPosition

                if distanceToNext < 1 && distanceToNext >= 0 {
                    delay = kStepDelay
                    led.setLed(value: false)
                    nextTargetIndex += 1
                    if nextTargetIndex >= sequence.count {
                        nextTargetIndex = 0
                    }
                }

                let isDriving = delay <= kMotorDriveDelay
            case .singleStep:
              led.setLed(value: true)

              stepOnce()
              cycles += 1
              led.setLed(value: false)
              enable.setLed(value: false)
              state = .stopped
        }

        for index in 0..<5 {
            let current = readPropertyValue(index: index)
            if current != lastSeenValues[index] {                
                print("Property \(index) changed to \(current)")
                if index == 0 {
                    updatePropertyValue(index: 1, value: current)
                }
                if index == 2 {
                    switch current[0] {
                        case 0: 
                          state = .stopped
                          enable.setLed(value: false)
                        case 1:
                          state = .singleStep
                          updatePropertyValue(index: 2, value: [0, 0, 0, 0])
                          enable.setLed(value: true)

                          case 2:
                          state = .homing
                          enable.setLed(value: true)

                          case 3:
                          state = .cycling
                          enable.setLed(value: true)

                        default:
                          ()

                    }
//                    led.setLed(value: current[0] == 0)
                }
                if index == 3 {
                    let high = current[0]
                    let low = current[1]
                    let speed = UInt32(high) * 256 + UInt32(low)
                    // for now, cap at min
                    kMotorDriveDelay = max(speed, 500)
                    // 0x0200 - for hurtigt
                    // 0x0300 (768) - hurtigst
                    // 0x0400 (1024) - hurtigt, flydende
                    // 0x0600 (1536) - med let 'drev' (skramlende motor)
                }
                lastSeenValues[index] = current
            }
        }


        ets_delay_us(delay)
    }


    // while true {
    //     for index in 0..<5 {
    //         let current = readPropertyValue(index: index)
    //         if current != lastSeenValues[index] {
    //             print("Property \(index) changed to \(current)")
    //             lastSeenValues[index] = current
    //         }
    //     }
    //     vTaskDelay(delayMs / (1000 / UInt32(configTICK_RATE_HZ)))
    // }
    
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

    func stepOnce() {
        step.setLed(value: true)
        ets_delay_us(10)
        step.setLed(value: false)
        ets_delay_us(10)
    }

}
