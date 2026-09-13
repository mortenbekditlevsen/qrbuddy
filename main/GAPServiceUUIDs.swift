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

/// GAP Complete List of 128-bit Service Class UUIDs.
///
/// Put your primary service UUID here so a scanning central (e.g. an iOS app
/// using `CBCentralManager.scanForPeripherals(withServices:)`) can find and
/// filter for this device. UUIDs are encoded little-endian in the AD structure.
public struct GAPCompleteListOf128BitServiceUUIDs: GAPData, Equatable, Hashable {

    public static var dataType: GAPDataType { .completeListOf128BitServiceUUIDs }

    public var uuids: [UUID]

    public init(uuids: [UUID]) {
        self.uuids = uuids
    }

    public init?<Data: DataContainer>(data: Data) {
        guard data.count > 0, data.count % UInt128.length == 0 else { return nil }
        var uuids: [UUID] = []
        var offset = 0
        while offset < data.count {
            guard let value = UInt128(data: data.subdata(in: offset ..< offset + UInt128.length)) else {
                return nil
            }
            uuids.append(UUID(value))
            offset += UInt128.length
        }
        self.init(uuids: uuids)
    }

    public func append<Data: DataContainer>(to data: inout Data) {
        for uuid in uuids {
            // UInt128(uuid:) holds the value; on this little-endian target its
            // in-memory bytes are exactly the little-endian order the AD wants.
            data += UInt128(uuid: uuid)
        }
    }

    public var dataLength: Int {
        uuids.count * UInt128.length
    }
}
