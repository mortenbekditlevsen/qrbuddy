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

// A single read-only characteristic (DEVICE_INFO) returning a small JSON
// object describing this firmware build -- version, wire-protocol version,
// and which CMD opcodes it supports. Unlike everything on CMD, this is
// deliberately plaintext and readable pre-pairing (same as PROV_STATE):
// none of this is sensitive, and a client benefits from being able to
// check compatibility before going through the trouble of pairing at all.

// MARK: - Constants

/// This firmware build's own version -- bump manually on release, same
/// spirit as a package/app version. Distinct from `apiVersion` below:
/// this can change (new effects, new copy, bugfixes) without the wire
/// protocol itself changing at all.
private let firmwareVersion = "1.0.0"

/// The wire protocol's own version (docs/ble-provisioning.md) -- bump this
/// specifically when a change could break an existing client (a
/// wire-format change, not just a new opcode appended). Additive changes
/// (a new opcode, a new SetConfig config_type) don't need a bump; those
/// are exactly what `capabilities` below is for instead.
private let apiVersion = 1

/// Which CMD opcodes (docs/ble-provisioning.md §5b) this build actually
/// implements -- lets a client detect an older device missing a command
/// it wants to use, without needing an apiVersion bump for every
/// additive change. Keep this in sync by hand when adding a new Command
/// case in GATTServer.swift -- Embedded Swift's Command enum has
/// associated values on most cases, so it can't be CaseIterable and this
/// can't be derived automatically.
private let capabilities = ["ShowQR", "Idle", "DemoEffects", "SetConfig", "GetConfig"]

/// Built once (these never change at runtime) rather than reconstructed on
/// every read. Hand-built via string interpolation, not a JSON
/// encoder/Codable -- Embedded Swift has no runtime type metadata, so
/// there's no synthesized Codable conformance available (same reason
/// Command is a hand-parsed enum rather than something auto-decoded).
/// Safe to build this way since every value going into it is an
/// internally-controlled constant, never external/untrusted input that
/// would need JSON-escaping.
private let deviceInfoJSON: String = {
    let capabilitiesJSON = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
    return "{\"version\":\"\(firmwareVersion)\",\"apiVersion\":\(apiVersion),\"capabilities\":[\(capabilitiesJSON)]}"
}()

/// UTF-8 bytes of the above, precomputed once for device_info_access_cb()
/// to hand straight to r_os_mbuf_append() -- same shape as the old
/// property_access_cb's read path used ([UInt8].withUnsafeBytes), not
/// String's own withCString (that gives a null-terminated C string
/// pointer, the wrong shape for an mbuf append that wants a length,
/// not a terminator).
private let deviceInfoBytes: [UInt8] = Array(deviceInfoJSON.utf8)

// MARK: - GATT UUID

private let deviceInfoUUIDString = "6E400012-B5A3-F393-E0A9-E50E24DCCA9E"

private var deviceInfoHandle: UInt16 = 0

// MARK: - Access Callback

/// Read-only, plaintext, no session required -- see this file's header
/// comment for why.
@_cdecl("device_info_access_cb")
func device_info_access_cb(
    connHandle: UInt16,
    attrHandle: UInt16,
    ctxt: UnsafeMutablePointer<ble_gatt_access_ctxt>?,
    arg: UnsafeMutableRawPointer?
) -> Int32 {
    guard let ctxt else { return 1 }
    guard ctxt.pointee.op == UInt8(BLE_GATT_ACCESS_OP_READ_CHR) else { return 1 }

    let result = deviceInfoBytes.withUnsafeBytes { buf in
        r_os_mbuf_append(ctxt.pointee.om, buf.baseAddress, UInt16(buf.count))
    }
    return result == 0 ? 0 : Int32(BLE_ATT_ERR_INSUFFICIENT_RES)
}

// MARK: - Registration

/// The DEVICE_INFO characteristic's definition -- spliced into the same
/// control-service characteristics array as CMD and the pairing pair, by
/// setupGATTServer() (GATTServer.swift), for the same reason those are:
/// one service, every characteristic, never a second ble_gatts_add_svcs()
/// call reusing the same service UUID.
func deviceInfoCharacteristics() -> [ble_gatt_chr_def] {
    [
        ble_gatt_chr_def(
            uuid: makeNimBLEUUID(deviceInfoUUIDString),
            access_cb: device_info_access_cb,
            arg: nil,
            descriptors: nil,
            flags: ble_gatt_chr_flags(BLE_GATT_CHR_F_READ),
            min_key_size: 0,
            val_handle: &deviceInfoHandle,
            cpfd: nil
        )
    ]
}
