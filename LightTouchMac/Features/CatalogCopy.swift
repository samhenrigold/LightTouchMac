import Foundation
import CryptoKit

nonisolated struct CatalogCopy: Decodable, Sendable {
    let ipa_id: String
    let filename: String?
    let size: Int64?
    let md5: String?
    let available: Bool
    let version: String?
    let bundle_id: String?
    let binary: Binary?

    struct Binary: Decodable, Sendable {
        let install_status: String?
        let architectures: [String]?
        let macho_min_os: String?
        let device_family_macho: [String]?
        /// API 2.1: the armv6 slice's instructions are really ARMv7 (a
        /// cracked release that relabelled its armv7 slice); nil = not scanned.
        let armv7_code: Bool?

        enum CodingKeys: String, CodingKey { case install_status, architectures, macho_min_os, device_family_macho, armv7_code }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            install_status = try c.decodeIfPresent(String.self, forKey: .install_status)
            architectures = try c.decodeIfPresent([String].self, forKey: .architectures)
            macho_min_os = try c.decodeIfPresent(String.self, forKey: .macho_min_os)
            armv7_code = try c.decodeIfPresent(Bool.self, forKey: .armv7_code)
            // The server sends the Mach-O families as numbers ([1,2]) while compat.device_family is strings; take either.
            if let strings = try? c.decodeIfPresent([String].self, forKey: .device_family_macho) {
                device_family_macho = strings
            } else {
                device_family_macho = try c.decodeIfPresent([Int].self, forKey: .device_family_macho)?.map(String.init)
            }
        }
    }

    /// `deviceOS`: the device's iOS version (its catalog entry).
    static func osIssue(_ value: String?, deviceOS: String = "3.1.3") -> String? {
        guard let value else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(part)
        }
        guard numbers.count == parts.count, !numbers.isEmpty, numbers.count <= 3,
              numbers[0] > 0 else { return "The minimum iOS version could not be verified." }
        let padded = numbers + Array(repeating: 0, count: 3 - numbers.count)
        let device = deviceOS.split(separator: ".").compactMap { Int($0) }
        let devicePadded = device + Array(repeating: 0, count: max(0, 3 - device.count))
        return devicePadded.lexicographicallyPrecedes(padded)
            ? "Requires iOS \(value); this device runs iOS \(deviceOS)." : nil
    }

    /// Whether a device whose CPU is `arch` has a slice here it can execute:
    /// an armv7 CPU (the iPad) runs armv6 slices too, as Legacy Store judges.
    static func runs(_ architectures: [String]?, on arch: String) -> Bool {
        architectures?.contains { $0 == arch || (arch == "armv7" && $0 == "armv6") } == true
    }

    /// `arch`: the device's CPU (armv6 on the iPod touch 1G/2G, armv7 on the iPad).
    func unavailableReason(minimumOS: String?, deviceOS: String = "3.1.3", arch: String = "armv6") -> String? {
        guard available else { return "This archived download is no longer available." }
        guard let binary else { return "This copy has not been analyzed for compatibility." }
        guard binary.install_status == "installable" else {
            return binary.install_status == "encrypted"
                ? "This copy is encrypted and can’t launch in Light Touch."
                : "This copy has not been classified as installable."
        }
        // Also an armv6 slice that is really ARMv7 code (API 2.1's scan): an
        // armv7 CPU runs it, an armv6 one can't.
        guard Self.runs(binary.architectures, on: arch), arch != "armv6" || binary.armv7_code != true else {
            return "This copy needs a newer processor than this device has."
        }
        if let family = binary.device_family_macho, !family.isEmpty, !family.contains("1"), !family.contains("2") {
            return "This copy does not support iPhone, iPod touch or iPad."
        }
        return Self.osIssue(minimumOS, deviceOS: deviceOS) ?? Self.osIssue(binary.macho_min_os, deviceOS: deviceOS)
    }

    /// MD5 is the archive's file-integrity check, not a signature or trust decision.
    /// Hash chunks off the main actor; never load an entire IPA into memory.
    @concurrent func verifyDownload(_ file: URL) async throws {
        let actual = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        guard let actual, actual.int64Value > 0,
              size == nil || size == actual.int64Value else {
            throw CatalogError.invalidCopy("The download is incomplete or its size differs from the archive.")
        }
        guard let md5 else { return }
        guard md5.count == 32, md5.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw CatalogError.invalidCopy("The archive supplied an invalid file checksum.")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == md5.lowercased() else {
            throw CatalogError.invalidCopy("The downloaded IPA failed its checksum check. Try downloading it again.")
        }
    }
}

nonisolated struct CatalogVersion: Decodable, Sendable {
    let version: String?
    let minimum_os_version: String?
    let copies: [Copy]

    struct Copy: Decodable, Sendable {
        let ipa_id: String
        let size: Int64?
        let install_status: String?
        let architectures: [String]?
        let macho_min_os: String?
    }
}
