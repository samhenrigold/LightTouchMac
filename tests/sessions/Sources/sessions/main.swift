// swift run --package-path tests/sessions sessions <check> [BASE …] [options]   (sessions --help)
import ArgumentParser
import Foundation
import SessionKit

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
        help: "Where the run's logs, events, frames and overlays go (default: a temporary directory).",
        transform: path
    )
    var work: URL?
    @Flag(
        name: [.customLong("keep-work"), .customLong("keep")],
        help: """
            Keeps all of a passed run's work directory: by default only its logs, events and summary.txt stay \
            (overlays, NAND copies, the guest archive and frames go). A failed run keeps everything.
            """
    )
    var keepWork = false
    @Option(help: "The signing requirement the driver pins the helper to.") var requirement: String?
    @Flag(
        help: """
            Boot a base this tree would prepare differently (an older recipe, or a change to what preparation writes \
            since the base was made: FirmwareSchema's PreparationChanges) instead of refusing it.
            """
    )
    var allowStale = false

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
            Every boot is headless and silent (-audio driver=none, or a WAV: single records one); nothing goes on screen. A BASE is a prepared device \
            (firmwarekit create output); it is read only. Without --app the Debug helper, services worker and \
            firmwarekit are built (cached in .build/sessions-xcode) and scripts/vendor's directory supplies the rest.
            """,
        subcommands: [
            SingleCheck.self, PairCheck.self, ProxyTrustCheck.self, LocalNetworkCheck.self, HelperCheck.self,
            HelperBootCheck.self, PhoneCheck.self, RotationCheck.self, KeyboardCheck.self, FlickCheck.self,
            ScrollTopCheck.self, MatrixCheck.self, AffectedCheck.self, ListingsCheck.self, ResumeCheck.self,
            TweaksCheck.self, RespringCheck.self, ClipboardCheck.self, ToldCheck.self, BasesCheck.self,
            ReprepareCheck.self
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
    @Flag(help: "A file uploaded at Home, the helper SIGKILLed, a second boot: the file must survive.")
    var killPersist = false
    @Option(help: "The guest agent reads PATH back at Home.") var readFile: String?
    @Option(
        parsing: .unconditionalSingleValue,
        help:
            "The guest agent runs this at the first Home, one argument per --spawn (a deliberate crash: the run must fail naming it)."
    )
    var spawn: [String] = []
    @Flag(help: "Tweaks' Developer Settings: mount the guest archive's Developer Disk Image for the base at Home.")
    var developerImage = false
    @Flag(
        help: """
            Device ▸ Accessibility at Home: White on Black (Invert Colors) and VoiceOver on, read back from the guest, \
            the frame brighter, VoiceOver heard (with --audio-wav), then both off.
            """
    )
    var accessibility = false
    @Option(
        help: """
            Import Media at Home (repeatable: a song, a video, a photo): staged and committed as the app does, then \
            found in the music library or Saved Photos, read back from their databases; with --reboot also on boot 2.
            """,
        transform: path
    )
    var media: [URL] = []
    @Option(help: "Where itmedia and itphoto are (default: the pinned qemu-ios's contrib/it-media).", transform: path)
    var mediaTools: URL?
    @Flag(help: "The base was prepared with --skip-setup: no Setup page, Setup's answers from the Mac.")
    var skipSetup = false
    @Option(help: "The base was prepared with create --language TAG: the guest's language and region are TAG's.")
    var language: String?
    @Option(help: "The guest's AppleKeyboards, comma-separated, as create --keyboards should leave them (fr_FR,en_US).")
    var keyboards: String?
    @Flag(
        help: """
            The base was prepared with --jailbreak: Files reads the whole file system through afc2, Cydia launches \
            with the web proxy on (its front page through it, its sources refreshed, and on a phone a package \
            installed through Cydia's pages), Substrate loads into SpringBoard (3.x to 6.x; idevicesyslog on PATH). \
            Cydia's repositories are local ones the proxy serves (no internet) unless --network.
            """
    )
    var jailbreak = false
    @Flag(
        help: """
            With --jailbreak: Cydia's sources and front page from the internet and bc installed from Cydia/Telesphoreo \
            (the nightly and pre-release matrix), instead of the local repositories.
            """
    )
    var network = false
    @Option(help: "Install a newer build of the same app over it; its data must stay.", transform: path)
    var upgradeIPA: URL?
    @Option(help: "With --reboot: boot 2 asks for TZ.") var secondZone: String?
    @Option(help: "lockdown-tz also sets LOCALE as the region, as the app sets the Mac's (ClockRegion.mac).")
    var region: String?
    @Flag(help: "Shut down with the host's power gesture (iPod/1G).") var hostPowerGesture = false
    @Option(help: "N boots, AFC at lockdown's first answer, then Stop.") var afcRace: Int?
    @Option(help: "Free-form Apply at WxH (as the panel scans) from Home: the frame, the dock row, a tap.")
    var panel: String?
    @Flag(help: "With --afc-race: dirty boots.") var dirty = false
    @Flag(help: "CoreAnimation composites through the emulator's GL bridge, and the bridge refuses nothing.")
    var gl = false
    @Flag(help: "Boot with Settings ▸ General's experimental ANGLE renderer on.") var angle = false
    @Flag var noInstall = false
    @Flag var noOffer = false
    @Option(transform: path) var ipa: URL?
    @Option(transform: path) var itpack: URL?
    @Option(help: "Where the guest's WAV goes (default: the work directory's audio/guest.wav).", transform: path)
    var audioWAV: URL?
    @Flag(
        help: """
            Boot it as a device the user already has: published under the run's state as the app publishes one (the \
            base an APFS clone), every boot through the app's boot admission and its record's boot.
            """
    )
    var managed = false
    @Option(
        help: """
            Implies --managed and --allow-stale: an old device's admission step, which the base must need and \
            the device must have taken by the end of the run (repeatable; Managed.swift lists the old devices): \
            \(ManagedDevice.Step.allCases.map(\.rawValue).joined(separator: ", ")).
            """
    )
    var expectAdmission: [ManagedDevice.Step] = []
    @OptionGroup var inputs: Inputs

    func run() { single(self) }
}

extension ManagedDevice.Step: ExpressibleByArgument {}

struct BasesCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bases",
        abstract: """
            Says, booting nothing, whether each base is fresh or stale: how it was prepared, where its recipe is not \
            its catalog row's (a boot path or option it was prepared with: a variant or drift, not stale), and what \
            this tree would prepare differently (the check every other command makes before it boots).
            """
    )
    @Argument var bases: [String]

    func run() { for base in bases { _ = Base(base, allowStale: true) } }
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
        abstract: """
            The helper alone on an n72 base: input, rotation, parent death, a meddled overlay, power; with angle, a \
            snapshot refused on the experimental ANGLE renderer.
            """
    )
    @Argument var base: String
    @Option(help: "The cases, comma-separated (ipod, meddle, power, angle).") var only = "ipod,meddle,power"
    @OptionGroup var inputs: Inputs

    func run() { helperBoot(self) }
}

struct PhoneCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "phone",
        abstract:
            "An iPhone base: carrier (SMS tone, ringtone, vibration), emergency, location (GPS), compass, rotate, shutdown, "
            + "keyboard, simpin; thermal (20 minutes) only when asked."
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
    @Option(
        help: """
            The overlay of a boot that activated the device (2.x) or walked Setup (5.x-7.x), cloned (default: a first \
            boot by sessions single makes one).
            """,
        transform: path
    )
    var overlay: URL?
    @OptionGroup var inputs: Inputs

    func run() { rotationCheck(self) }
}

struct KeyboardCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keyboard",
        abstract: "An n81ap or n90ap base: the Mac's keys type into a new note (key_mac -> usb-kbd), read back."
    )
    @Argument var base: String
    @Option(help: "The overlay of a boot that walked Setup (5.x-7.x without --skip-setup), cloned.", transform: path)
    var overlay: URL?
    @OptionGroup var inputs: Inputs

    func run() { keyboardCheck(self) }
}

struct ScrollTopCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scrolltop",
        abstract: "A quick tap on the status bar scrolls Settings' list back to the top (frames compared)."
    )
    @Argument var base: String
    @Option(help: "The overlay of a boot that walked Setup (5.x-7.x without --skip-setup), cloned.", transform: path)
    var overlay: URL?
    @Option(help: "Where the tap lands, as a fraction of the screen's height.") var y = 0.02
    @Option(
        help: "How long the tap holds, in seconds: 0 is a trackpad's tap to click, released before the guest reads."
    )
    var hold = 0.0
    @Option(help: "Drag and tap rounds.") var taps = 4
    @OptionGroup var inputs: Inputs

    func run() { scrollTopCheck(self) }
}

struct FlickCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "flick",
        abstract:
            "Trackpad swipes on the Home screen: a quick short flick turns the page, a slow short drag snaps back."
    )
    @Argument var base: String
    @Option(help: "The overlay of a boot that walked Setup (5.x or 6.x), cloned.", transform: path) var overlay: URL?
    @Option(help: "Gestures of each kind.") var runs = 10
    @Option(help: "The kinds, comma-separated (helper-driver's trackpadGesture).") var kinds = "flick,slow"
    @Option(help: "The least median frames/s of motion each kind's gestures may reach the app at.") var minFps = 45.0
    @Option(help: "The panel's refresh, Hz, as Settings ▸ General's experimental 120 Hz boots it.") var refreshHz = 60
    @Flag(help: "Boot with Settings ▸ General's experimental ANGLE renderer on.") var angle = false
    @OptionGroup var inputs: Inputs

    func run() { flickCheck(self) }
}

struct ClipboardCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clipboard",
        abstract: """
            An iOS 3.0 or later base: a copy on the device reaches the host once, the host's text reaches the \
            device's pasteboard, non-ASCII both ways (the guest agent's spawn of it_pbtool sets and reads it).
            """
    )
    @Argument var base: String
    @Option(
        help: """
            The guest's pasteboard tool (default: the pinned qemu-ios's contrib/it-pasteboard/it_pbtool, or \
            build/ipad1-guest/it_pbtool on an armv7 board).
            """,
        transform: path
    )
    var pbtool: URL?
    @Option(
        help: "The guest package offered at boot (default: the guest archive's for the base's arch).",
        transform: path
    )
    var itpack: URL?
    @OptionGroup var inputs: Inputs

    func run() { clipboardCheck(self) }
}

// App code in the drivers logs and keeps state under the run's own directories, never the user's library.
setenv("LTM_STATE_DIR", FileManager.default.temporaryDirectory.appendingPathComponent("ltm-sessions-state").path, 1)
TextReader.serveChild()  // a screen read's child process (TextReader): reads, prints and exits
Sessions.main()
