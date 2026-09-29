// The web proxy's per-device certificate authority (the app trusts its public
// certificate in the guest; the helper's WebProxy signs a leaf per HTTPS host
// with it). Security.framework only: RSA-2048 keys, SHA-1 signatures (iOS 3's
// TLS 1.0 stack), certificates encoded here in a few lines of DER.
//
// Files beside the routing CONFIG, as the old itwebproxy --init-ca wrote them,
// so a device keeps the CA its guest already trusts: CONFIG.ca.pem (PKCS#8
// private key then the certificate, mode 0600, owner only), CONFIG.ca.der
// (the public certificate), CONFIG.ca.lock (creation lock).

import Foundation
import Security

nonisolated struct WebProxyCA: @unchecked Sendable {
    let key: SecKey
    let certificate: SecCertificate
    /// The certificate's subject, as encoded: every leaf's issuer.
    let subject: Data

    enum Failure: Error { case unreadable(String), keyGeneration, signing, identity }

    /// Loads CONFIG.ca.pem, creating it on first use; (re)writes CONFIG.ca.der.
    static func prepare(config: URL) throws -> WebProxyCA {
        let lock = open(config.path + ".ca.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX) == 0 else { throw Failure.unreadable("lock") }
        defer { close(lock) }
        let pem = URL(fileURLWithPath: config.path + ".ca.pem")
        let ca: WebProxyCA
        if FileManager.default.fileExists(atPath: pem.path) {
            ca = try load(config: config)
        } else {
            let key = try newKey()
            let name = DER.name("Light Touch Device Proxy")
            let der = try certificate(key: key, issuerKey: key, issuer: name, subject: name, days: 3650, host: nil)
            let text = "-----BEGIN PRIVATE KEY-----\n" + DER.pkcs8(try external(key)).base64EncodedString(options: .lineLength64Characters)
                + "\n-----END PRIVATE KEY-----\n-----BEGIN CERTIFICATE-----\n" + der.base64EncodedString(options: .lineLength64Characters)
                + "\n-----END CERTIFICATE-----\n"
            try save(Data(text.utf8), to: pem, mode: 0o600)
            ca = try load(config: config)
        }
        try save(SecCertificateCopyData(ca.certificate) as Data, to: URL(fileURLWithPath: config.path + ".ca.der"), mode: 0o644)
        return ca
    }

    /// CONFIG.ca.pem, refused unless it is a regular file of this user's that nobody else can read.
    static func load(config: URL) throws -> WebProxyCA {
        let path = config.path + ".ca.pem"
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.unreadable(path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o077 == 0, st.st_mode & S_IFMT == S_IFREG,
              let text = String(data: handle.readDataToEndOfFile(), encoding: .utf8),
              let pkcs8 = pemBlock(text, "PRIVATE KEY"), let rsa = DER.children(pkcs8)?.last?.content,
              let certDER = pemBlock(text, "CERTIFICATE"),
              let key = SecKeyCreateWithData(rsa as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                                             kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, nil),
              let certificate = SecCertificateCreateWithData(nil, certDER as CFData),
              let certKey = SecCertificateCopyKey(certificate), let publicKey = SecKeyCopyPublicKey(key),
              SecKeyCopyExternalRepresentation(certKey, nil) as Data? == SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              let tbs = DER.children(certDER)?.first?.whole, let fields = DER.children(tbs), fields.count > 5
        else { throw Failure.unreadable(path) }
        return WebProxyCA(key: key, certificate: certificate, subject: fields[5].whole)
    }

    /// A TLS server identity for `host` (a DNS name or an IP literal), valid for a week, under this CA.
    func identity(for host: String, key leafKey: SecKey) throws -> SecIdentity {
        let der = try Self.certificate(key: leafKey, issuerKey: key, issuer: subject,
                                       subject: DER.name(host.utf8.count <= 64 ? host : "Light Touch Device Proxy"), days: 7, host: host)
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData),
              let identity = Self.createIdentity?(nil, certificate, leafKey)?.takeRetainedValue() else { throw Failure.identity }
        return identity
    }

    static func newKey() throws -> SecKey {
        guard let key = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil)
        else { throw Failure.keyGeneration }
        return key
    }

    // MARK: - Certificates

    /// SecIdentityCreate (Security.framework SPI): an identity from a key that isn't in a keychain.
    /// The public way (SecPKCS12Import's kSecImportToMemoryOnly) needs macOS 15; the app supports 14.4.
    private typealias IdentityCreate = @convention(c) (CFAllocator?, SecCertificate, SecKey) -> Unmanaged<SecIdentity>?
    private static let createIdentity: IdentityCreate? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecIdentityCreate")
        .map { unsafeBitCast($0, to: IdentityCreate.self) }

    private static func certificate(key: SecKey, issuerKey: SecKey, issuer: Data, subject: Data, days: Int, host: String?) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(key) else { throw Failure.keyGeneration }
        var serial = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        serial[0] &= 0x7f
        let now = Date()
        let rsa = DER.seq(DER.oid("1.2.840.113549.1.1.1"), DER.null)
        let spki = DER.seq(rsa, DER.bitString(try external(publicKey)))
        var extensions: [Data]
        if let host {
            let ip = [AF_INET, AF_INET6].lazy.compactMap { family -> Data? in
                var bytes = [UInt8](repeating: 0, count: 16)
                return inet_pton(family, host, &bytes) == 1 ? Data(bytes.prefix(family == AF_INET ? 4 : 16)) : nil
            }.first
            guard host.utf8.count <= 253, !host.isEmpty,
                  host.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-:".unicodeScalars.contains($0)) })
            else { throw Failure.signing }
            extensions = [DER.extension("2.5.29.19", critical: true, DER.seq()),                       // CA:FALSE
                          DER.extension("2.5.29.15", critical: true, Data([0x03, 0x02, 0x05, 0xa0])),  // digitalSignature, keyEncipherment
                          DER.extension("2.5.29.17", critical: false, DER.seq(ip.map { DER.tlv(0x87, $0) } ?? DER.tlv(0x82, Data(host.utf8)))),
                          DER.extension("2.5.29.37", critical: false, DER.seq(DER.oid("1.3.6.1.5.5.7.3.1")))]  // serverAuth
        } else {
            extensions = [DER.extension("2.5.29.19", critical: true, DER.seq(DER.tlv(0x01, Data([0xff])), DER.integer(Data([0])))),  // CA, pathlen 0
                          DER.extension("2.5.29.15", critical: true, Data([0x03, 0x02, 0x01, 0x06]))]  // keyCertSign, cRLSign
        }
        let sha1RSA = DER.seq(DER.oid("1.2.840.113549.1.1.5"), DER.null)
        let tbs = DER.seq(DER.tlv(0xa0, DER.integer(Data([2]))), DER.integer(serial), sha1RSA, issuer,
                          DER.seq(DER.time(now - 86400), DER.time(now + Double(days) * 86400)), subject, spki,
                          DER.tlv(0xa3, DER.seq(extensions.reduce(Data(), +))))
        guard let signature = SecKeyCreateSignature(issuerKey, .rsaSignatureMessagePKCS1v15SHA1, tbs as CFData, nil) as Data?
        else { throw Failure.signing }
        return DER.seq(tbs, sha1RSA, DER.bitString(signature))
    }

    private static func external(_ key: SecKey) throws -> Data {
        guard let data = SecKeyCopyExternalRepresentation(key, nil) as Data? else { throw Failure.keyGeneration }
        return data
    }

    private static func pemBlock(_ text: String, _ label: String) -> Data? {
        guard let start = text.range(of: "-----BEGIN \(label)-----"), let end = text.range(of: "-----END \(label)-----", range: start.upperBound..<text.endIndex)
        else { return nil }
        return Data(base64Encoded: String(text[start.upperBound..<end.lowerBound]), options: .ignoreUnknownCharacters)
    }

    private static func save(_ data: Data, to url: URL, mode: mode_t) throws {
        let temporary = url.path + ".\(getpid()).tmp"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw Failure.unreadable(temporary) }
        let ok = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) == $0.count }
        guard close(fd) == 0, ok, rename(temporary, url.path) == 0 else { unlink(temporary); throw Failure.unreadable(url.path) }
    }
}

/// Just enough DER for the certificates above and for reading them back.
nonisolated enum DER {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var length = Data()
        if content.count < 0x80 { length.append(UInt8(content.count)) } else {
            var n = content.count, bytes: [UInt8] = []
            while n > 0 { bytes.insert(UInt8(n & 0xff), at: 0); n >>= 8 }
            length = Data([0x80 | UInt8(bytes.count)] + bytes)
        }
        return Data([tag]) + length + content
    }
    static func seq(_ parts: Data...) -> Data { tlv(0x30, parts.reduce(Data(), +)) }
    static let null = Data([0x05, 0x00])
    static func integer(_ bytes: Data) -> Data {
        var value = bytes.drop { $0 == 0 }
        if value.isEmpty || value.first! & 0x80 != 0 { value.insert(0, at: value.startIndex) }
        return tlv(0x02, Data(value))
    }
    static func bitString(_ bytes: Data) -> Data { tlv(0x03, Data([0]) + bytes) }
    static func oid(_ dotted: String) -> Data {
        let arcs = dotted.split(separator: ".").map { UInt($0)! }
        var out = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for var arc in arcs.dropFirst(2) {
            var chunk = [UInt8(arc & 0x7f)]
            arc >>= 7
            while arc > 0 { chunk.insert(UInt8(arc & 0x7f) | 0x80, at: 0); arc >>= 7 }
            out.append(contentsOf: chunk)
        }
        return tlv(0x06, out)
    }
    /// CN=`commonName`, a UTF8String.
    static func name(_ commonName: String) -> Data {
        seq(tlv(0x31, seq(oid("2.5.4.3"), tlv(0x0c, Data(commonName.utf8)))))
    }
    static func `extension`(_ id: String, critical: Bool, _ value: Data) -> Data {
        seq(oid(id), critical ? tlv(0x01, Data([0xff])) : Data(), tlv(0x04, value))
    }
    /// UTCTime through 2049, GeneralizedTime after (RFC 5280 4.1.2.5).
    static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy"
        let generalized = Int(formatter.string(from: date))! >= 2050
        formatter.dateFormat = generalized ? "yyyyMMddHHmmss'Z'" : "yyMMddHHmmss'Z'"
        return tlv(generalized ? 0x18 : 0x17, Data(formatter.string(from: date).utf8))
    }
    /// PrivateKeyInfo around a PKCS#1 RSAPrivateKey (what OpenSSL's PEM_write_PrivateKey wrote).
    static func pkcs8(_ rsa: Data) -> Data {
        seq(integer(Data([0])), seq(oid("1.2.840.113549.1.1.1"), null), tlv(0x04, rsa))
    }
    /// The elements inside one constructed element: each one whole and its content.
    static func children(_ data: Data) -> [(whole: Data, content: Data)]? {
        let bytes = [UInt8](data)
        func element(at i: Int) -> (end: Int, contentStart: Int)? {
            guard i + 1 < bytes.count else { return nil }
            var length = Int(bytes[i + 1]), start = i + 2
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard count > 0, count <= 4, start + count <= bytes.count else { return nil }
                length = bytes[start..<start + count].reduce(0) { $0 << 8 | Int($1) }
                start += count
            }
            guard start + length <= bytes.count else { return nil }
            return (start + length, start)
        }
        guard let outer = element(at: 0) else { return nil }
        var result: [(Data, Data)] = [], i = outer.contentStart
        while i < outer.end {
            guard let inner = element(at: i), inner.end <= outer.end else { return nil }
            result.append((Data(bytes[i..<inner.end]), Data(bytes[inner.contentStart..<inner.end])))
            i = inner.end
        }
        return result
    }
}
