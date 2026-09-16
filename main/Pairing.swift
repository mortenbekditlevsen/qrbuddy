//===----------------------------------------------------------------------===//
//
// App-level BLE provisioning: see docs/ble-provisioning.md for the full
// design (wire format, KDF construction, threat model). This file owns the
// GATT side (two characteristics: PROV_STATE, PROV_HANDSHAKE) and the
// per-connection handshake state machine; components/pairing/pairing.h
// (via pairing_*() C calls) owns NVS-backed trust storage, the pairing
// window/POP, and every mbedtls call -- this file never touches mbedtls or
// NVS directly, same split as GATTServer.swift/particle.h.
//
//===----------------------------------------------------------------------===//

// MARK: - GATT UUIDs

private let provisioningStateUUIDString = "6E400020-B5A3-F393-E0A9-E50E24DCCA9E"
private let provisioningHandshakeUUIDString = "6E400021-B5A3-F393-E0A9-E50E24DCCA9E"

private var provStateHandle: UInt16 = 0
private var provHandshakeHandle: UInt16 = 0

/// PROV_STATE's single byte: 0 = unpaired/awaiting pairing, 1 = paired
/// (idle), 2 = pairing window open. Kept in sync with pairing_*() calls by
/// updateProvState() below, called any time one of those could have
/// changed which state this is.
private var provState: UInt8 = 0

private func updateProvState() {
    let new: UInt8 = pairing_has_trust() ? 1 : (pairing_window_is_open() ? 2 : 0)
    guard new != provState else { return }
    provState = new
    if provStateHandle != 0 {
        ble_gatts_chr_updated(provStateHandle)
    }
}

// MARK: - Handshake wire format (docs/ble-provisioning.md §5)

private enum HandshakeOpcode: UInt8 {
    case clientHello = 0x01
    case deviceHello = 0x02
    case clientConfirm = 0x03
    case pairingComplete = 0x04
    case resumeHello = 0x05
    case resumeDeviceHello = 0x06
    case resumeClientConfirm = 0x07
    case resumeComplete = 0x08
    case nack = 0x7F
}

private enum NackReason: UInt8 {
    case notPaired = 1
    case badConfirm = 2
    case windowClosed = 3
    case rateLimited = 4
}

// Fixed HKDF/HMAC context strings -- must match the client exactly (see
// docs/ble-provisioning.md §6).
private let infoPair = Array("qrbuddy-pair-v1".utf8)
private let infoResume = Array("qrbuddy-resume-v1".utf8)
private let infoLTK = Array("qrbuddy-ltk-v1".utf8)
private let confirmInfoDevice = Array("qrbuddy-confirm-device-v1".utf8)
private let confirmInfoClient = Array("qrbuddy-confirm-client-v1".utf8)

// MARK: - Per-connection session state

/// At most CONFIG_BT_NIMBLE_MAX_CONNECTIONS (3) connections exist at once;
/// a little headroom in case a slot isn't reclaimed by the time a new
/// connection needs one.
private let maxPairingSessions = 4

private struct PairingSession {
    var connHandle: UInt16 = 0xFFFF   // 0xFFFF == unused slot
    var established = false
    var sessionKey = [UInt8](repeating: 0, count: Int(PAIRING_SECRET_LEN))
    var pendingClientID = [UInt8](repeating: 0, count: Int(PAIRING_CLIENT_ID_LEN))
    var hasPending = false            // a DeviceHello/ResumeDeviceHello went out, awaiting confirm
    var txCounter: UInt32 = 0
}

private var sessions = [PairingSession](repeating: PairingSession(), count: maxPairingSessions)

private func sessionIndex(for connHandle: UInt16) -> Int? {
    sessions.firstIndex { $0.connHandle == connHandle }
}

private func sessionSlot(for connHandle: UInt16) -> Int {
    if let i = sessionIndex(for: connHandle) { return i }
    if let free = sessions.firstIndex(where: { $0.connHandle == 0xFFFF }) {
        sessions[free] = PairingSession()
        sessions[free].connHandle = connHandle
        return free
    }
    // No free slot (shouldn't happen given maxPairingSessions > max BLE
    // connections) -- reclaim the first slot rather than crash.
    sessions[0] = PairingSession()
    sessions[0].connHandle = connHandle
    return 0
}

/// The established session key for `connHandle`, for GATTServer.swift's
/// property read/write handlers to encrypt/decrypt against. `nil` means
/// "no established session" -- callers must treat that as "drop this
/// traffic", never fall back to plaintext.
func pairingSessionKey(forConnHandle connHandle: UInt16) -> [UInt8]? {
    guard let i = sessionIndex(for: connHandle), sessions[i].established else { return nil }
    return sessions[i].sessionKey
}

/// The next never-repeated per-connection, device->app counter, for the
/// AES-GCM nonce on an outgoing (encrypted read) message. Must never be
/// reused within a connection's lifetime -- see docs/ble-provisioning.md §6.
func pairingNextTxCounter(forConnHandle connHandle: UInt16) -> UInt32? {
    guard let i = sessionIndex(for: connHandle), sessions[i].established else { return nil }
    let c = sessions[i].txCounter
    sessions[i].txCounter += 1
    return c
}

/// Called from NimBLE.swift's GAP callback on BLE_GAP_EVENT_DISCONNECT --
/// a session (established or mid-handshake) is only ever meaningful for the
/// connection it was negotiated on.
func pairingSessionOnDisconnect(connHandle: UInt16) {
    if let i = sessionIndex(for: connHandle) {
        sessions[i] = PairingSession()
    }
}

// MARK: - Nonce construction (docs/ble-provisioning.md §6)

/// direction(1) + counter, little-endian (4) + zero-pad(7). The direction
/// byte keeps app->device and device->app messages from ever sharing a
/// nonce even if their counters happened to collide.
private func makeNonce(direction: UInt8, counter: UInt32) -> [UInt8] {
    var nonce = [UInt8](repeating: 0, count: Int(PAIRING_NONCE_LEN))
    nonce[0] = direction
    nonce[1] = UInt8(counter & 0xFF)
    nonce[2] = UInt8((counter >> 8) & 0xFF)
    nonce[3] = UInt8((counter >> 16) & 0xFF)
    nonce[4] = UInt8((counter >> 24) & 0xFF)
    return nonce
}

// MARK: - Crypto call wrappers (thin -- just adapt Swift Arrays to the
// fixed-size C buffers pairing.h expects)

private func x25519Keypair() -> (priv: [UInt8], pub: [UInt8]) {
    var priv = [UInt8](repeating: 0, count: Int(PAIRING_PRIVKEY_LEN))
    var pub = [UInt8](repeating: 0, count: Int(PAIRING_PUBKEY_LEN))
    priv.withUnsafeMutableBytes { p in
        pub.withUnsafeMutableBytes { q in
            pairing_x25519_keypair(p.baseAddress, q.baseAddress)
        }
    }
    return (priv, pub)
}

private func x25519Shared(priv: [UInt8], peerPub: [UInt8]) -> [UInt8] {
    var shared = [UInt8](repeating: 0, count: Int(PAIRING_SECRET_LEN))
    priv.withUnsafeBytes { p in
        peerPub.withUnsafeBytes { q in
            shared.withUnsafeMutableBytes { s in
                pairing_x25519_shared(p.baseAddress, q.baseAddress, s.baseAddress)
            }
        }
    }
    return shared
}

private func hkdfSHA256(ikm: [UInt8], salt: [UInt8], info: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: Int(PAIRING_SECRET_LEN))
    ikm.withUnsafeBytes { i in
        salt.withUnsafeBytes { s in
            info.withUnsafeBytes { n in
                out.withUnsafeMutableBytes { o in
                    pairing_hkdf_sha256(i.baseAddress, i.count, s.baseAddress, s.count, n.baseAddress, n.count, o.baseAddress)
                }
            }
        }
    }
    return out
}

private func hmacSHA256Tag(key: [UInt8], info: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: Int(PAIRING_TAG_LEN))
    key.withUnsafeBytes { k in
        info.withUnsafeBytes { n in
            out.withUnsafeMutableBytes { o in
                pairing_hmac_sha256(k.baseAddress, n.baseAddress, n.count, o.baseAddress, o.count)
            }
        }
    }
    return out
}

/// AES-256-GCM encrypt, wire-framed as counter(4, LE) || ciphertext || tag
/// -- see docs/ble-provisioning.md §6. Used by GATTServer.swift's property
/// read handler.
func pairingEncryptForWire(connHandle: UInt16, plaintext: [UInt8]) -> [UInt8]? {
    guard let key = pairingSessionKey(forConnHandle: connHandle),
          let counter = pairingNextTxCounter(forConnHandle: connHandle) else { return nil }
    let nonce = makeNonce(direction: 0x01, counter: counter)   // device -> app

    var ciphertext = [UInt8](repeating: 0, count: plaintext.count)
    var tag = [UInt8](repeating: 0, count: Int(PAIRING_TAG_LEN))
    key.withUnsafeBytes { k in
        nonce.withUnsafeBytes { n in
            plaintext.withUnsafeBytes { p in
                ciphertext.withUnsafeMutableBytes { c in
                    tag.withUnsafeMutableBytes { t in
                        pairing_aes_gcm_encrypt(k.baseAddress, n.baseAddress, p.baseAddress, p.count, c.baseAddress, t.baseAddress)
                    }
                }
            }
        }
    }

    var wire = [UInt8](repeating: 0, count: 4)
    wire[0] = UInt8(counter & 0xFF)
    wire[1] = UInt8((counter >> 8) & 0xFF)
    wire[2] = UInt8((counter >> 16) & 0xFF)
    wire[3] = UInt8((counter >> 24) & 0xFF)
    wire.append(contentsOf: ciphertext)
    wire.append(contentsOf: tag)
    return wire
}

/// Inverse of pairingEncryptForWire, for an incoming (app->device) write.
/// Returns nil on any failure (no session, malformed frame, bad tag) --
/// callers must drop the write, never fall back to trusting raw bytes.
func pairingDecryptFromWire(connHandle: UInt16, wire: [UInt8]) -> [UInt8]? {
    guard let key = pairingSessionKey(forConnHandle: connHandle) else { return nil }
    guard wire.count >= 4 + Int(PAIRING_TAG_LEN) else { return nil }

    let counter = UInt32(wire[0]) | (UInt32(wire[1]) << 8) | (UInt32(wire[2]) << 16) | (UInt32(wire[3]) << 24)
    let nonce = makeNonce(direction: 0x00, counter: counter)   // app -> device

    let cipherLen = wire.count - 4 - Int(PAIRING_TAG_LEN)
    let ciphertext = Array(wire[4 ..< 4 + cipherLen])
    let tag = Array(wire[(4 + cipherLen)...])

    var plaintext = [UInt8](repeating: 0, count: cipherLen)
    var ok = false
    key.withUnsafeBytes { k in
        nonce.withUnsafeBytes { n in
            ciphertext.withUnsafeBytes { c in
                tag.withUnsafeBytes { t in
                    plaintext.withUnsafeMutableBytes { p in
                        ok = pairing_aes_gcm_decrypt(k.baseAddress, n.baseAddress, c.baseAddress, cipherLen, t.baseAddress, p.baseAddress)
                    }
                }
            }
        }
    }
    return ok ? plaintext : nil
}

// MARK: - Sending a handshake response

/// Notifies `bytes` to exactly this connection on PROV_HANDSHAKE, via a
/// fresh mbuf -- not ble_gatts_chr_updated(), which would notify *every*
/// subscriber with a shared "last value" instead of a per-connection
/// response. Silently drops the response if the mbuf allocation fails
/// (this is a handshake nicety, not something worth a hard failure over --
/// the client will just see the write time out and can retry).
private func sendHandshakeResponse(connHandle: UInt16, opcode: HandshakeOpcode, payload: [UInt8]) {
    var bytes = [opcode.rawValue]
    bytes.append(contentsOf: payload)
    bytes.withUnsafeBytes { buf in
        guard let om = ble_hs_mbuf_from_flat(buf.baseAddress, UInt16(buf.count)) else { return }
        ble_gatts_notify_custom(connHandle, provHandshakeHandle, om)
    }
}

private func sendNack(connHandle: UInt16, reason: NackReason) {
    sendHandshakeResponse(connHandle: connHandle, opcode: .nack, payload: [reason.rawValue])
}

// MARK: - Handshake processing

private func handleClientHello(connHandle: UInt16, payload: [UInt8]) {
    guard payload.count == Int(PAIRING_CLIENT_ID_LEN) + Int(PAIRING_PUBKEY_LEN) else { return }
    guard pairing_window_is_open() else { sendNack(connHandle: connHandle, reason: .windowClosed); return }

    var popBytes = [UInt8](repeating: 0, count: Int(PAIRING_POP_LEN))
    let gotPop = popBytes.withUnsafeMutableBytes { pairing_window_pop_bytes($0.baseAddress) }
    guard gotPop else { sendNack(connHandle: connHandle, reason: .windowClosed); return }

    let clientID = Array(payload[0 ..< Int(PAIRING_CLIENT_ID_LEN)])
    let clientPub = Array(payload[Int(PAIRING_CLIENT_ID_LEN)...])

    let (devPriv, devPub) = x25519Keypair()
    let z = x25519Shared(priv: devPriv, peerPub: clientPub)
    let sessionKey = hkdfSHA256(ikm: z, salt: popBytes, info: infoPair)
    let confirmTagDevice = hmacSHA256Tag(key: sessionKey, info: confirmInfoDevice)

    let slot = sessionSlot(for: connHandle)
    sessions[slot].sessionKey = sessionKey
    sessions[slot].pendingClientID = clientID
    sessions[slot].hasPending = true
    sessions[slot].established = false

    sendHandshakeResponse(connHandle: connHandle, opcode: .deviceHello, payload: devPub + confirmTagDevice)
}

private func handleClientConfirm(connHandle: UInt16, payload: [UInt8], isResume: Bool) {
    guard payload.count == Int(PAIRING_TAG_LEN) else { return }
    guard let slot = sessionIndex(for: connHandle), sessions[slot].hasPending else {
        sendNack(connHandle: connHandle, reason: isResume ? .notPaired : .windowClosed)
        return
    }

    let expected = hmacSHA256Tag(key: sessions[slot].sessionKey, info: confirmInfoClient)
    guard expected == payload else {
        if !isResume { _ = pairing_window_note_failure() }
        sendNack(connHandle: connHandle, reason: .badConfirm)
        return
    }

    sessions[slot].hasPending = false
    sessions[slot].established = true
    sessions[slot].txCounter = 0

    if !isResume {
        let ltk = hkdfSHA256(ikm: sessions[slot].sessionKey, salt: [], info: infoLTK)
        sessions[slot].pendingClientID.withUnsafeBytes { idBuf in
            ltk.withUnsafeBytes { ltkBuf in
                pairing_store_trust(idBuf.baseAddress, ltkBuf.baseAddress)
            }
        }
        pairing_close_window()
        updateProvState()
        show_particles()   // done showing the pairing QR -- back to the normal idle effect
        sendHandshakeResponse(connHandle: connHandle, opcode: .pairingComplete, payload: [])
    } else {
        sendHandshakeResponse(connHandle: connHandle, opcode: .resumeComplete, payload: [])
    }
}

private func handleResumeHello(connHandle: UInt16, payload: [UInt8]) {
    guard payload.count == Int(PAIRING_CLIENT_ID_LEN) + Int(PAIRING_PUBKEY_LEN) else { return }

    var storedID = [UInt8](repeating: 0, count: Int(PAIRING_CLIENT_ID_LEN))
    var storedLTK = [UInt8](repeating: 0, count: Int(PAIRING_SECRET_LEN))
    let haveTrust = storedID.withUnsafeMutableBytes { idBuf in
        storedLTK.withUnsafeMutableBytes { ltkBuf in
            pairing_load_trust(idBuf.baseAddress, ltkBuf.baseAddress)
        }
    }

    let clientID = Array(payload[0 ..< Int(PAIRING_CLIENT_ID_LEN)])
    let clientPub = Array(payload[Int(PAIRING_CLIENT_ID_LEN)...])
    guard haveTrust, storedID == clientID else {
        // This is exactly the shape of a stale client auto-reconnecting
        // after a re-pair reset: it still thinks it's paired and tries to
        // Resume, but the trust it's resuming against is gone (or belongs
        // to a different client). Advertising doesn't come back up while
        // any connection is open (see NimBLE.swift), so if we just left
        // this one sitting here, it would permanently block a legitimate
        // new client from ever connecting to go through the real pairing
        // flow. Kick it after the Nack so the slot frees up.
        sendNack(connHandle: connHandle, reason: .notPaired)
        terminateConnection(connHandle)
        return
    }

    let (devPriv, devPub) = x25519Keypair()
    let z = x25519Shared(priv: devPriv, peerPub: clientPub)
    let sessionKey = hkdfSHA256(ikm: z, salt: storedLTK, info: infoResume)
    let confirmTagDevice = hmacSHA256Tag(key: sessionKey, info: confirmInfoDevice)

    let slot = sessionSlot(for: connHandle)
    sessions[slot].sessionKey = sessionKey
    sessions[slot].pendingClientID = clientID
    sessions[slot].hasPending = true
    sessions[slot].established = false

    sendHandshakeResponse(connHandle: connHandle, opcode: .resumeDeviceHello, payload: devPub + confirmTagDevice)
}

/// Dispatches one PROV_HANDSHAKE write. `bytes[0]` is the opcode (see
/// docs/ble-provisioning.md §5); the rest is that opcode's payload.
private func handleHandshakeWrite(connHandle: UInt16, bytes: [UInt8]) {
    guard !bytes.isEmpty, let opcode = HandshakeOpcode(rawValue: bytes[0]) else { return }
    let payload = Array(bytes[1...])

    switch opcode {
    case .clientHello:
        handleClientHello(connHandle: connHandle, payload: payload)
    case .clientConfirm:
        handleClientConfirm(connHandle: connHandle, payload: payload, isResume: false)
    case .resumeHello:
        handleResumeHello(connHandle: connHandle, payload: payload)
    case .resumeClientConfirm:
        handleClientConfirm(connHandle: connHandle, payload: payload, isResume: true)
    // Everything else here is a device -> app opcode; the app should never send it to us.
    case .deviceHello, .pairingComplete, .resumeDeviceHello, .resumeComplete, .nack:
        break
    }
}

// MARK: - GATT access callbacks

@_cdecl("prov_state_access_cb")
func prov_state_access_cb(
    connHandle: UInt16,
    attrHandle: UInt16,
    ctxt: UnsafeMutablePointer<ble_gatt_access_ctxt>?,
    arg: UnsafeMutableRawPointer?
) -> Int32 {
    guard let ctxt else { return 1 }
    guard ctxt.pointee.op == UInt8(BLE_GATT_ACCESS_OP_READ_CHR) else { return 1 }
    let result = withUnsafeBytes(of: provState) { buf in
        r_os_mbuf_append(ctxt.pointee.om, buf.baseAddress, UInt16(buf.count))
    }
    return result == 0 ? 0 : Int32(BLE_ATT_ERR_INSUFFICIENT_RES)
}

@_cdecl("prov_handshake_access_cb")
func prov_handshake_access_cb(
    connHandle: UInt16,
    attrHandle: UInt16,
    ctxt: UnsafeMutablePointer<ble_gatt_access_ctxt>?,
    arg: UnsafeMutableRawPointer?
) -> Int32 {
    guard let ctxt else { return 1 }
    guard ctxt.pointee.op == UInt8(BLE_GATT_ACCESS_OP_WRITE_CHR) else { return 0 }

    var buffer = [UInt8](repeating: 0, count: 64)
    var writtenLen: UInt16 = 0
    let result = buffer.withUnsafeMutableBytes { buf in
        ble_hs_mbuf_to_flat(ctxt.pointee.om, buf.baseAddress, UInt16(buf.count), &writtenLen)
    }
    guard result == 0 else { return Int32(BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN) }

    handleHandshakeWrite(connHandle: connHandle, bytes: Array(buffer[..<Int(writtenLen)]))
    return 0
}

// MARK: - Registration

/// The provisioning characteristics' definitions -- PROV_STATE and
/// PROV_HANDSHAKE. Returned (not registered directly) so GATTServer.swift's
/// setupGATTServer() can splice them into the *same* control-service
/// characteristics array as CMD: NimBLE doesn't deduplicate service
/// registrations by UUID, so two separate ble_gatts_add_svcs() calls both
/// using controlServiceUUIDString would create two distinct services that
/// happen to share a UUID (and most client code, doing
/// `services.first(where: { $0.uuid == controlServiceUUID })`, would only
/// ever see whichever one was registered first -- this is exactly what
/// used to happen here, and why a client that discovered `CMD` never saw
/// PROV_STATE/PROV_HANDSHAKE). One service, three characteristics.
func pairingCharacteristics() -> [ble_gatt_chr_def] {
    [
        ble_gatt_chr_def(
            uuid: makeNimBLEUUID(provisioningStateUUIDString),
            access_cb: prov_state_access_cb,
            arg: nil,
            descriptors: nil,
            flags: ble_gatt_chr_flags(BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY),
            min_key_size: 0,
            val_handle: &provStateHandle,
            cpfd: nil
        ),
        ble_gatt_chr_def(
            uuid: makeNimBLEUUID(provisioningHandshakeUUIDString),
            access_cb: prov_handshake_access_cb,
            arg: nil,
            descriptors: nil,
            flags: ble_gatt_chr_flags(BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_NOTIFY),
            min_key_size: 0,
            val_handle: &provHandshakeHandle,
            cpfd: nil
        ),
    ]
}

// MARK: - Boot / lifecycle entry points (called from Main.swift)

/// Call once at boot, after registerPairingService()/ble_gatts_start(). If
/// no trust is stored (factory-fresh, or right after a re-pair reset),
/// opens a pairing window immediately and returns the POP for display
/// (QR + text fallback). Returns nil if a trusted client is already
/// stored -- nothing to show, normal idle behavior applies.
func pairingStartupCheck() -> String? {
    if pairing_has_trust() {
        updateProvState()
        return nil
    }
    var pop = [CChar](repeating: 0, count: Int(PAIRING_POP_LEN) + 1)
    pop.withUnsafeMutableBufferPointer { pairing_open_window($0.baseAddress) }
    updateProvState()
    return String(cString: pop)
}

/// The firmware side of "re-pair" (docs/ble-provisioning.md §3c) -- wire
/// this to a button-hold-at-boot check. Clears the stored trust, opens a
/// fresh pairing window, and returns the new POP for display.
func pairingResetAndReopen() -> String {
    pairing_clear_trust()
    var pop = [CChar](repeating: 0, count: Int(PAIRING_POP_LEN) + 1)
    pop.withUnsafeMutableBufferPointer { pairing_open_window($0.baseAddress) }
    updateProvState()
    return String(cString: pop)
}

/// Call periodically (e.g. once a second, alongside other polling in
/// Main.swift's loop) to expire a stale pairing window.
func pairingTick() {
    if pairing_window_tick_expiry() {
        updateProvState()
        // The window can also close by timing out (not just by pairing
        // succeeding) -- without this, the screen would get stuck showing
        // whichever of the QR/helper-text alternation (see Main.swift) was
        // up when the window expired.
        show_particles()
    }
}
