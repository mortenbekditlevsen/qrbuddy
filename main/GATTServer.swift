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

// Command interface: a single opcode+payload characteristic instead of a
// fixed set of property characteristics (the previous design here) --
// extending it later means adding a new opcode, never a new characteristic
// or a client-side re-discovery. See docs/ble-provisioning.md for the wire
// format. All command traffic rides the same authenticated/encrypted
// session as everything else (Pairing.swift's pairingDecryptFromWire) --
// there's deliberately no second, unauthenticated channel here.

// MARK: - Service / Characteristic UUIDs

let controlServiceUUIDString = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
private let commandUUIDString = "6E400011-B5A3-F393-E0A9-E50E24DCCA9E"

private var commandHandle: UInt16 = 0

// MARK: - Wire format (docs/ble-provisioning.md's command opcode table)

/// Append-only: a shipped opcode's meaning never changes or gets reused --
/// deprecate by leaving it unused, not by reassigning the value. Payload
/// shape is per-opcode (whatever's left in the decrypted plaintext after
/// the opcode byte), not a single global layout.
private enum Command {
    case showQR(text: String)
    case idle
    case demoEffects

    static func parse(_ bytes: [UInt8]) -> Command? {
        guard let opcode = bytes.first else { return nil }
        let payload = Array(bytes.dropFirst())
        switch opcode {
        case 0x01:
            guard let text = String(validating: payload, as: UTF8.self), !text.isEmpty else { return nil }
            return .showQR(text: text)
        case 0x02:
            guard payload.isEmpty else { return nil }
            return .idle
        case 0x03:
            guard payload.isEmpty else { return nil }
            return .demoEffects
        default:
            return nil   // unknown opcode -- caller returns an ATT error, no app-level Nack needed
        }
    }
}

private func handle(_ command: Command) {
    switch command {
    case .showQR(let text):
        text.withCString { show_qr($0) }
    case .idle:
        enter_idle()
    case .demoEffects:
        show_particles()
    }
}

// MARK: - Access Callback

/// Write-only (no read, no notify) -- commands are fire-and-forget, per
/// docs/ble-provisioning.md; a malformed/unknown one still gets a normal
/// ATT-level write-response error (standard GATT behavior, not an
/// app-level acknowledgement scheme).
@_cdecl("command_access_cb")
func command_access_cb(
    connHandle: UInt16,
    attrHandle: UInt16,
    ctxt: UnsafeMutablePointer<ble_gatt_access_ctxt>?,
    arg: UnsafeMutableRawPointer?
) -> Int32 {
    guard let ctxt else { return 1 }
    guard ctxt.pointee.op == UInt8(BLE_GATT_ACCESS_OP_WRITE_CHR) else { return 1 }

    // Opcode + a generously-sized payload (the longest today is ShowQR's
    // text) plus the encryption envelope's 20-byte overhead (4-byte counter
    // + 16-byte tag).
    var buffer = [UInt8](repeating: 0, count: 1 + 256 + 20)
    var writtenLen: UInt16 = 0
    let result = buffer.withUnsafeMutableBytes { buf in
        ble_hs_mbuf_to_flat(ctxt.pointee.om, buf.baseAddress, UInt16(buf.count), &writtenLen)
    }
    guard result == 0 else { return Int32(BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN) }

    guard let plaintext = pairingDecryptFromWire(connHandle: connHandle, wire: Array(buffer[..<Int(writtenLen)])) else {
        // No session, malformed envelope, or a bad auth tag -- drop it
        // rather than reporting exactly which check failed.
        return Int32(BLE_ATT_ERR_INSUFFICIENT_AUTHEN)
    }
    guard let command = Command.parse(plaintext) else {
        return Int32(BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN)
    }

    handle(command)
    return 0
}

// MARK: - Registration

/// Builds and registers the control service with NimBLE's GATT server.
/// Call this after `NimBLE()` init and before `bluetooth.gap.startAdvertising()`.
func setupGATTServer() throws(NimBLEError) {
    let characteristics = UnsafeMutablePointer<ble_gatt_chr_def>.allocate(capacity: 2)

    characteristics[0] = ble_gatt_chr_def(
        uuid: makeNimBLEUUID(commandUUIDString),
        access_cb: command_access_cb,
        arg: nil,
        descriptors: nil,
        flags: ble_gatt_chr_flags(BLE_GATT_CHR_F_WRITE),
        min_key_size: 0,
        val_handle: &commandHandle,
        cpfd: nil
    )
    characteristics[1] = ble_gatt_chr_def()   // zeroed sentinel (uuid == nil)

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

    // Provisioning's characteristics (see Pairing.swift) must also be added
    // before ble_gatts_start() -- NimBLE wants every service registered
    // (count_cfg + add_svcs) up front, with start() called exactly once
    // after all of them.
    try registerPairingService()

    try ble_gatts_start().throwsError()
}
