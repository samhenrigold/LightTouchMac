import Crypto
import Foundation
import HostRuntime
import SQLite3
import Testing

@testable import FirmwareKit

@Suite(.detachesItsImages) struct TrustStore1xTests {
    static func tlv(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag, UInt8(body.count)] + body }
    /// A certificate skeleton: version, serial, signature, issuer, validity, subject (C=us PrintableString,
    /// CN=Light Touch UTF8String); nothing after the subject matters to the normalization.
    static let subjectContent =
        tlv(0x31, tlv(0x30, tlv(0x06, [0x55, 0x04, 0x06]) + tlv(0x13, Array("us".utf8))))
        + tlv(0x31, tlv(0x30, tlv(0x06, [0x55, 0x04, 0x03]) + tlv(0x0c, Array("Light Touch".utf8))))
    static let certificate = Data(
        tlv(
            0x30,
            tlv(
                0x30,
                tlv(0xa0, tlv(0x02, [2])) + tlv(0x02, [1]) + tlv(0x30, tlv(0x06, [0x2a]))
                    + tlv(0x30, []) + tlv(0x30, []) + tlv(0x30, subjectContent)
            )
        )
    )

    /// 1.x stores PrintableString values uppercased and every other string type as issued (the stock store's
    /// "Prefectural Association For JPKI" is a UTF8String kept as it is; Entrust's "ENTRUST.NET" a PrintableString).
    @Test func normalizesPrintableStringsOnly() throws {
        let normalized = try TrustStore1x.normalizedSubject(Self.certificate)
        var expected = Self.subjectContent
        let us = expected.firstIndex(of: UInt8(ascii: "u"))!
        expected[us] = UInt8(ascii: "U")
        expected[us + 1] = UInt8(ascii: "S")
        #expect(normalized == Data(expected))
        #expect(String(decoding: normalized, as: UTF8.self).contains("Light Touch"))
    }

    /// Every anchor in a 1.x firmware's own store (FK_TRUSTSTORE_1X: its Security.framework/TrustStore.sqlite3):
    /// its subj column is normalizedSubject of its data, its tset the empty settings.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"))
    func matchesTheStockStore() throws {
        guard let path = ProcessInfo.processInfo.environment["FK_TRUSTSTORE_1X"] else {
            try FixtureRequirements.missing("FK_TRUSTSTORE_1X")
        }
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT subj,data,tset FROM tsettings", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        var rows = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let subj = Data(bytes: sqlite3_column_blob(stmt, 0), count: Int(sqlite3_column_bytes(stmt, 0)))
            let data = Data(bytes: sqlite3_column_blob(stmt, 1), count: Int(sqlite3_column_bytes(stmt, 1)))
            #expect(try TrustStore1x.normalizedSubject(data) == subj)
            #expect(
                Data(bytes: sqlite3_column_blob(stmt, 2), count: Int(sqlite3_column_bytes(stmt, 2)))
                    == TrustStore1x.emptySettings
            )
            rows += 1
        }
        #expect(rows > 100)
    }

    @Test func addsAnAnchorRowAsTheStockRowsAre() throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("ts-\(UUID()).sqlite3")
        defer { try? FileManager.default.removeItem(at: store) }
        var db: OpaquePointer?
        #expect(sqlite3_open(store.path, &db) == SQLITE_OK)
        #expect(
            sqlite3_exec(
                db,
                "CREATE TABLE tsettings(sha1 BLOB NOT NULL DEFAULT '',subj BLOB NOT NULL DEFAULT '',tset BLOB,data BLOB,PRIMARY KEY(sha1));",
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        sqlite3_close(db)
        try TrustStore1x.addAnchor(Self.certificate, to: store)
        try TrustStore1x.addAnchor(Self.certificate, to: store)  // idempotent: one row per certificate

        #expect(sqlite3_open(store.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT sha1,subj,tset,data FROM tsettings", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        func blob(_ i: Int32) -> Data {
            Data(bytes: sqlite3_column_blob(stmt, i), count: Int(sqlite3_column_bytes(stmt, i)))
        }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(blob(0) == Data(Insecure.SHA1.hash(data: Self.certificate)))
        #expect(blob(1) == (try TrustStore1x.normalizedSubject(Self.certificate)))
        #expect(blob(2) == TrustStore1x.emptySettings)
        #expect(blob(3) == Self.certificate)
        #expect(sqlite3_step(stmt) == SQLITE_DONE)
    }

    /// A stopped 1.x device (N45FTLTests' booted-guest store around a volume with an empty system trust store):
    /// trust() writes the row through a stopped edit, records the marker, and does nothing the second time.
    @Test func trustsThroughAStoppedEdit() async throws {
        let fm = FileManager.default
        let root = try Fixtures.tempDir("trust1x-edit")
        defer { try? fm.removeItem(at: root) }
        let device = root.appendingPathComponent("device")
        let base = device.appendingPathComponent("base")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("volume.img")
        let store = root.appendingPathComponent("TrustStore.sqlite3")
        var db: OpaquePointer?
        #expect(sqlite3_open(store.path, &db) == SQLITE_OK)
        #expect(
            sqlite3_exec(
                db,
                "CREATE TABLE tsettings(sha1 BLOB NOT NULL DEFAULT '',subj BLOB NOT NULL DEFAULT '',tset BLOB,data BLOB,PRIMARY KEY(sha1));",
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        sqlite3_close(db)
        try Fixtures.makeVolume(image, size: 16 << 20, name: "Trust test") { v in
            try v.makeDirectory((TrustStore1x.path as NSString).deletingLastPathComponent)
            try v.put(contentsOf: store, at: TrustStore1x.path)
        }
        try N45NAND.write(
            volume: image,
            out: base.appendingPathComponent("nand"),
            filID: 0x4330_3030,
            banks: N45FTLTests.banks
        )
        let overlay = device.appendingPathComponent("overlay")
        try N45FTLTests.booted(overlay, base.appendingPathComponent("nand"), changeData: false)
        try Data("{}".utf8).write(to: base.appendingPathComponent("device.lock.json"))
        let record: [String: Any] = [
            "id": UUID().uuidString, "board": "m68ap", "firmware": "test",
            "base": ["kind": "prepared", "path": base.path],
            "storage": ["key": "old", "overlay": overlay.path, "snapshot": "old-snapshot"]
        ]
        try DeviceRecord.data(record).write(to: device.appendingPathComponent(DeviceRecord.name))

        #expect(try await TrustStore1x.trust(device: device, certificate: Self.certificate))
        #expect(try await TrustStore1x.trust(device: device, certificate: Self.certificate) == false)  // the marker

        // Erase (DeviceStateStorage.erase) removes the overlay the anchor went into and keeps the storage key:
        // the next start writes the anchor again.
        let erased = try #require(
            try DeviceRecord.object(Data(contentsOf: device.appendingPathComponent(DeviceRecord.name)))["storage"]
                as? [String: Any]
        )
        try fm.removeItem(at: URL(fileURLWithPath: try #require(erased["overlay"] as? String)))
        #expect(try await TrustStore1x.trust(device: device, certificate: Self.certificate))

        let published = try DeviceRecord.object(Data(contentsOf: device.appendingPathComponent(DeviceRecord.name)))
        let newBase = URL(fileURLWithPath: try #require((published["base"] as? [String: Any])?["path"] as? String))
        let newOverlay = URL(
            fileURLWithPath: try #require((published["storage"] as? [String: Any])?["overlay"] as? String)
        )
        let rebuilt = try VolumeRebuild.rebuild(
            base: newBase.appendingPathComponent("nand"),
            overlay: newOverlay,
            into: root.appendingPathComponent("verify")
        )[0]
        let check = root.appendingPathComponent("check.sqlite3")
        try HFSPlusVolume(rebuilt.image).contents(HFSPlusVolume(rebuilt.image).record(at: TrustStore1x.path)).write(
            to: check
        )
        db = nil
        #expect(sqlite3_open(check.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT data FROM tsettings", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(
            Data(bytes: sqlite3_column_blob(stmt, 0), count: Int(sqlite3_column_bytes(stmt, 0))) == Self.certificate
        )
    }
}
