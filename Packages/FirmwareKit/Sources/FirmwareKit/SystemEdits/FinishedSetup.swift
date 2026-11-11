// FinishedSetup: Setup Assistant's finished state, seeded into the data volume's /private/var skeleton (recipe option
// skip_setup, firmwarekit create --skip-setup), so a fresh iOS 5-8 device starts at the Home screen.
//
// The keys are the ones Setup itself writes on a walk that picks English, the region, Location Services off, no Wi-Fi,
// a new device, no Apple ID or passcode, the terms and Don't Send: the data volume of each base diffed before and
// after the sessions harness's walk (n81ap/k48ap 9B206, n90ap 10B329, n90ap 11D257). What the boot's other parts
// write anyway (lockdown's zone and clock, it_prefs, caches) is left to them. The language and region are
// seedLanguage's, which every prepared device gets.
// The 8.0 additions follow the original 12A365 Preferences setup predicate and Setup's own marker names;
// live qualification of that profile is recorded separately from the walked 5-7 fixtures.

import BinaryParsing
import Foundation

extension SystemEdits {
    /// The same setup records used for image preparation, exported for native
    /// guest provisioning. Callers merge them with existing device records;
    /// live preference domains must be synchronized through CFPreferences.
    public static func finishedSetupPlists(
        major: Int, productVersion: String,
        language: String = "en", locale: String = "en_US", locationServicesEnabled: Bool = false,
        a6: Bool = false
    ) throws -> [String: Data] {
        try Dictionary(
            uniqueKeysWithValues: finishedSetup(
                major: major, language: language, locale: locale,
                productVersion: productVersion, locationServicesEnabled: locationServicesEnabled,
                a6: a6
            ).map { path, keys in
                (path, try PropertyListSerialization.data(fromPropertyList: keys, format: .binary, options: 0))
            })
    }
    /// One plist under /private/var and the keys it gets.
    typealias Seed = (path: String, keys: [String: Any])

    static let purpleBuddy = "mobile/Library/Preferences/com.apple.purplebuddy.plist"
    static let purpleBuddyLocal = "mobile/Library/Preferences/com.apple.purplebuddy.notbackedup.plist"
    static let locationd = "mobile/Library/Preferences/com.apple.locationd.plist"
    static let locationdLocal = "mobile/Library/Preferences/com.apple.locationd.notbackedup.plist"
    static let globalPreferences = "mobile/Library/Preferences/.GlobalPreferences.plist"
    static let dataArk = "root/Library/Lockdown/data_ark.plist"

    /// What Setup leaves on iOS `major` (5-8) in `language` and `locale` ("en", "en_AU"), finished at
    /// `now`; empty before 5 (iTunes activated those, no Setup Assistant). `a6`: the iPhone 5, whose 6.x Setup also asks
    /// about Siri.
    static func finishedSetup(
        major: Int, language: String, locale: String, now: Date = Date(), productVersion: String? = nil,
        locationServicesEnabled: Bool = false, a6: Bool = false
    ) -> [Seed] {
        guard major >= 5 else { return [] }
        var buddy: [String: Any] = [
            "SetupDone": true, "SetupFinishedAllSteps": true, "RestoreChoice": true, "PBTCPresented": true,
            "PBDiagnosticsPresented": true, "WiFiPresented": true, "Language": language, "Locale": locale
        ]
        let off: [String: Any]
        var buddyLocal: [String: Any]
        var ark: [String: Any]
        var extra: [Seed] = []
        switch major {
        case 5, 6:
            buddy[major == 5 ? "AppleIDPresented" : "AppleIDPB3Presented"] = true
            if major == 6 {
                buddy["SetupVersion"] = 3
                // Siri-capable 6.x devices also run PSSetupAssistantNeedsToRun's
                // assistant-upgrade predicate. The walked N90 has no Siri step, and no other board in the catalog
                // runs Siri: the iPhone 5 only.
                if a6 { buddy["AssistantPresented"] = true }
            }
            buddyLocal = ["LocationServicesPresented": true]
            off = ["LocationServicesEnabled": locationServicesEnabled ? 1 : 0]
            ark = [
                "com.apple.purplebuddy-SetupState": "SetupUsingAssistant",
                "com.apple.mobile.user_preferences-UserSetLanguage": true,
                "com.apple.mobile.user_preferences-UserSetLocale": true
            ]
        default:
            buddy.merge(
                [
                    "AppleIDPB5Presented": true, "PasscodePresented": true, "SetupVersion": 5,
                    "SetupState": "SetupUsingAssistant", "AppleIDForceUpgrade": false
                ]
            ) { $1 }
            // Native N42 11A465 completed setup uses version 4 / PB4 and
            // records the Siri choice; 7.1's walked N90 oracle uses 5 / PB5.
            // The iPhone 5 only: the iPhone 4's 7.0 rows keep what they were qualified with.
            if a6, productVersion == "7.0" || productVersion?.hasPrefix("7.0.") == true {
                buddy.removeValue(forKey: "AppleIDPB5Presented")
                buddy["AppleIDPB4Presented"] = true
                buddy["AssistantPresented"] = true
                buddy["SetupVersion"] = 4
            }
            if major == 8 {
                // Native 12A365 PSSetupAssistantNeedsToRun requires version >6,
                // AssistantPresented, and neither upgrade mini-buddy flag.
                // Its Setup executable names PB6 and LocationServices4.
                buddy.removeValue(forKey: "AppleIDPB5Presented")
                buddy["AppleIDPB6Presented"] = true
                buddy["AssistantPresented"] = true
                buddy["SetupVersion"] = 7
            }
            if major == 9 {
                // Qualified against native 13A344's setup predicate and the
                // completed-setup Data records; no Setup executable edits.
                buddy.removeValue(forKey: "AppleIDPB5Presented")
                buddy["AppleIDPB9Presented"] = true
                buddy["AssistantPresented"] = true
                buddy["Passcode4Presented"] = true
                buddy["PBDiagnostics2Presented"] = true
                buddy["SetupVersion"] = 9
            }
            if major == 10 {
                // 14G61's native BYBuddyIOSCurrentVersion is 10; its qualified
                // completed-setup records retain the shared cloud/Siri choices.
                buddy.removeValue(forKey: "AppleIDPB5Presented")
                buddy["AppleIDPB6Presented"] = true
                buddy["AssistantPresented"] = true
                buddy["SetupVersion"] = 10
            }
            buddyLocal = [
                major == 9
                    ? "LocationServices5Presented"
                    : major == 8 || major == 10 ? "LocationServices4Presented" : "LocationServices2Presented": true,
                "CloudConfigPresented": true
            ]
            if (8...10).contains(major) {
                buddyLocal["ShouldRunKeychainSyncMiniBuddy"] = false
                buddyLocal["ShouldRunMesaMiniBuddy"] = false
            }
            if major == 9 {
                buddyLocal["ShouldRunDiagnosticsMiniBuddy"] = false
                buddyLocal["ShouldRunPaymentMiniBuddy"] = false
            }
            off = [
                (8...10).contains(major) ? "LocationServicesEnabledIn8.0" : "LocationServicesEnabledIn7.0":
                    locationServicesEnabled ? 1 : 0
            ]
            ark = [
                "-ActivationStateAcknowledged": true, "com.apple.mobile.chaperone-NotSoFresh": true,
                "-FirstPurpleBuddyCompletion": Int(now.timeIntervalSince1970)
            ]
            // Setup's cloud configuration step, through ManagedConfiguration: without the record, 7.x's
            // PSSetupAssistantNeedsToRun brings Setup back for it (Wi-Fi, then Welcome) on every boot.
            extra = [
                (
                    major == 10
                        ? "containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles/CloudConfigurationDetails.plist"
                        : "mobile/Library/ConfigurationProfiles/CloudConfigurationDetails.plist",
                    [
                        "AllowPairing": true, "CloudConfigurationUIComplete": true, "IsSupervised": false,
                        "PostSetupProfileWasInstalled": false
                    ]
                ),
                (
                    "mobile/Library/Preferences/com.apple.mobile.user_preferences.plist",
                    ["UserSetLanguage": true, "UserSetLocale": true]
                )
            ]
        }
        return [
            (purpleBuddy, buddy), (purpleBuddyLocal, buddyLocal), (locationd, off), (locationdLocal, off),
            (dataArk, ark)
        ] + extra
    }

    /// The device's language: the first of `preferred` (BCP 47 tags) that `supported`, the firmware's own
    /// AppleLanguages, has, matched as a bundle picks its localization ("zh-Hans-CN" to "zh-Hans", "pt-BR" to "pt",
    /// "en-AU" to "en-GB" where the firmware has it), else English. Its AppleLocale: `locale` ("uk_UA") where
    /// `formats`, the firmware's region formats (regionFormats), has it, whatever the language, as Region Format sets
    /// it; else the language's code with `region` ("fr_FR").
    static func deviceLanguage(
        supported: [String],
        preferred: [String],
        region: String?,
        locale: String? = nil,
        formats: Set<String>? = nil
    ) -> (language: String, locale: String) {
        let language = Bundle.preferredLocalizations(from: supported, forPreferences: preferred).first ?? "en"
        if let locale, formats?.contains(locale) == true { return (language, locale) }
        let code = Locale(identifier: language).language.languageCode?.identifier ?? "en"
        return (language, region.map { "\(code)_\($0)" } ?? code)
    }

    /// The region formats a firmware offers (Settings ▸ International ▸ Region Format, CFLocale's available
    /// locales): the locales in the system volume's ICU data, the table of contents of /usr/share/icu/icudt*l.dat
    /// ("uk_UA" for icudt42l/uk_UA.res); nil where it has none.
    static func regionFormats(_ v: any VolumeFiles) -> Set<String>? {
        guard
            let name = try? v.contentsOfDirectory(at: "usr/share/icu").sorted()
                .first(where: { $0.hasPrefix("icudt") && $0.hasSuffix("l.dat") }),
            let data = try? v.contents(at: "usr/share/icu/" + name)
        else { return nil }
        // ICU's common data: a header (its size, magic DA 27, format "CmnD"), then the entry count and each entry's
        // name and data offsets, both from the header's end; a name is a NUL-terminated string.
        return try? parsing(data, "ICU data") { s -> Set<String>? in
            guard s.count > 24, try s.bytes(at: 2, 2) == [0xDA, 0x27], try s.bytes(at: 12, 4).elementsEqual("CmnD".utf8)
            else { return nil }
            let toc = try s.seeking(toAbsoluteOffset: Int(try UInt16(parsingLittleEndian: &s)))
            var entries = try toc.seeking(toRelativeOffset: 0)
            let count = try UInt32(parsingLittleEndian: &entries)
            var out = Set<String>()
            for _ in 0..<count {
                var entry = try entries.sliceSpan(byteCount: 8)
                var name = try toc.seeking(toRelativeOffset: try UInt32(parsingLittleEndian: &entry))
                guard let end = name.withUnsafeBytes({ $0.firstIndex(of: 0) }) else { return nil }
                // a locale is a top-level .res ("icudt42l/uk_UA.res"); coll/ and the like are not region formats
                let path = String(decoding: try [UInt8](parsing: &name, byteCount: end), as: UTF8.self)
                    .split(separator: "/")
                if path.count == 2, path[1].hasSuffix(".res") { out.insert(String(path[1].dropLast(4))) }
            }
            return out
        }
    }

    /// The locale to seed as AppleLocale, as ICU names it ("uk_UA", "sr_Latn_RS"), without keywords ("@calendar=…"):
    /// `tag`'s, else `appleLocale`, the user's own AppleLocale preference. Not Locale.current, which in an app
    /// localized only in English carries the app's language with the user's region (en_UA for a uk_UA user).
    static func deviceLocale(
        tag: String?,
        appleLocale: String? = CFPreferencesCopyAppValue("AppleLocale" as CFString, kCFPreferencesAnyApplication)
            as? String
    ) -> String {
        String(Locale.identifier(.icu, from: tag ?? appleLocale ?? Locale.current.identifier).prefix { $0 != "@" })
    }

    /// Sets the device's language and region (`deviceLanguage`, from `tag`, else the Mac's) in each user's
    /// .GlobalPreferences under `top` (/private/var, or "" for the skeleton of it) on `v` that lists the firmware's languages: the language moved
    /// first, AppleLocale set; with `catalog`, the firmware's keyboards, AppleKeyboards (KeyboardCatalog.keyboards)
    /// for the language and `keyboards`, Mac input source IDs, else the Mac's enabled ones; with `formats`, the
    /// firmware's region formats (regionFormats), AppleLocale is `tag`'s or the Mac's own locale where it has it.
    /// Nil where the firmware has no such list.
    @discardableResult
    static func seedLanguage(
        _ v: any VolumeFiles,
        _ top: String,
        tag: String?,
        keyboards: [String]? = nil,
        catalog: KeyboardCatalog? = nil,
        formats: Set<String>? = nil
    ) throws -> (language: String, locale: String, keyboards: [String])? {
        let preferred = tag.map { [$0] } ?? Locale.preferredLanguages
        let region = tag.flatMap { Locale(identifier: $0).region?.identifier } ?? Locale.current.region?.identifier
        let locale = deviceLocale(tag: tag)
        let mac = catalog == nil ? [] : macKeyboards(keyboards)
        var chosen: (language: String, locale: String, keyboards: [String])?
        for path in [globalPreferences, "root/Library/Preferences/.GlobalPreferences.plist"] {
            let rel = top.isEmpty ? path : top + "/" + path
            guard v.exists(rel) else { continue }
            try rewritePlist(v, rel) { d in
                guard var list = d["AppleLanguages"] as? [String] else { return }
                let pick = deviceLanguage(
                    supported: list,
                    preferred: preferred,
                    region: region,
                    locale: locale,
                    formats: formats
                )
                list.removeAll { $0 == pick.language }
                d["AppleLanguages"] = [pick.language] + list
                d["AppleLocale"] = pick.locale
                let kb = catalog?.keyboards(language: pick.language, locale: pick.locale, mac: mac) ?? []
                if !kb.isEmpty { d["AppleKeyboards"] = kb }
                chosen = chosen ?? (pick.language, pick.locale, kb)
            }
        }
        return chosen
    }

    /// Seeds `finishedSetup` into `top` (/private/var, or "" for the skeleton of it) on `v`, merged into the plists
    /// already there, as Setup's walk in `language` and `locale` (seedLanguage's) leaves it.
    static func seedFinishedSetup(
        _ v: any VolumeFiles, _ top: String, major: Int, language: String, locale: String,
        productVersion: String? = nil, locationServicesEnabled: Bool = false, a6: Bool = false
    )
        throws
    {
        for (path, keys) in finishedSetup(
            major: major, language: language, locale: locale, productVersion: productVersion,
            locationServicesEnabled: locationServicesEnabled, a6: a6)
        {
            try seedPlist(v, top.isEmpty ? path : top + "/" + path) { $0.addEntries(from: keys) }
        }
    }
}
