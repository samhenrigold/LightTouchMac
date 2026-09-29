// The web proxy's answers for services that no longer speak to a 2009-2010
// guest (WebProxy.swift dispatches to them): the stock Weather gateway on
// Open-Meteo, the Wi-Fi location server, the retired API hosts; plus the two
// rewrites between URLSession's view of a response and the guest's.

import Foundation

enum WebProxyAdapters {
    // MARK: Retired services

    /// Exact retired API hosts only (never a vendor's whole domain); a DNS trailing dot and case are normalized.
    /// OpenFeint (shut down 2012) and the YouTube Data API v2 (retired 2015): HTTP 410 without contacting them.
    static func retired(host: String) -> Bool {
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        return ["api.openfeint.com", "gdata.youtube.com"].contains(name)
    }

    // MARK: Response rewrites

    /// Set-Cookie lines for the guest. HTTPURLResponse joins repeated headers with commas, which
    /// Set-Cookie's own Expires dates contain; Foundation's cookie parser splits them again.
    static func setCookieLines(_ response: HTTPURLResponse) -> [String] {
        guard let url = response.url, let joined = response.value(forHTTPHeaderField: "Set-Cookie") else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd-MMM-yyyy HH:mm:ss 'GMT'"
        return HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": joined], for: url).map { cookie in
            var line = "\(cookie.name)=\(cookie.value)"
            if let expires = cookie.expiresDate { line += "; expires=" + formatter.string(from: expires) }
            line += "; path=\(cookie.path)"
            if cookie.domain.hasPrefix(".") { line += "; domain=\(cookie.domain)" }
            if cookie.isSecure { line += "; secure" }
            if cookie.isHTTPOnly { line += "; HttpOnly" }
            return line
        }
    }

    /// Dated browsing is a read-only HTTP presentation: absolute https:// links in a text resource become
    /// http:// so old WebKit never opens a tunnel it can't finish. Binary resources are never passed here.
    static func httpLinks(_ body: Data) -> Data {
        let bytes = [UInt8](body), pattern = Array("https://".utf8)
        var out = [UInt8](), i = 0
        out.reserveCapacity(bytes.count)
        while i < bytes.count {
            if i + 8 <= bytes.count, zip(bytes[i..<i + 8], pattern).allSatisfy({ $0 | 0x20 == $1 | 0x20 }) {
                out += Array("http://".utf8); i += 8
            } else { out.append(bytes[i]); i += 1 }
        }
        return Data(out)
    }

    static func textual(_ contentType: String?) -> Bool {
        let type = (contentType ?? "").lowercased()
        return ["text/html", "text/css", "text/javascript", "application/javascript", "application/xhtml+xml"].contains { type.hasPrefix($0) }
    }

    // MARK: Wi-Fi location (docs/ipad1/location.md in qemu-ios)

    /// iOS 3.2's locationd POSTs the BSSIDs it sees to AppleLocationServer (baked to
    /// http://10.0.2.100:3128/clls/wloc) and gets a position per BSSID back; every BSSID is placed at
    /// `position`. Wire format (PBRequester, ProtocolBuffer.framework 3.2, captured from 7B500), big-endian:
    /// request u16 version=1, three u16-length strings (locale, app id, OS build), u32 type=1, u32 length,
    /// ALSLocationRequest { 2: ALSWirelessAP { 1: macID } }; response u16 1, u32 type, u32 length,
    /// ALSLocationResponse { 2: ALSWirelessAP { 1: macID, 2: ALSLocation { 1: lat, 2: lon, 3: accuracy } } },
    /// degrees as int64 x 1e8, accuracy in metres. nil: not a location request; 400: malformed.
    static func location(target: String, method: String, body: Data, position: (Double, Double, Double)) -> (status: Int, body: Data)? {
        var path = Substring(target)
        if let scheme = target.range(of: "://") {
            guard let slash = target[scheme.upperBound...].firstIndex(of: "/") else { return nil }
            path = target[slash...]
        }
        guard path == "/clls/wloc", method == "POST" else { return nil }
        var c = Protobuf(bytes: [UInt8](body)[...])
        guard c.be(2) == 1 else { return (400, Data()) }
        for _ in 0..<3 { guard let n = c.be(2), c.skip(Int(n)) else { return (400, Data()) } }
        guard let type = c.be(4), let size = c.be(4), let request = c.take(Int(size)) else { return (400, Data()) }
        var message = Protobuf.Writer(), fields = Protobuf(bytes: request), macs: [ArraySlice<UInt8>] = []
        while !fields.bytes.isEmpty {
            guard let (number, ap) = fields.field() else { return (400, Data()) }
            guard number == 2, var ap = ap.map({ Protobuf(bytes: $0) }) else { continue }
            while !ap.bytes.isEmpty {
                guard let (inner, mac) = ap.field() else { return (400, Data()) }
                if inner == 1, let mac, macs.count < 64 { macs.append(mac) }
            }
        }
        for mac in macs {
            var place = Protobuf.Writer(), entry = Protobuf.Writer()
            place.int(1, Int64((position.0 * 1e8).rounded())); place.int(2, Int64((position.1 * 1e8).rounded()))
            place.int(3, Int64(position.2.rounded()))
            entry.bytes(1, mac); entry.bytes(2, place.out[...])
            message.bytes(2, entry.out[...])
        }
        let head: [UInt8] = [0, 1] + [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: type >> $0) }
            + [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: message.out.count >> $0) }
        return (200, Data(head + message.out))
    }

    /// CONFIG.location, "LAT LON [ACCURACY]", replaceable while the guest runs; else Apple Park, 30 m.
    static func position(_ file: URL) -> (Double, Double, Double) {
        let values = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(whereSeparator: \.isWhitespace).prefix(3).map { Double($0) }
        guard values.count >= 2, let lat = values[0], let lon = values[1], lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180
        else { return (37.33490, -122.00898, 30) }
        let accuracy = values.count == 3 ? values[2].flatMap { $0.isFinite && $0 > 0 && $0 < 100_000 ? $0 : nil } : nil
        return (lat, lon, accuracy ?? 30)
    }

    struct Protobuf {
        var bytes: ArraySlice<UInt8>
        mutating func be(_ count: Int) -> UInt32? { take(count)?.reduce(0) { $0 << 8 | UInt32($1) } }
        mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
            guard count <= bytes.count else { return nil }
            defer { bytes = bytes.dropFirst(count) }
            return bytes.prefix(count)
        }
        mutating func skip(_ count: Int) -> Bool { take(count) != nil }
        mutating func varint() -> UInt64? {
            var value: UInt64 = 0
            for shift in stride(from: 0, to: 64, by: 7) {
                guard let byte = bytes.popFirst() else { return nil }
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
            }
            return nil
        }
        /// The next field: its number, and its bytes when it is length-delimited.
        mutating func field() -> (UInt64, ArraySlice<UInt8>?)? {
            guard let key = varint() else { return nil }
            switch key & 7 {
            case 0: return varint().map { _ in (key >> 3, nil) }
            case 1: return take(8).map { _ in (key >> 3, nil) }
            case 5: return take(4).map { _ in (key >> 3, nil) }
            case 2: guard let n = varint(), n <= UInt64(bytes.count), let value = take(Int(n)) else { return nil }
                return (key >> 3, value)
            default: return nil
            }
        }
        struct Writer {
            var out: [UInt8] = []
            mutating func varint(_ value: UInt64) {
                var v = value
                repeat { out.append(UInt8(v & 0x7f) | (v > 0x7f ? 0x80 : 0)); v >>= 7 } while v > 0
            }
            mutating func int(_ number: UInt64, _ value: Int64) { varint(number << 3); varint(UInt64(bitPattern: value)) }
            mutating func bytes(_ number: UInt64, _ value: ArraySlice<UInt8>) { varint(number << 3 | 2); varint(UInt64(value.count)); out += value }
        }
    }

    // MARK: Weather (the stock 7E18 gateway on Open-Meteo)

    /// iphone-wu.apple.com/dgw?apptype=weather, answered from Open-Meteo's geocoding and forecast APIs
    /// (CC BY 4.0; noncommercial free tier). City searches return opaque "ltm:" ids; the two default Yahoo ids
    /// (Cupertino, New York) work too; other old ids get 422 rather than guessed coordinates. Bad provider data
    /// fails the update (the guest keeps its forecast); nothing is made up. nil: another service.
    /// `fetch(host, path, query)` is an HTTPS GET returning parsed JSON, or nil.
    static func weather(target: String, method: String, body: Data,
                        fetch: (String, String, [String: String]) -> Any?) -> (status: Int, body: Data)? {
        guard let url = URLComponents(string: target), url.host?.lowercased() == "iphone-wu.apple.com", url.path == "/dgw" else { return nil }
        let services = (url.queryItems ?? []).filter { $0.name == "apptype" }
        guard services.count <= 1 else { return (400, Data()) }
        guard services.first?.value == "weather" else { return nil }
        guard method == "POST", url.user == nil, url.password == nil, !body.isEmpty, body.count <= 65536, !body.contains(0),
              let xml = String(data: body, encoding: .utf8),
              xml.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil, xml.range(of: "<!ENTITY", options: .caseInsensitive) == nil,
              let request = try? XMLDocument(xmlString: xml, options: .nodeLoadExternalEntitiesNever), request.dtd == nil,
              let root = request.rootElement(), root.name == "request", root.elements(forName: "query").count == 1
        else { return (400, Data()) }
        let query = root.elements(forName: "query")[0]
        let response = XMLElement(name: "response")
        let list = child(child(response, "result"), "list")
        switch query.attribute(forName: "type")?.stringValue {
        case "getlocationid":
            let phrases = query.elements(forName: "phrase")
            guard phrases.count == 1, let phrase = string(phrases[0].stringValue, 200) else { return (400, Data()) }
            if phrase.count >= 2 {
                guard let result = fetch("geocoding-api.open-meteo.com", "/v1/search",
                                         ["name": phrase, "count": "10", "language": "en", "format": "json"]) as? [String: Any],
                      let places = (result["results"] ?? []) as? [Any], places.count <= 10 else { return (502, Data()) }
                for entry in places {
                    guard let place = place(entry), let entry = entry as? [String: Any] else { return (502, Data()) }
                    let item = child(list, "item")
                    child(item, "id", identifier(place)); child(item, "city", place.name)
                    child(item, "region", string(entry["admin1"], 200) ?? ""); child(item, "regionname", string(entry["admin1"], 200) ?? "")
                    child(item, "country", string(entry["country_code"], 8) ?? ""); child(item, "countryname", string(entry["country"], 200) ?? "")
                }
            }
        case "getforecastbylocationid":
            let identifiers = ((try? query.nodes(forXPath: "./list/id")) ?? []).map { $0.stringValue ?? "" }
            let units = query.elements(forName: "unit")
            guard (1...20).contains(identifiers.count), units.count == 1, let unit = units[0].stringValue, unit == "c" || unit == "f"
            else { return (400, Data()) }
            var places: [Place] = []
            for id in identifiers {
                guard let place = decode(id) else { return (422, Data()) }   // an unknown retired Yahoo id: never guess
                places.append(place)
            }
            let result = fetch("api.open-meteo.com", "/v1/forecast", [
                "latitude": places.map { String($0.latitude) }.joined(separator: ","),
                "longitude": places.map { String($0.longitude) }.joined(separator: ","),
                "current": "temperature_2m,weather_code,is_day", "daily": "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset",
                "temperature_unit": unit == "c" ? "celsius" : "fahrenheit", "timezone": "auto", "forecast_days": "6"])
            guard let forecasts = result is [String: Any] ? [result!] : result as? [Any], forecasts.count == places.count else { return (502, Data()) }
            for (index, place) in places.enumerated() {
                guard let item = forecast(forecasts[index], id: identifiers[index], place: place, celsius: unit == "c") else { return (502, Data()) }
                list.addChild(item)
            }
        default: return (400, Data())
        }
        return (200, XMLDocument(rootElement: response).xmlData)
    }

    struct Place: Equatable { var latitude, longitude: Double; var name: String }

    static func number(_ value: Any?, _ low: Double, _ high: Double) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue >= low, n.doubleValue <= high
        else { return nil }
        return n.doubleValue
    }
    static func string(_ value: Any?, _ maximum: Int) -> String? {
        guard let s = value as? String, s.utf16.count <= maximum, s.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return s
    }
    static func place(_ value: Any?) -> Place? {
        guard let d = value as? [String: Any], let lat = number(d["latitude"], -90, 90), let lon = number(d["longitude"], -180, 180),
              let name = string(d["name"], 200), !name.isEmpty else { return nil }
        return Place(latitude: lat, longitude: lon, name: name)
    }
    static func identifier(_ place: Place) -> String {
        let json = try! JSONSerialization.data(withJSONObject: ["latitude": place.latitude, "longitude": place.longitude, "name": place.name],
                                               options: .sortedKeys)
        return "ltm:" + json.base64EncodedString()
    }
    static func decode(_ id: String) -> Place? {
        if id == "USCA0273|12797509" { return Place(latitude: 37.323, longitude: -122.032, name: "Cupertino") }
        if id == "USNY0996|2459115" { return Place(latitude: 40.7143, longitude: -74.006, name: "New York") }
        guard id.utf16.count <= 2048, id.hasPrefix("ltm:"), let data = Data(base64Encoded: String(id.dropFirst(4))) else { return nil }
        return place(try? JSONSerialization.jsonObject(with: data))
    }
    static func icon(_ code: Any?, daylight: Bool) -> String? {
        guard let value = number(code, 0, 99), value == value.rounded() else { return nil }
        switch Int(value) {
        case 0: return daylight ? "32" : "31"
        case 1: return daylight ? "34" : "33"
        case 2: return daylight ? "30" : "29"
        case 3: return "26"
        case 45, 48: return "20"
        case 51, 53, 55: return "9"
        case 56, 57: return "8"
        case 61, 63, 65: return "12"
        case 66, 67: return "10"
        case 71, 73, 75, 77: return "16"
        case 80, 81, 82: return "11"
        case 85, 86: return "14"
        case 95: return "4"
        case 96, 99: return "3"
        default: return nil
        }
    }
    /// Strict: the text must format back to itself (no lenient Feb 30).
    static func date(_ text: Any?, _ format: String) -> Date? {
        guard let text = string(text, 32) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        formatter.isLenient = false
        guard let value = formatter.date(from: text), formatter.string(from: value) == text else { return nil }
        return value
    }
    static func clockTime(_ value: Any?) -> String? {
        date(value, "yyyy-MM-dd'T'HH:mm") != nil ? String((value as! String).dropFirst(11)) : nil
    }
    /// ponytail: the mean lunar cycle for the stock icon; an ephemeris if exact phase timing matters.
    /// NASA's 2000-01-06 18:15 UTC new moon; USNO mean synodic month 29.53059 days.
    static func moon(_ timestamp: TimeInterval) -> [String: String] {
        var cycle = (timestamp - 947182500.0) / (29.53059 * 86400.0)
        cycle -= cycle.rounded(.down)
        return ["moonphase": String(Int((cycle * 8 + 0.5).rounded(.down)) % 8),
                "moonfacevisible": String(format: "%.3f", 50 * (1 - cos(2 * Double.pi * cycle)))]
    }
    static func forecast(_ data: Any, id: String, place: Place, celsius: Bool) -> XMLElement? {
        guard let data = data as? [String: Any], let offset = number(data["utc_offset_seconds"], -50400, 50400),
              let current = data["current"] as? [String: Any], let daily = data["daily"] as? [String: Any],
              let temperature = number(current["temperature_2m"], -200, 200), let isDay = number(current["is_day"], 0, 1), isDay == isDay.rounded(),
              let time = clockTime(current["time"]), let now = date(current["time"], "yyyy-MM-dd'T'HH:mm"),
              let icon = icon(current["weather_code"], daylight: isDay == 1) else { return nil }
        var columns: [String: [Any]] = [:]
        for key in ["time", "temperature_2m_max", "temperature_2m_min", "weather_code", "sunrise", "sunset"] {
            guard let column = daily[key] as? [Any], column.count == 6 else { return nil }
            columns[key] = column
        }
        guard let sunrise = clockTime(columns["sunrise"]![0]), let sunset = clockTime(columns["sunset"]![0]) else { return nil }
        let item = XMLElement(name: "item")
        attributes(child(item, "location"), ["id": id, "city": place.name])
        attributes(child(item, "units"), ["temperature": celsius ? "C" : "F"])
        let astronomy = child(item, "astronomy")
        attributes(astronomy, ["sunrise": sunrise, "sunset": sunset].merging(moon(now.timeIntervalSince1970 - offset)) { $1 })
        attributes(child(item, "condition"), ["time": time, "temp": String(format: "%.0f", temperature), "code": icon])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for day in 0..<6 {
            guard let when = date(columns["time"]![day], "yyyy-MM-dd"), let condition = self.icon(columns["weather_code"]![day], daylight: true),
                  let high = number(columns["temperature_2m_max"]![day], -200, 200), let low = number(columns["temperature_2m_min"]![day], -200, 200),
                  high >= low else { return nil }
            attributes(child(item, "forecast"), ["high": String(format: "%.0f", high), "low": String(format: "%.0f", low), "code": condition,
                                                 "dayofweek": String(calendar.component(.weekday, from: when))])
        }
        child(item, "link", "http://open-meteo.com/")
        return item
    }
    @discardableResult
    private static func child(_ parent: XMLElement, _ name: String, _ text: String = "") -> XMLElement {
        let node = XMLElement(name: name, stringValue: text)
        parent.addChild(node)
        return node
    }
    private static func attributes(_ node: XMLElement, _ values: [String: String]) {
        for (key, value) in values.sorted(by: { $0.key < $1.key }) { node.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode) }
    }
}
