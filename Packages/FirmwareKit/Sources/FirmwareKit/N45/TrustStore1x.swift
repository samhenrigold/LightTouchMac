// iPhone OS 1.x's certificate anchors. 1.0's SecTrust asks only the system anchor source, the trust store in
// Security.framework (table tsettings, the schema 2.x/3.x keep for their user store); the user store
// (~/Library/Keychains/TrustStore.sqlite3) is never consulted. A row there makes a certificate an anchor:
// sha1 of its DER, subj the subject Name's content as 1.x normalizes it (PrintableString values uppercased,
// every other string type as issued, read off the stock rows), tset the stock rows' empty-array plist, data the
// DER. Checked on M68 1A543a: with the row, SecTrustEvaluate gives 4 (unspecified) for a WebProxyCA-shaped
// chain and Safari opens HTTPS through a TLS 1.0 relay; without it, 3 (deny).

import BinaryParsing
import CSQLiteDefense
import Crypto
import FirmwareSchema
import Foundation
import HostRuntime
import SQLite3

public enum TrustStore1x {
    static let path = "System/Library/Frameworks/Security.framework/TrustStore.sqlite3"
    /// The stock rows' tset: an empty trust-settings array.
    static let emptySettings = Data(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <array/>
        </plist>

        """.utf8
    )

    /// The DER element `s` starts with: its tag and its content's range; `s` moves past it.
    private static func element(_ s: inout ParserSpan) throws -> (tag: UInt8, content: ParserRange) {
        let tag = try UInt8(parsing: &s)
        var length = Int(try UInt8(parsing: &s))
        if length & 0x80 != 0 {
            let n = length & 0x7f
            guard n <= 3 else { throw FirmwareError(.unsupported, "certificate length") }
            length = 0
            for _ in 0..<n { length = length << 8 | Int(try UInt8(parsing: &s)) }
        }
        return (tag, try s.sliceRange(byteCount: length))
    }

    /// The certificate's subject Name content, normalized as 1.x stores it.
    static func normalizedSubject(_ certificate: Data) throws -> Data {
        let d = [UInt8](certificate)
        let name = try parsing(d, "certificate") { s in
            var certificate = try s.seeking(toRange: try element(&s).content)
            var tbs = try certificate.seeking(toRange: try element(&certificate).content)
            if try tbs.byte(at: 0) == 0xa0 { _ = try element(&tbs) }  // version
            for _ in 0..<4 { _ = try element(&tbs) }  // serial, signature, issuer, validity
            return try element(&tbs).content
        }
        var out = Array(d[name.lowerBound..<name.upperBound])
        // Walk the RDNs: SET { SEQUENCE { OID, value } }; uppercase PrintableString (0x13) values in place.
        let printable = try parsing(out, "certificate subject") { s in
            var values: [Range<Int>] = []
            while !s.isEmpty {
                var set = try s.seeking(toRange: try element(&s).content)
                while !set.isEmpty {
                    var atv = try set.seeking(toRange: try element(&set).content)
                    _ = try element(&atv)  // the OID
                    let value = try element(&atv)
                    if value.tag == 0x13 { values.append(value.content.lowerBound..<value.content.upperBound) }
                }
            }
            return values
        }
        for r in printable { for i in r where (0x61...0x7a).contains(out[i]) { out[i] -= 0x20 } }
        return Data(out)
    }

    /// Adds (or replaces) `certificate` as an anchor in the trust store at `store` on the device's volume. SQLite
    /// edits a host copy (DevicePath.read), written back in place (DevicePath.write), so it opens nothing there.
    static func addAnchor(_ certificate: Data, to store: URL) throws {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("TrustStore-\(UUID().uuidString)")
        try DevicePath.read(store).write(to: copy)  // host file
        defer { for suffix in ["", "-journal"] { unlink(copy.path + suffix) } }  // host file
        try addAnchor(certificate, copy: copy, name: store.path)
        try DevicePath.write(Data(contentsOf: copy), store)  // host file
    }

    private static func addAnchor(_ certificate: Data, copy: URL, name: String) throws {
        let subject = try normalizedSubject(certificate)
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {  // host file
            sqlite3_close(db)
            throw FirmwareError(.unsupported, "\(name): not a trust store")
        }
        defer { sqlite3_close(db) }
        // The guest wrote this database: its schema runs nothing here (no trigger, view or schema function).
        guard lt_sqlite_defend(db) == SQLITE_OK else {
            throw FirmwareError(.internal, "\(name): \(String(cString: sqlite3_errmsg(db)))")
        }
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                "INSERT OR REPLACE INTO tsettings(sha1,subj,tset,data) VALUES(?,?,?,?)",
                -1,
                &stmt,
                nil
            ) == SQLITE_OK
        else { throw FirmwareError(.unsupported, "\(name): no tsettings table") }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, blob) in [Data(Insecure.SHA1.hash(data: certificate)), subject, emptySettings, certificate].enumerated()
        {
            _ = blob.withUnsafeBytes {
                sqlite3_bind_blob(stmt, Int32(i + 1), $0.baseAddress, Int32(blob.count), transient)
            }
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw FirmwareError(.unsupported, "\(name): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// The device directory's record of the anchor its guest trusts (FirmwareWire.trustAnchorFile). A new
    /// storage generation (prepared again, another edit) has another key, so the anchor is written again.
    public static let marker = FirmwareWire.trustAnchorFile

    /// Makes `certificate` an anchor in a stopped 1.x device's system volume, through a stopped edit (begin, mount,
    /// the row, commit: the 1.x FTL is written in place). False when the device already trusts it.
    nonisolated(nonsending) public static func trust(
        device: URL,
        certificate: Data,
        policy: StorageRecordPolicy = .standalone,
        log: (String) -> Void = { _ in }
    ) async throws -> Bool {
        let sha1 = Insecure.SHA1.hash(data: certificate).hexString
        func storageKey() throws -> String? {
            let record = try DeviceRecord.object(Data(contentsOf: DeviceRecord.url(device)))  // host file
            guard HostRuntime.Board(rawValue: record["board"] as? String ?? "")?.soc == .s5l8900 else {
                throw FirmwareError(.unsupported, "trust anchors are written into 1.x devices only")
            }
            return (record["storage"] as? [String: Any])?["key"] as? String
        }
        // The anchor lives in the overlay, which Erase removes while the key stays: the overlay's stamp says it holds it.
        func overlayStamp() throws -> URL? {
            let owner = try OwnedStorageRecord.acquire(device: device, policy: policy)
            defer { withExtendedLifetime(owner) {} }
            return owner.paths?.overlay.appendingPathComponent(".trust-anchor")
        }
        let markerURL = device.appendingPathComponent(marker)
        if let data = try? Data(contentsOf: markerURL),  // host file
            let m = try? JSONSerialization.jsonObject(with: data) as? [String: String],
            m["sha1"] == sha1, m["key"] == (try storageKey()),
            let stamp = try overlayStamp(), (try? String(contentsOf: stamp, encoding: .utf8)) == sha1  // host file
        {
            return false
        }
        _ = try normalizedSubject(certificate)  // a certificate this can parse, before any work
        let session = try await StoppedVolumeEdit.begin(device: device, policy: policy, log: log)
        do {
            let point = session.image.deletingLastPathComponent().appendingPathComponent("trust-anchor-mount")
            try await VolumeMount.withVolume(session.image, at: point) { v in
                if let m = v as? MountedVolume { return try addAnchor(certificate, to: m.url(path)) }
                // the store is a SQLite file: edited as a file on the host, then put back in place
                let copy = session.image.deletingLastPathComponent().appendingPathComponent("trust-store")
                defer { try? FileManager.default.removeItem(at: copy) }  // host file
                try v.contents(at: path).write(to: copy)  // host file
                try addAnchor(certificate, to: copy)
                try v.put(contentsOf: copy, at: path, mode: nil)  // host file
            }
            log("anchor \(sha1) added to /\(path)")
            try await StoppedVolumeEdit.commit(device: device, id: session.id, policy: policy, log: log)
        } catch {
            try? await StoppedVolumeEdit.discard(device: device, id: session.id, policy: policy)
            throw error
        }
        if let stamp = try overlayStamp() { try N72NAND.writeDurably(Data(sha1.utf8), to: stamp) }
        let record = try JSONSerialization.data(
            withJSONObject: ["sha1": sha1, "key": try storageKey() ?? ""],
            options: [.sortedKeys]
        )
        try record.write(to: markerURL, options: .atomic)  // host file
        return true
    }
}
