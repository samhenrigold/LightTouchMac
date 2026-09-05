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
    }

    static func osIssue(_ value: String?) -> String? {
        guard let value else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(part)
        }
        guard numbers.count == parts.count, !numbers.isEmpty, numbers.count <= 3,
              numbers[0] > 0 else { return "The minimum iOS version could not be verified." }
        let padded = numbers + Array(repeating: 0, count: 3 - numbers.count)
        return [3, 1, 3].lexicographicallyPrecedes(padded)
            ? "Requires iOS \(value); this device runs iOS 3.1.3." : nil
    }

    func unavailableReason(minimumOS: String?) -> String? {
        guard available else { return "This archived download is no longer available." }
        guard let binary else { return "This copy has not been analyzed for compatibility." }
        guard binary.install_status == "installable" else {
            return binary.install_status == "encrypted"
                ? "This copy is FairPlay-encrypted and cannot launch in the emulator."
                : "This copy has not been classified as installable."
        }
        guard binary.architectures?.contains("armv6") == true else {
            return "This copy has no ARMv6 executable for the iPod touch 2G."
        }
        if let family = binary.device_family_macho, !family.isEmpty, !family.contains("1") {
            return "This copy does not support iPhone or iPod touch."
        }
        return Self.osIssue(minimumOS) ?? Self.osIssue(binary.macho_min_os)
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
