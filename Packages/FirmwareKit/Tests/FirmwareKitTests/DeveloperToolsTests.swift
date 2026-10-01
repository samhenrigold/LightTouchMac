import Foundation
import Testing
@testable import FirmwareKit

struct DeveloperToolsTests {
    @Test(arguments: ["9B206", "7B500"])
    func rejectsUnsupportedOrSeedOnlyOffer(build: String) throws {
        try Oracle.withTemp { root in
            let offer = root.appendingPathComponent("offer")
            try FileManager.default.createDirectory(at: offer, withIntermediateDirectories: true)
            let original = Data("ltpkg 1\nbuild \(build)\nserial 0 seed\n".utf8)
            try original.write(to: offer.appendingPathComponent("offer"))
            #expect(throws: (any Error).self) {
                try DeveloperTools.augment(offer: offer, payload: root.appendingPathComponent("absent"),
                    state: root.appendingPathComponent("state"), instance: UUID(), serial: 100)
            }
            #expect(try Data(contentsOf: offer.appendingPathComponent("offer")) == original)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("state").path))
        }
    }

    @Test func refusesUntrustedBundleBeforePublishingKeysOrOffer() throws {
        try Oracle.withTemp { root in
            let offer = root.appendingPathComponent("offer"), payload = root.appendingPathComponent("payload")
            for url in [offer, payload] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            let original = Data("ltpkg 1\nbuild 7B500\nserial 9 seed\n".utf8)
            try original.write(to: offer.appendingPathComponent("offer"))
            // A manifest supplied alongside altered binaries is not a trusted hash source.
            let untrusted = DeveloperTools.BundleManifest(source: DeveloperTools.source,
                files: Dictionary(uniqueKeysWithValues: DeveloperTools.targets.map { ($0, String(repeating: "0", count: 64)) }))
            try JSONEncoder().encode(untrusted).write(to: payload.appendingPathComponent("developer-tools.json"))
            #expect(throws: (any Error).self) {
                try DeveloperTools.augment(offer: offer, payload: payload, state: root.appendingPathComponent("state"),
                    instance: UUID(), serial: 100)
            }
            #expect(try Data(contentsOf: offer.appendingPathComponent("offer")) == original)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("state").path))
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FK_DEVELOPER_PAYLOAD"] != nil,
                   "Pinned developer payload fixture; set FK_DEVELOPER_PAYLOAD to run"))
    func isolatesAndRetainsKeysAndRejectsChangedPins() throws {
        let payload = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FK_DEVELOPER_PAYLOAD"]!)
        try Oracle.withTemp { root in
            let state = root.appendingPathComponent("private"), id = UUID(), other = UUID()
            func offer(_ name: String) throws -> URL {
                let path = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                try Data("ltpkg 1\nbuild 7B500\nserial 9 seed\n".utf8).write(to: path.appendingPathComponent("offer"))
                return path
            }
            let first = try DeveloperTools.augment(offer: offer("one"), payload: payload, state: state, instance: id, serial: 101)
            let directory = state.appendingPathComponent(id.uuidString.lowercased())
            let originalHost = try Data(contentsOf: directory.appendingPathComponent("ssh_host_ecdsa_key"))
            let originalClient = try Data(contentsOf: directory.appendingPathComponent("id_ecdsa"))
            let repeatOffer = try offer("two")
            let repeated = try DeveloperTools.augment(offer: repeatOffer, payload: payload, state: state, instance: id, serial: 102)
            #expect(first.hostPublicKey == repeated.hostPublicKey)
            #expect(first.clientIdentity == repeated.clientIdentity)
            #expect(try Data(contentsOf: directory.appendingPathComponent("ssh_host_ecdsa_key")) == originalHost)
            #expect(try Data(contentsOf: directory.appendingPathComponent("id_ecdsa")) == originalClient)
            let isolated = try DeveloperTools.augment(offer: offer("other"), payload: payload, state: state, instance: other, serial: 101)
            #expect(first.hostPublicKey != isolated.hostPublicKey)
            #expect(first.clientIdentity != isolated.clientIdentity)
            let broken = try offer("broken")
            let untouched = try Data(contentsOf: broken.appendingPathComponent("offer"))
            try Data("untrusted-host ecdsa-sha2-nistp256 changed\n".utf8).write(to: directory.appendingPathComponent("known_hosts"))
            #expect(throws: (any Error).self) {
                try DeveloperTools.augment(offer: broken, payload: payload, state: state, instance: id, serial: 103)
            }
            #expect(try Data(contentsOf: broken.appendingPathComponent("offer")) == untouched)
            #expect(!FileManager.default.fileExists(atPath: broken.appendingPathComponent("developer").path))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FK_DEVELOPER_PAYLOAD"] != nil,
                   "Complete qualified release payload fixture required"),
          arguments: ["missing-binary", "tampered-binary", "missing-source", "tampered-source", "missing-notice", "tampered-notice", "private-key", "symlink"])
    func releaseAuditRejectsIncompleteOrPrivatePayload(damage: String) throws {
        let original = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FK_DEVELOPER_PAYLOAD"]!)
        try DeveloperTools.audit(payload: original, redistribution: true)
        try Oracle.withTemp { root in
            let payload = root.appendingPathComponent("payload")
            try FileManager.default.copyItem(at: original, to: payload)
            let target: String
            switch damage {
            case "missing-binary", "tampered-binary": target = "usr/sbin/sshd"
            case "missing-source", "tampered-source": target = "Sources/bash-4.0.tar.gz"
            case "missing-notice", "tampered-notice": target = "Licenses/Bash-GPL-3.txt"
            default: target = "ssh_host_ecdsa_key"
            }
            let file = payload.appendingPathComponent(target)
            if damage.hasPrefix("missing") {
                try FileManager.default.removeItem(at: file)
            } else if damage == "symlink" {
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: original.appendingPathComponent("bin/bash"))
            } else {
                try Data("altered or private material".utf8).write(to: file)
            }
            #expect(throws: (any Error).self) {
                try DeveloperTools.audit(payload: payload, redistribution: true)
            }
        }
    }

}
