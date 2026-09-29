// The helper's web proxy on its own, for tests/offline/check-web-proxy*.py. Built from
// LightTouchDevice/WebProxy*.swift and Shared/WebProxyCA.swift:
//
//   web-proxy init-ca CONFIG                          WebProxyCA.prepare (what WebProxySetup does)
//   web-proxy serve CONFIG SOCKET [ARCHIVE] [ROOT.der] WebProxy.listen, as the helper does; ARCHIVE replaces
//                                                     https://web.archive.org, ROOT is an extra upstream root
//   web-proxy adapters                                the adapters' own checks (no network)

import Foundation

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "init-ca":
    do { _ = try WebProxyCA.prepare(config: URL(fileURLWithPath: args[2])) } catch { print("init-ca: \(error)"); exit(1) }
case "serve":
    let anchors = args.count > 5 ? [SecCertificateCreateWithData(nil, try! Data(contentsOf: URL(fileURLWithPath: args[5])) as CFData)!] : []
    let proxy = WebProxy(config: URL(fileURLWithPath: args[2]), archiveOrigin: args.count > 4 ? args[4] : "https://web.archive.org", anchors: anchors)
    try! proxy.listen(socket: args[3])
    print("listening"); fflush(stdout)
    while true { sleep(3600) }
case "adapters":
    adapters()
    print("PASS: adapters")
default:
    print("usage: web-proxy init-ca CONFIG | serve CONFIG SOCKET [ARCHIVE] [ROOT.der] | adapters"); exit(64)
}

func adapters() {
    typealias A = WebProxyAdapters
    // Retired hosts: the exact authority only, case and a trailing dot normalized.
    precondition(A.retired(host: "API.OpenFeint.com.") && A.retired(host: "gdata.youtube.com"))
    precondition(!A.retired(host: "openfeint.com") && !A.retired(host: "api.openfeint.com.example.org") && !A.retired(host: "::1"))

    // Archive text links; binary is never passed in.
    precondition(A.httpLinks(Data("<a href=\"HTTPS://x/\">https://y</a>".utf8)) == Data("<a href=\"http://x/\">http://y</a>".utf8))
    precondition(A.textual("text/html; charset=utf-8") && A.textual("application/javascript") && !A.textual("image/png") && !A.textual(nil))

    // Set-Cookie: HTTPURLResponse joins repeats with commas; each comes back on its own line, dates intact.
    let url = URL(string: "https://www.example.com/a/b")!
    let joined = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
        "Set-Cookie": "a=1; expires=Wed, 09-Jun-2027 10:18:14 GMT; path=/; domain=.example.com, b=2; HttpOnly, c=3; secure"])!
    let lines = A.setCookieLines(joined)
    precondition(lines.count == 3, "\(lines)")
    precondition(lines[0] == "a=1; expires=Wed, 09-Jun-2027 10:18:14 GMT; path=/; domain=.example.com", lines[0])
    precondition(lines[1].hasPrefix("b=2; path=/a") && lines[1].hasSuffix("; HttpOnly") && lines[2].hasSuffix("; secure"), "\(lines)")
    let reparsed = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": lines.joined(separator: ", ")], for: url)
    precondition(reparsed.map(\.name) == ["a", "b", "c"] && reparsed[0].expiresDate != nil)

    // Wi-Fi location: the request 3.2's locationd sent on a real boot (7B500), placed at the host-set position.
    let body = Data(hexString: "00010005656e5f55530000000b332e322e322e3742353030000000010000001f0a080800100018002000120f0a0d323a303a35653a31303a303a3118002000")
    precondition(A.location(target: "/clls/wloc", method: "GET", body: body, position: (0, 0, 1)) == nil)
    precondition(A.location(target: "http://x/other", method: "POST", body: body, position: (0, 0, 1)) == nil)
    precondition(A.location(target: "/clls/wloc", method: "POST", body: Data([0, 2]), position: (0, 0, 1))?.status == 400)
    let answer = A.location(target: "http://iphone-services.apple.com/clls/wloc", method: "POST", body: body, position: (51.50073, -0.12463, 20))!
    precondition(answer.status == 200 && answer.body.prefix(2) == Data([0, 1]))
    var reader = A.Protobuf(bytes: [UInt8](answer.body)[2...])
    precondition(reader.be(4) == 1 && Int(reader.be(4)!) == answer.body.count - 10)
    guard let (field, ap) = reader.field(), field == 2, var entry = ap.map({ A.Protobuf(bytes: $0) }),
          let (macField, mac) = entry.field(), macField == 1, let (whereField, place) = entry.field(), whereField == 2, var position = place.map({ A.Protobuf(bytes: $0) })
    else { fatalError("location answer shape") }
    precondition(String(decoding: mac!, as: UTF8.self) == "2:0:5e:10:0:1")
    precondition(position.field().map { $0.0 } == 1)   // latitude, then longitude and accuracy
    var values = A.Protobuf(bytes: place!)
    var decoded: [Int64] = []
    while !values.bytes.isEmpty { _ = values.varint(); decoded.append(Int64(bitPattern: values.varint()!)) }
    precondition(decoded == [5_150_073_000, -12_463_000, 20], "\(decoded)")
    let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ltm-location-\(getpid())")
    precondition(A.position(file) == (37.33490, -122.00898, 30))
    try! "51.5 -0.1\n".write(to: file, atomically: true, encoding: .utf8)
    precondition(A.position(file) == (51.5, -0.1, 30))
    try! "91 0 5".write(to: file, atomically: true, encoding: .utf8)
    precondition(A.position(file) == (37.33490, -122.00898, 30))
    try? FileManager.default.removeItem(at: file)

    // Weather: city identity, XML escaping, the six-day forecast, invalid data and request boundaries.
    let city = A.Place(latitude: 37.3, longitude: -122.0, name: "A&B <City> ☀")
    precondition(A.decode(A.identifier(city)) == city)
    // An id the ObjC adapter minted (NSJSONSerialization, sorted keys) still decodes.
    precondition(A.decode("ltm:" + Data(#"{"latitude":35.6895,"longitude":139.69171,"name":"Tokyo"}"#.utf8).base64EncodedString())
                 == A.Place(latitude: 35.6895, longitude: 139.69171, name: "Tokyo"))
    precondition(A.decode("USCA0273|12797509") != nil && A.decode("USXX0000") == nil && A.decode("ltm:bad") == nil)
    precondition(A.string("bad\nname", 200) == nil)
    precondition(A.place(["latitude": true, "longitude": 0, "name": "bad"]) == nil && A.place(["latitude": 91, "longitude": 0, "name": "bad"]) == nil)
    var daily: [String: Any] = ["time": ["2026-09-06", "2026-09-07", "2026-09-08", "2026-09-09", "2026-09-10", "2026-09-11"],
                                "weather_code": [0, 1, 2, 3, 61, 95], "temperature_2m_max": [80, 81, 82, 83, 84, 85],
                                "temperature_2m_min": [60, 61, 62, 63, 64, 65],
                                "sunrise": ["2026-09-06T06:00", "", "", "", "", ""], "sunset": ["2026-09-06T20:00", "", "", "", "", ""]]
    var current: [String: Any] = ["time": "2026-09-06T14:30", "temperature_2m": 73.2, "weather_code": 0, "is_day": 1]
    func data() -> [String: Any] { ["current": current, "daily": daily, "utc_offset_seconds": 0] }
    precondition(A.moon(947182500.0)["moonphase"] == "0" && A.moon(947182500.0 + 29.53059 * 86400 / 2)["moonphase"] == "4")
    let item = A.forecast(data(), id: A.identifier(city), place: city, celsius: false)!
    precondition(item.elements(forName: "forecast").count == 6)
    precondition(item.elements(forName: "forecast")[0].attribute(forName: "dayofweek")?.stringValue == "1")
    precondition(A.forecast(data(), id: "id", place: city, celsius: true)!.elements(forName: "units")[0].attribute(forName: "temperature")?.stringValue == "C")
    let roundtrip = try! XMLDocument(xmlString: item.xmlString, options: .nodeLoadExternalEntitiesNever)
    precondition(roundtrip.rootElement()!.elements(forName: "location")[0].attribute(forName: "city")?.stringValue == city.name)
    current["temperature_2m"] = NSNull(); precondition(A.forecast(data(), id: "id", place: city, celsius: false) == nil)
    current["temperature_2m"] = 73
    daily["weather_code"] = [0]; precondition(A.forecast(data(), id: "id", place: city, celsius: false) == nil)
    precondition(A.clockTime("2026-02-30T12:00") == nil && A.icon(100, daylight: true) == nil && A.icon(0, daylight: false) == "31")
    let gateway = "http://iphone-wu.apple.com/dgw?apptype=weather"
    let offline: (String, String, [String: String]) -> Any? = { _, _, _ in fatalError("no fetch expected") }
    precondition(A.weather(target: "http://example.com/dgw?apptype=weather", method: "POST", body: Data(), fetch: offline) == nil)
    precondition(A.weather(target: gateway, method: "GET", body: Data(), fetch: offline)?.status == 400)
    for (index, bad) in ["<!DOCTYPE request [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><request>&x;</request>",
                         "<request><query type='other'/></request>", "<request><query/><query/></request>",
                         "<request><query type='getforecastbylocationid'><list><id>UNKNOWN</id></list><unit>f</unit></query></request>"].enumerated() {
        let result = A.weather(target: gateway, method: "POST", body: Data(bad.utf8), fetch: offline)!
        precondition(result.status == (index == 3 ? 422 : 400) && result.body.isEmpty, "\(index): \(result)")
    }
    let empty = A.weather(target: gateway, method: "POST", body: Data("<request><query type='getlocationid'><phrase>Q</phrase></query></request>".utf8), fetch: offline)!
    precondition(empty.status == 200 && (try? XMLDocument(data: empty.body))?.rootElement()?.name == "response")
    // A search and a forecast through the fetch, as Open-Meteo answers.
    let search = A.weather(target: gateway, method: "POST", body: Data("<request><query type='getlocationid'><phrase>Tokyo</phrase></query></request>".utf8)) { host, path, query in
        precondition(host == "geocoding-api.open-meteo.com" && path == "/v1/search" && query["name"] == "Tokyo")
        return ["results": [["latitude": 35.6895, "longitude": 139.69171, "name": "Tokyo", "admin1": "Tokyo", "country_code": "JP", "country": "Japan"]]]
    }!
    let found = try! XMLDocument(data: search.body)
    let id = (try! found.nodes(forXPath: "//item/id"))[0].stringValue!
    precondition(search.status == 200 && A.decode(id)?.name == "Tokyo")
    daily["weather_code"] = [0, 1, 2, 3, 61, 95]
    let request = "<request><query type='getforecastbylocationid'><list><id>\(id)</id><id>USNY0996|2459115</id></list><unit>c</unit></query></request>"
    let forecast = A.weather(target: gateway, method: "POST", body: Data(request.utf8)) { host, path, query in
        precondition(host == "api.open-meteo.com" && path == "/v1/forecast" && query["latitude"] == "35.6895,40.7143" && query["temperature_unit"] == "celsius")
        return [data(), data()]
    }!
    precondition(forecast.status == 200 && (try! XMLDocument(data: forecast.body).nodes(forXPath: "//item")).count == 2)
    precondition(A.weather(target: gateway, method: "POST", body: Data(request.utf8)) { _, _, _ in nil }?.status == 502)
}

extension Data {
    init(hexString: String) {
        var bytes: [UInt8] = [], text = Substring(hexString)
        while !text.isEmpty { bytes.append(UInt8(text.prefix(2), radix: 16)!); text = text.dropFirst(2) }
        self.init(bytes)
    }
}
