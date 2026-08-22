//===----------------------------------------------------------------------===//
// NimBLEUUID.swift
//===----------------------------------------------------------------------===//

/// Builds a persistent `ble_uuid_t*` from our local 128-bit `UUID`, reversing byte order
/// from the UUID's string/RFC-4122 order into the little-endian order NimBLE's
/// `BLE_UUID128_INIT` expects (128-bit UUIDs go least-significant-byte first over the air).
///
/// The returned storage is heap-allocated once and never freed — `ble_gatt_svc_def` /
/// `ble_gatt_chr_def` keep a raw pointer to it for as long as the service is registered,
/// which for firmware is the lifetime of the process.
func makeNimBLEUUID(_ uuid: UUID) -> UnsafeMutablePointer<ble_uuid_t> {
    let storage = UnsafeMutablePointer<ble_uuid128_t>.allocate(capacity: 1)
    storage.pointee.u.type = UInt8(BLE_UUID_TYPE_128)

    let stringOrderBytes = uuid.bytes   // 16-tuple, big-endian / string order
    withUnsafeBytes(of: stringOrderBytes) { be in
        withUnsafeMutableBytes(of: &storage.pointee.value) { le in
            for i in 0..<16 {
                le[i] = be[15 - i]
            }
        }
    }

    // ble_uuid_t is the first field of ble_uuid128_t, so this reinterpretation
    // is exactly what BLE_UUID128_DECLARE does in C.
    return UnsafeMutableRawPointer(storage).assumingMemoryBound(to: ble_uuid_t.self)
}

/// Convenience for building directly from a UUID string, matching how iBeacon.swift
/// already constructs UUIDs elsewhere in this project.
func makeNimBLEUUID(_ uuidString: String) -> UnsafeMutablePointer<ble_uuid_t> {
    guard let uuid = UUID(uuidString: uuidString) else {
        fatalError("Invalid UUID string: \(uuidString)")
    }
    return makeNimBLEUUID(uuid)
}