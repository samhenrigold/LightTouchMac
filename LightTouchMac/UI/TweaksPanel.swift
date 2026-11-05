// The Tweaks panel (Device ▸ Tweaks…): one device's hidden switches (TweaksPanelModel), by section. Each row's caption
// is what it changes; on firmware that doesn't have it, the row stays, disabled.

import Cocoa
import HostRuntime
import LightTouchCore
import SwiftUI

struct TweaksPanel: View {
    @Bindable var model: TweaksPanelModel
    @State private var showsTouches = false

    var body: some View {
        Form {
            ForEach(Tweak.Section.allCases, id: \.self) { section in
                Section(section.rawValue) {
                    ForEach(Tweak.allCases.filter { $0.section == section }, id: \.self) { tweak in
                        row(tweak)
                    }
                    if section == .interface, let dots = model.fingerDots {
                        TweakToggle(
                            title: "Show Touches",
                            caption: "View ▸ Show Finger Dots",
                            isOn: Binding(
                                get: { showsTouches },
                                set: {
                                    dots.set($0)
                                    showsTouches = dots.get()
                                }
                            )
                        )
                        .onAppear { showsTouches = dots.get() }
                    }
                }
            }
            Section("Hidden Apps") {
                if !model.opensHiddenApps {
                    Text("They open through the guest tools, which this version doesn’t run.")
                        .foregroundStyle(.secondary)
                } else if !model.isRunning {
                    Text("Start the device to open the apps its Home screen hides.").foregroundStyle(.secondary)
                } else if let apps = model.hiddenApps {
                    if apps.isEmpty {
                        Text("This firmware has none of them.").foregroundStyle(.secondary)
                    }
                    ForEach(apps) { app in
                        LabeledContent(app.name) {
                            Button("Open") { Task { await model.open(app) } }
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if let status = model.status {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 380, idealWidth: 420, minHeight: 560)
        .task(id: model.isRunning) { await model.listHiddenApps() }
    }

    @ViewBuilder
    private func row(_ tweak: Tweak) -> some View {
        let available = model.isAvailable(tweak)
        TweakToggle(
            title: tweak.title,
            caption: model.caption(tweak),
            note: model.note(tweak),
            isOn: Binding(
                get: { model.isOn(tweak) && available },
                set: { model.set(tweak, on: $0) }
            )
        )
        .disabled(!available)
        if available, model.isOn(tweak) { options(tweak) }
    }

    @ViewBuilder
    private func options(_ tweak: Tweak) -> some View {
        switch tweak {
        case .coreAnimationColors:
            Picker(
                "Color",
                selection: Binding(
                    get: { model.settings.coreAnimationColor },
                    set: { model.set(coreAnimationColor: $0) }
                )
            ) {
                ForEach(CoreAnimationColor.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        case .cleanStatusBar:
            StatusBarOptions(model: model)
        case .timeMachine:
            DatePicker(
                "Starts At",
                selection: Binding(get: { model.settings.clock }, set: { model.set(clock: $0) }),
                in: Date(timeIntervalSince1970: 978_307_200)...Date(timeIntervalSince1970: 2_147_483_000)
            )
            Button("Macworld 2007") { model.set(clock: TweakSettings.macworld2007) }
        default:
            EmptyView()
        }
    }
}

/// Marketing Status Bar's status bar: the clock's text and the carrier wherever it works; the bars, battery and
/// indicators one by one where UIKit takes overrides (4.2 on), else drawn full.
private struct StatusBarOptions: View {
    @Bindable var model: TweaksPanelModel

    var body: some View {
        let style = model.settings.statusBar
        let each = model.statusBarSetsEach
        CommitField(title: "Time", prompt: "Real time", value: style.time) { v in model.setStatusBar { $0.time = v } }
        CommitField(
            title: "Carrier",
            prompt: model.statusBarSetsCarrier ? "Network’s own" : "Not on this version",
            value: style.carrier
        ) { v in
            model.setStatusBar { $0.carrier = v }
        }
        .disabled(!model.statusBarSetsCarrier)
        Group {
            Stepper(
                model.hasCellular ? "Cellular Bars: \(style.cellBars)" : "Cellular Bars: no cellular radio",
                value: binding(\.cellBars),
                in: 0...5
            )
            .disabled(!model.hasCellular)
            Stepper("Wi-Fi Bars: \(style.wifiBars)", value: binding(\.wifiBars), in: 0...3)
            Stepper("Battery: \(style.battery)%", value: binding(\.battery), in: 0...100, step: 5)
            Toggle("Charging", isOn: binding(\.charging))
            TweakToggle(
                title: "Hide Indicators",
                caption: "Alarm, location, Bluetooth, rotation lock, activity",
                isOn: binding(\.hidesIndicators)
            )
        }
        .disabled(!each)
        if !each {
            Text("This version draws the bars and battery full.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func binding<T>(_ field: WritableKeyPath<StatusBarStyle, T>) -> Binding<T> {
        Binding(
            get: { model.settings.statusBar[keyPath: field] },
            set: { v in model.setStatusBar { $0[keyPath: field] = v } }
        )
    }
}

/// A text field that saves when editing ends (Return or leaving it), not at every keystroke: a change to SpringBoard's
/// keys restarts it.
private struct CommitField: View {
    let title: String
    let prompt: String
    let value: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .focused($focused)
            .onSubmit { save() }
            .onChange(of: focused) { if !focused { save() } }
            .onAppear { text = value }
            .onChange(of: value) { text = value }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed != value { commit(trimmed) }
    }
}

/// A switch with its caption under it, and its note (why it's off, or when it takes effect) under that.
struct TweakToggle: View {
    let title: String
    let caption: String
    var note: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
            Text(caption)
            if let note { Text(note) }
        }
    }
}

/// A Tweaks panel per device: a utility panel that floats above the device window, for a running or stopped device.
@MainActor final class TweaksWindowController: NSWindowController {
    let model: TweaksPanelModel
    init(model: TweaksPanelModel, name: String) {
        self.model = model
        let hosting = NSHostingController(rootView: TweaksPanel(model: model))
        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.titled, .closable, .resizable, .utilityWindow]
        panel.title = "Tweaks — \(name)"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.setFrameAutosaveName("TweaksPanel")
        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

extension DeviceTweaks {
    /// A stopped device's: its firmware's version from the catalog, its base's pinned clock.
    @MainActor static func stopped(_ instance: DeviceInstance) -> DeviceTweaks {
        DeviceTweaks(
            settings: DeviceSettingsFile(directory: instance.paths.directory),
            version: FirmwareCatalog.bundled.entry(id: instance.firmware)?.version ?? "3.1.3",
            guestTools: GuestPackage.runsAgent(firmware: instance.firmware),
            clockPinned: (try? DeviceLock.read(base: instance.paths.base))??.pinsClock == true,
            cellular: instance.profile?.hasCellular ?? true
        )
    }
}
