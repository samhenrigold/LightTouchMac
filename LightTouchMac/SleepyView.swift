// Created by Sam on 2026-09-05.

import AppKit

final class SleepingAnimationView: NSView {
    private let animationLayer: CALayer

    init() {
        let url = Bundle.main.url(forResource: "Sleeping", withExtension: "caar")!
        let data = try! Data(contentsOf: url)

        let unarchiver = try! NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = false
        defer { unarchiver.finishDecoding() }

        let archive = unarchiver.decodeObject(forKey: "root") as! [String: Any]
        animationLayer = archive["rootLayer"] as! CALayer

        super.init(frame: .zero)

        wantsLayer = true
        layer!.masksToBounds = false
        animationLayer.masksToBounds = false
        layer!.addSublayer(animationLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        animationLayer.frame = bounds
    }
}
