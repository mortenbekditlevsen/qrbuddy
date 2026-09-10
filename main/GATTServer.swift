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

// MARK: - Service / Characteristic UUIDs

private let controlServiceUUIDString = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"

private let propertyUUIDStrings: [String] = [
    "6E400011-B5A3-F393-E0A9-E50E24DCCA9E",
    "6E400012-B5A3-F393-E0A9-E50E24DCCA9E",
    "6E400013-B5A3-F393-E0A9-E50E24DCCA9E",
    "6E400014-B5A3-F393-E0A9-E50E24DCCA9E",
    "6E400015-B5A3-F393-E0A9-E50E24DCCA9E",
]

private let propertyCount = propertyUUIDStrings.count

/// Maximum stored length of each property's value, in bytes.
/// Property 0 (`6E400011`) is a UTF-8 text buffer of up to 256 bytes; the
/// others are fixed 4-byte values.
private let propertyMaxLength: [Int] = [256, 4, 4, 4, 4]

/// Whether a property's payload is treated as UTF-8 text (validated on write,
/// readable as a `String`) rather than a fixed 4-byte value.
private func isTextProperty(_ index: Int) -> Bool { index == 0 }

// MARK: - Persistent State

/// Current value of each property. Only ever touched from Swift (never aliased
/// by a raw pointer handed to C), so a plain array is safe here. Text properties
/// start empty; fixed properties start as 4 zero bytes.
private var propertyStorage: [[UInt8]] = (0 ..< propertyCount).map { index in
    isTextProperty(index) ? [] : [0, 0, 0, 0]
}

/// Attribute handles NimBLE assigns to each characteristic's value at registration time.
/// Allocated as raw storage (not a Swift Array) because `ble_gatt_chr_def.val_handle`
/// keeps a pointer into this for as long as the service is registered — a Swift Array's
/// backing storage isn't guaranteed to stay at a fixed address the way this is.
private let propertyHandles = UnsafeMutablePointer<UInt16>.allocate(capacity: propertyCount)

// MARK: - Synchronization

/// `propertyStorage` is touched from two tasks: NimBLE's host task (via
/// `property_access_cb`, on every BLE read/write) and whichever task calls
/// `updatePropertyValue` (here, app_main's loop). This brackets access with a
/// scheduler suspend/resume — coarse, but the critical section is a 4-byte
/// copy, so the window is negligible. `vTaskSuspendAll`/`xTaskResumeAll` are
/// real functions (unlike the `xSemaphore*` family, which are macros and
/// can't be bridged without a small C shim).
@inline(__always)
private func withPropertyLock<R>(_ body: () -> R) -> R {
    vTaskSuspendAll()
    defer { xTaskResumeAll() }
    return body()
}

// MARK: - Access Callback

/// Shared access callback for all 5 property characteristics. NimBLE passes back
/// whichever `arg` pointer was registered for the characteristic being accessed,
/// which is how we recover which of the 5 properties this call is for.
@_cdecl("property_access_cb")
func property_access_cb(
    connHandle: UInt16,
    attrHandle: UInt16,
    ctxt: UnsafeMutablePointer<ble_gatt_access_ctxt>?,
    arg: UnsafeMutableRawPointer?
) -> Int32 {
    guard let ctxt, let arg else { return 1 }
    let index = arg.load(as: Int.self)
    guard index >= 0, index < propertyCount else { return 1 }

    switch ctxt.pointee.op {
    case UInt8(BLE_GATT_ACCESS_OP_READ_CHR):
        let value = withPropertyLock { propertyStorage[index] }
        let result = value.withUnsafeBytes { buf in
            r_os_mbuf_append(ctxt.pointee.om, buf.baseAddress, UInt16(buf.count))
        }
        return result == 0 ? 0 : Int32(BLE_ATT_ERR_INSUFFICIENT_RES)

    case UInt8(BLE_GATT_ACCESS_OP_WRITE_CHR):
        // Flatten the incoming mbuf into a buffer sized to this property's max.
        // ble_hs_mbuf_to_flat fails (BLE_HS_EMSGSIZE) if the write is larger,
        // which is how the 256-byte / 4-byte caps are enforced.
        var buffer = [UInt8](repeating: 0, count: propertyMaxLength[index])
        var writtenLen: UInt16 = 0
        let result = buffer.withUnsafeMutableBytes { buf in
            ble_hs_mbuf_to_flat(ctxt.pointee.om, buf.baseAddress, UInt16(buf.count), &writtenLen)
        }
        guard result == 0 else { return Int32(BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN) }

        let value = Array(buffer[..<Int(writtenLen)])
        if isTextProperty(index) {
            // Reject payloads that aren't well-formed UTF-8.
            guard String(validating: value, as: UTF8.self) != nil else {
                return Int32(BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN)
            }
        } else {
            guard writtenLen == 4 else { return Int32(BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN) }
        }
        withPropertyLock { propertyStorage[index] = value }
        return 0

    default:
        return 1
    }
}

// MARK: - Registration

/// Builds and registers the control service with NimBLE's GATT server.
/// Call this after `NimBLE()` init and before `bluetooth.gap.startAdvertising()`.
func setupGATTServer() throws(NimBLEError) {
    // `arg` pointers handed to NimBLE — allocated once, read-only after this point,
    // so a local allocation is fine (the underlying heap memory outlives this scope).
    let argStorage = UnsafeMutablePointer<Int>.allocate(capacity: propertyCount)

    let characteristics = UnsafeMutablePointer<ble_gatt_chr_def>.allocate(capacity: propertyCount + 1)

    for i in 0 ..< propertyCount {
        argStorage[i] = i
        characteristics[i] = ble_gatt_chr_def(
            uuid: makeNimBLEUUID(propertyUUIDStrings[i]),
            access_cb: property_access_cb,
            arg: UnsafeMutableRawPointer(argStorage + i),
            descriptors: nil,
            flags: ble_gatt_chr_flags(BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_NOTIFY),
            min_key_size: 0,
            val_handle: propertyHandles + i,
            cpfd: nil
        )
    }
    characteristics[propertyCount] = ble_gatt_chr_def()   // zeroed sentinel (uuid == nil)

    let services = UnsafeMutablePointer<ble_gatt_svc_def>.allocate(capacity: 2)
    services[0] = ble_gatt_svc_def(
        type: UInt8(BLE_GATT_SVC_TYPE_PRIMARY),
        uuid: makeNimBLEUUID(controlServiceUUIDString),
        includes: nil,
        characteristics: characteristics
    )
    services[1] = ble_gatt_svc_def()   // zeroed sentinel (type == 0)

    try ble_gatts_count_cfg(services).throwsError()
    try ble_gatts_add_svcs(services).throwsError()
    try ble_gatts_start().throwsError()
}

// MARK: - Firmware-side reads

/// Call from firmware logic to read the current value of a property —
/// e.g. after a central has written to it over BLE.
func readPropertyValue(index: Int) -> [UInt8] {
    precondition(index >= 0 && index < propertyCount)
    return withPropertyLock { propertyStorage[index] }
}

/// Read a text property's current value as a `String`. The stored bytes are
/// always valid UTF-8 (enforced on every write), so decoding can't fail.
func readPropertyString(index: Int) -> String {
    precondition(isTextProperty(index), "Property \(index) is not a text property")
    return String(decoding: readPropertyValue(index: index), as: UTF8.self)
}

// MARK: - Firmware-side updates

/// Call from firmware logic (not from a BLE write) to change a property's value
/// and notify any subscribed centrals.
func updatePropertyValue(index: Int, value: [UInt8]) {
    precondition(index >= 0 && index < propertyCount)
    precondition(value.count <= propertyMaxLength[index],
                 "Property \(index) holds at most \(propertyMaxLength[index]) bytes")
    precondition(isTextProperty(index) || value.count == 4,
                 "Fixed properties are exactly 4 bytes")
    withPropertyLock { propertyStorage[index] = value }
    ble_gatts_chr_updated(propertyHandles[index])
}

/// Set a text property from a `String` and notify subscribed centrals.
func updatePropertyString(index: Int, value: String) {
    precondition(isTextProperty(index), "Property \(index) is not a text property")
    updatePropertyValue(index: index, value: Array(value.utf8))
}