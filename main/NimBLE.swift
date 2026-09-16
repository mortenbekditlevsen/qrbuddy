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

struct NimBLE: ~Copyable {

    init() throws(ESPError) {
       try nvs_flash_init().throwsESPError()
       try nimble_port_init().throwsESPError()
       nimble_port_freertos_init(nimble_host_task)
    }
    
    deinit {
        nimble_port_freertos_deinit()
    }

    var gap = GAP()

    var hostController = HostController()
}

@_silgen_name("nvs_flash_init")
internal func nvs_flash_init() -> Int32

@_silgen_name("nimble_port_init")
internal func nimble_port_init() -> Int32

@_silgen_name("nimble_port_run")
internal func nimble_port_run() -> Int32

@_silgen_name("nimble_port_freertos_init")
internal func nimble_port_freertos_init(_ function: (UnsafeMutableRawPointer) -> ())

@_silgen_name("nimble_port_freertos_deinit")
internal func nimble_port_freertos_deinit()

internal func nimble_host_task(_ parameters: UnsafeMutableRawPointer) {
    print("BLE Host Task Started")
    nimble_port_run()
    nimble_port_freertos_deinit()
}

/// NimBLE GAP interface.
public struct GAP: ~Copyable {
    
    private(set) var advertisementData = LowEnergyAdvertisingData()
    
    private(set) var scanResponse = LowEnergyAdvertisingData()
    
    /// Indicates whether an advertisement procedure is currently in progress.
    public var isAdvertising: Bool {
        ble_gap_adv_active() == 1
    }
    
    /// Start advertising
    public func startAdvertising(
        addressType: LowEnergyAddressType = .public,
        address: BluetoothAddress? = nil,
        parameters: ble_gap_adv_params = ble_gap_adv_params(conn_mode: UInt8(BLE_GAP_CONN_MODE_NON), disc_mode: UInt8(BLE_GAP_DISC_MODE_GEN), itvl_min: 0, itvl_max: 0, channel_map: 0, filter_policy: 0, high_duty_cycle: 0)
    ) throws(NimBLEError) {
        // Remember the configuration so `_gap_callback` can bring advertising
        // back up after a disconnect (NimBLE stops advertising on its own the
        // moment a central connects).
        advertisingOwnAddrType = addressType.rawValue
        advertisingParams = parameters
        advertisingConfigured = true
        var address = ble_addr_t(
            type: 0,
            val: (address ?? .zero).bytes
        )
        var parameters = parameters
        try ble_gap_adv_start(addressType.rawValue, &address, BLE_HS_FOREVER, &parameters, _gap_callback, nil).throwsError()
    }
    
    /// Stops the currently-active advertising procedure. 
    public func stopAdvertising() throws(NimBLEError) {
        try ble_gap_adv_stop().throwsError()
    }
    
    /// Configures the data to include in subsequent advertisements.
    public mutating func setAdvertisement(_ data: LowEnergyAdvertisingData) throws(NimBLEError) {
        advertisementData = data
        try advertisementData.withUnsafePointer {
            ble_gap_adv_set_data($0, Int32(data.length))
        }.throwsError()
    }
    
    /// Configures the data to include in subsequent scan responses.
    public mutating func setScanResponse(_ data: LowEnergyAdvertisingData) throws(NimBLEError) {
        scanResponse = data
        try scanResponse.withUnsafePointer {
            ble_gap_adv_rsp_set_data($0, Int32(data.length))
        }.throwsError()
    }
}

// Last advertising configuration, cached by `GAP.startAdvertising` so that the
// GAP event handler can restart advertising after a disconnect. Written from the
// task that starts advertising (once, at startup) and read from the NimBLE host
// task — the write happens-before any connection, so no locking is needed.
internal var advertisingOwnAddrType: UInt8 = UInt8(BLE_OWN_ADDR_PUBLIC)
internal var advertisingParams = ble_gap_adv_params()
internal var advertisingConfigured = false

/// Re-arm undirected connectable advertising with the last-used configuration.
/// Safe to call from inside `_gap_callback` (this is what NimBLE's own
/// peripheral examples do in their disconnect handler).
@discardableResult
internal func restartAdvertising() -> Int32 {
    guard advertisingConfigured, ble_gap_adv_active() == 0 else { return 0 }
    var address = ble_addr_t(type: 0, val: BluetoothAddress.zero.bytes)
    var parameters = advertisingParams
    return ble_gap_adv_start(
        advertisingOwnAddrType, &address, BLE_HS_FOREVER, &parameters, _gap_callback, nil
    )
}

/// Force-closes one connection. NimBLE stops advertising the instant a
/// central connects and this file only resumes it on disconnect (see
/// restartAdvertising() above) -- so only one central can ever be reachable
/// at a time. That means a client that's no longer trusted (e.g. it
/// auto-reconnected and tried to Resume right after a re-pair reset, see
/// Pairing.swift's handleResumeHello) can end up permanently occupying the
/// device's only connection slot, leaving no way for a legitimate new
/// client to ever get in. Terminating that connection triggers
/// BLE_GAP_EVENT_DISCONNECT, which puts advertising back up.
@discardableResult
internal func terminateConnection(_ connHandle: UInt16) -> Int32 {
    ble_gap_terminate(connHandle, UInt8(BLE_ERR_REM_USER_CONN_TERM.rawValue))
}

internal func _gap_callback(event: UnsafeMutablePointer<ble_gap_event>?, context: UnsafeMutableRawPointer?) -> Int32 {
    guard let event else { return 0 }

    switch Int32(event.pointee.type) {
    case BLE_GAP_EVENT_DISCONNECT:
        // Central disconnected — advertising stopped when it connected, so
        // start it again or the device stays unreachable until a power cycle.
        restartAdvertising()
        // Any pairing session (established or mid-handshake) only ever made
        // sense for this specific connection (see Pairing.swift) — drop it
        // rather than let a stale session key linger for a reused conn_handle.
        pairingSessionOnDisconnect(connHandle: event.pointee.disconnect.conn.conn_handle)

    case BLE_GAP_EVENT_ADV_COMPLETE:
        // Advertising ended on its own (shouldn't with BLE_HS_FOREVER, but be safe).
        restartAdvertising()

    case BLE_GAP_EVENT_CONNECT:
        // A failed connection attempt also leaves advertising stopped.
        if event.pointee.connect.status != 0 {
            restartAdvertising()
        }

    default:
        break
    }
    return 0
}

public struct HostController: ~Copyable {
    
    func address(
        type: LowEnergyAddressType = .public
    ) throws(NimBLEError) -> BluetoothAddress {
        var address = BluetoothAddress.zero
        try withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: UInt8.self, capacity: 6) {
                ble_hs_id_copy_addr(type.rawValue, $0, nil)
            }
        }.throwsError()
        return address
    }
}