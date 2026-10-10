// swift run --package-path tests/sessions sessions <check> [BASE …] [options]   (sessions --help)
import ArgumentParser
import Foundation

/// The options every check takes: where the executables and the run's files come from.
struct Inputs: ParsableArguments {
    @Option(
        help: "Boot with a built app's helper, services worker, firmwarekit, dylib, usbmuxd and guest package.",
        transform: path
    )
    var app: URL?
    @Option(
        help: """
            Another emulator dylib (a development build), for the Debug helper only: not with --app, whose helper \
            loads the app's own Frameworks/libqemu-arm.dylib (a Release helper ignores LTM_QEMU_DYLIB).
            """,
        transform: path
    )
    var dylib: URL?
    @Option(transform: path) var usbmuxd: URL?
    @Option(help: "The guest's HTTP client (default: the pinned qemu-ios's contrib/it-proxy/httpget).", transform: path)
    var httpget: URL?
    @Option(
        help: "Keeps the logs, screenshots and events (default: a temporary directory, deleted if the run passes).",
        transform: path
    )
    var work: URL?
    @Flag(help: "Keeps the temporary work directory of a run that passes.") var keep = false
    @Option(help: "The signing requirement the driver pins the helper to.") var requirement: String?

    func validate() throws {
        if app != nil, dylib != nil {
            throw ValidationError(
                "--dylib can't be used with --app: the app's helper loads its own Frameworks/libqemu-arm.dylib "
                    + "(a Release helper ignores LTM_QEMU_DYLIB). Drop --app to boot the Debug helper with --dylib."
            )
        }
    }
}

/// `value` with ~ expanded.
func path(_ value: String) -> URL { URL(fileURLWithPath: (value as NSString).expandingTildeInPath) }

struct Sessions: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: "Emulator sessions on prepared bases, headless and silent; exit 1 on any FAIL.",
        discussion: """
            Every boot is headless and silent (-audio driver=none); nothing goes on screen. A BASE is a prepared device \
            (firmwarekit create output); it is read only. Without --app the Debug helper, services worker and \
            firmwarekit are built (cached in .build/sessions-xcode) and scripts/vendor's directory supplies the rest.
            """,
        subcommands: [
            SingleCheck.self, PairCheck.self, ProxyTrustCheck.self, LocalNetworkCheck.self, HelperCheck.self,
            HelperBootCheck.self, PhoneCheck.self, RotationCheck.self, FlickCheck.self,
            TweaksCheck.self,
        ]
    )
}

struct SingleCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "single",
        abstract: """
            One device as the app boots it: lit, lockdown, activation, time zone, the Home screen (agent state, frame \
            reference), backlight, AFC, an IPA install, a clean shutdown, the base untouched.
            """
    )
    @Argument var base: String
    @Flag(help: "Launch the installed IPA through the guest agent; it must be frontmost.") var launch = false
    @Flag(help: "A second cold boot on the same overlay: a file and the app must survive.") var reboot = false
    @Option(help: "The guest agent reads PATH back at Home.") var readFile: String?
    @Option(
        help: "Tweaks' Developer Settings: mount this Developer Disk Image (.signature beside it) at Home.",
        transform: path
    )
    var developerImage: URL?
    @Flag(help: "The base was prepared with --skip-setup: no Setup page, Setup's answers from the Mac.")
    var skipSetup = false
    @Flag(
        help: """
            The base was prepared with --jailbreak: Files reads the whole file system through afc2, Cydia launches, \
            Substrate loads into SpringBoard (3.x to 5.x; idevicesyslog on PATH).
            """
    )
    var jailbreak = false
    @Option(help: "Install a newer build of the same app over it; its data must stay.", transform: path)
    var upgradeIPA: URL?
    @Option(help: "With --reboot: boot 2 asks for TZ.") var secondZone: String?
    @Flag(help: "Shut down with the host's power gesture (iPod/1G).") var hostPowerGesture = false
    @Option(help: "N boots, AFC at lockdown's first answer, then Stop.") var afcRace: Int?
    @Option(help: "Free-form Apply at WxH (as the panel scans) from Home: the frame, the dock row, a tap.")
    var panel: String?
    @Flag(help: "With --afc-race: dirty boots.") var dirty = false
    @Flag var noInstall = false
    @Flag var noOffer = false
    @Option(transform: path) var ipa: URL?
    @Option(transform: path) var itpack: URL?
    @Option(transform: path) var audioWAV: URL?
    @OptionGroup var inputs: Inputs

    func run() { single(self) }
}

struct PairCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pair",
        abstract: "Two devices at once (an n72 base, a k48 base): kill -9 of one, restart, Stop both."
    )
    @Argument var ipodBase: String
    @Argument var ipadBase: String
    @Flag var noOffer = false
    @Option(transform: path) var ipa: URL?
    @OptionGroup var inputs: Inputs

    func run() { pair(self) }
}

struct ProxyTrustCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "proxy-trust",
        abstract: "The web proxy's CA trusted silently (an n72 or k48 base)."
    )
    @Argument var base: String
    @Option var url = "https://example.com/"
    @OptionGroup var inputs: Inputs

    func run() { proxyTrust(self) }
}

struct LocalNetworkCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "local-network",
        abstract: """
            Attach to Local Network off: internet yes, the Mac's LAN no, until turned on (an n72 or k48 base); usbmuxd \
            opens no network socket.
            """
    )
    @Argument var base: String
    @Option var internet = "http://example.com/"
    @Option var dns = "http://example/"
    @Option var domain = "com"
    @Flag(help: "Boot wifi0 restricted (5.x Setup offline): no internet, DNS or LAN, even once turned on.")
    var restricted = false
    @OptionGroup var inputs: Inputs

    func run() { localNetworkCheck(self) }
}

struct HelperCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "helper",
        abstract: "The helper without a guest: signature pin, leases, kill before hello, preparation failure."
    )
    @OptionGroup var inputs: Inputs

    func run() { helperChecks(self) }
}

struct HelperBootCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "helper-boot",
        abstract: "The helper alone on an n72 base: input, rotation, parent death, a meddled overlay, power."
    )
    @Argument var base: String
    @Option(help: "The cases, comma-separated.") var only = "ipod,meddle,power"
    @OptionGroup var inputs: Inputs

    func run() { helperBoot(self) }
}

struct PhoneCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "phone",
        abstract:
            "An iPhone base: carrier (SMS tone, ringtone, vibration), emergency, location (GPS), compass, rotate, shutdown, "
            + "keyboard, simpin."
    )
    @Argument var base: String
    @Option(help: "The cases, comma-separated.") var only =
        "carrier,emergency,location,compass,rotate,shutdown,keyboard,simpin"
    @Option(help: "The overlay of a boot that walked Setup (5.x-7.x carrier and rotate), cloned.", transform: path)
    var overlay: URL?
    @OptionGroup var inputs: Inputs

    func run() { phone(self) }
}

struct RotationCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rotation",
        abstract:
            "Rotate Right and Left with Safari in front: the picture as the window shows it is upright, a tap lands."
    )
    @Argument var base: String
    @Option(help: "The overlay of a boot that walked Setup (5.x-7.x), cloned.", transform: path) var overlay: URL?
    @OptionGroup var inputs: Inputs

    func run() { rotationCheck(self) }
}

struct FlickCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "flick",
        abstract:
            "Trackpad swipes on the Home screen: a quick short flick turns the page, a slow short drag snaps back."
    )
    @Argument var base: String
    @Option(help: "The overlay of a boot that walked Setup (5.x-7.x), cloned.", transform: path) var overlay: URL?
    @Option(help: "Gestures of each kind.") var runs = 10
    @Option(help: "The kinds, comma-separated (helper-driver's trackpadGesture).") var kinds = "flick,slow"
    @OptionGroup var inputs: Inputs

    func run() { flickCheck(self) }
}

// App code in the drivers logs and keeps state under the run's own directories, never the user's library.
setenv("LTM_STATE_DIR", FileManager.default.temporaryDirectory.appendingPathComponent("ltm-sessions-state").path, 1)
Sessions.main()
