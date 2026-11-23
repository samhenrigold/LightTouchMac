import Foundation
import SessionKit

/// `single --replug`'s verdict (session-driver's firstgen-usb.swift): lockdown gone with the cable, back with it, and
/// an AFC round trip over the new link.
func judgeReplug(_ r: Report, _ events: Events, device d: String) {
    let e = events.one("replug", ["device": d])
    r.check(
        e.has("gone") && e.has("back") && e.bool("same"),
        "\(d): the cable pulled, lockdown gone in \(format(e.double("gone"))) s; plugged, back in "
            + "\(format(e.double("back"))) s with an AFC round trip\(e.string("error").map { ": \($0)" } ?? "")"
    )
}
