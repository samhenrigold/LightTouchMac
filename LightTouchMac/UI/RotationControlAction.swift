/// The normal button returns landscape to portrait, or turns portrait left.
/// Option reverses that next quarter-turn without changing the menu commands.
struct RotationControlAction {
    let clockwise: Bool

    init(rotationDegrees: Int, optionPressed: Bool) {
        clockwise = (rotationDegrees == 270) != optionPressed
    }

    var title: String { clockwise ? "Rotate Right" : "Rotate Left" }
    var symbol: String { clockwise ? "rotate.right" : "rotate.left" }
    var help: String { title + " (Option rotates the other way)" }
}
