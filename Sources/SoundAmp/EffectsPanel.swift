import AppKit
import SoundAmpCore

/// Effects panel: speed (varispeed or time-stretch), pitch (Signalsmith Stretch)
/// and the Dattorro plate reverb. A plain, opaque utility window with standard,
/// full-contrast controls (follows light/dark mode).
@MainActor
final class EffectsPanel: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let preset = NSPopUpButton()
    private let speed = ValueSlider(range: 0.5...1.5, center: 1, format: { String(format: "%.2f×", $0) })
    private let keepPitch = NSButton(checkboxWithTitle: "Keep pitch (time-stretch instead of varispeed)", target: nil, action: nil)
    private let formants = NSButton(checkboxWithTitle: "Preserve formants (natural vocals when pitching)", target: nil, action: nil)
    private let pitch = ValueSlider(range: -12...12, center: 0, step: 0.5,
                                    format: { $0 == 0 ? "0 st" : String(format: "%+.1f st", $0) })
    private let reverbSwitch = NSSwitch()
    private let mix = ValueSlider(range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" })
    // Capped: decay rises steeply near 1 (0.85 ≈ 7 s already), size above ~1.2 gets cavernous.
    private let decay = ValueSlider(range: 0.3...0.85, format: { String(format: "%.2f", $0) })
    private let tone = ValueSlider(range: 0...1, format: { $0 > 0.66 ? "Bright" : ($0 > 0.33 ? "Warm" : "Dark") })
    private let predelay = ValueSlider(range: 0...150, step: 1, format: { "\(Int($0)) ms" })
    private let size = ValueSlider(range: 0.5...1.25, center: 0.85, format: { String(format: "%.2f", $0) })
    private let wallSwitch = NSSwitch()
    private let wall = ValueSlider(range: 0...1, format: { $0 > 0.8 ? "Concrete" : ($0 > 0.55 ? "Brick" : ($0 > 0.3 ? "Drywall" : "Door ajar")) })
    private let note = NSTextField(wrappingLabelWithString: "")
    private let enableButton = NSButton(title: "Allow Audio Access…", target: nil, action: nil)
    /// Set while our own controls push a change, so the refresh doesn't fight the drag.
    private var applyingFromControls = false
    private var observer: NSObjectProtocol?

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                        styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Effects"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        super.init()
        panel.delegate = self

        preset.target = self
        preset.action = #selector(presetChosen)
        for s in [speed, pitch, mix, decay, tone, predelay, size, wall] { s.onChange = { [weak self] in self?.controlsChanged() } }
        wallSwitch.target = self
        wallSwitch.action = #selector(controlsChanged)
        for b in [keepPitch, formants] { b.target = self; b.action = #selector(controlsChanged) }
        reverbSwitch.target = self
        reverbSwitch.action = #selector(controlsChanged)
        enableButton.target = self
        enableButton.action = #selector(enable)
        enableButton.bezelStyle = .rounded
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor

        let resetSpeed = Self.smallButton("1×", target: self, action: #selector(resetSpeed))
        let resetPitch = Self.smallButton("0", target: self, action: #selector(resetPitch))

        let grid = NSGridView(views: [
            [Self.label("Preset"), preset],
            [Self.section("Speed & Pitch"), NSGridCell.emptyContentView],
            [Self.label("Speed"), Self.row(speed.view, resetSpeed)],
            [NSGridCell.emptyContentView, keepPitch],
            [Self.label("Pitch"), Self.row(pitch.view, resetPitch)],
            [NSGridCell.emptyContentView, formants],
            [Self.sectionWithSwitch("Plate Reverb", reverbSwitch), NSGridCell.emptyContentView],
            [Self.label("Mix"), mix.view],
            [Self.label("Decay"), decay.view],
            [Self.label("Tone"), tone.view],
            [Self.label("Pre-delay"), predelay.view],
            [Self.label("Size"), size.view],
            [Self.sectionWithSwitch("Next Door", wallSwitch), NSGridCell.emptyContentView],
            [Self.label("Wall"), wall.view],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for r in [1, 6, 12] { grid.row(at: r).topPadding = 8 }
        grid.cell(atColumnIndex: 0, rowIndex: 12).xPlacement = .leading
        grid.cell(atColumnIndex: 0, rowIndex: 1).xPlacement = .leading
        grid.cell(atColumnIndex: 0, rowIndex: 6).xPlacement = .leading
        for r in [1, 6, 12] { grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: r, length: 1)) }

        let footer = NSStackView(views: [note, enableButton])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 6

        let stack = NSStackView(views: [grid, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            note.widthAnchor.constraint(equalToConstant: 360),
            preset.widthAnchor.constraint(equalToConstant: 260),
        ])
        panel.contentView = content
        for v in [grid, stack] as [NSView] { v.setContentHuggingPriority(.required, for: .vertical) }

        observer = NotificationCenter.default.addObserver(forName: PlayerController.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// Window height follows the content (the note can wrap to 1–3 lines, the
    /// permission button comes and goes); keep the top edge where it is.
    private func fitToContent() {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        guard size.height > 0, abs(size.height - content.frame.height) > 0.5 || abs(size.width - content.frame.width) > 0.5 else { return }
        let top = panel.frame.maxY
        panel.setContentSize(size)
        panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
    }

    func show() {
        if !panel.isVisible, let main = Env.windows?.main {
            panel.setFrameTopLeftPoint(NSPoint(x: main.frame.maxX + 12, y: main.frame.maxY))
        }
        refresh()
        panel.makeKeyAndOrderFront(nil)
    }

    /// The panel's content, for snapshots in tests.
    var contentView: NSView? { panel.contentView }

    // MARK: Model ⇄ controls

    private func refresh() {
        guard !applyingFromControls, let p = Env.player else { return }
        let e = p.effects
        preset.removeAllItems()
        preset.addItems(withTitles: EffectSettings.presets.map(\.name))
        if let name = p.effectsPresetName {
            preset.selectItem(withTitle: name)
        } else {
            preset.addItem(withTitle: "Custom")
            preset.selectItem(withTitle: "Custom")
        }
        speed.value = e.speed
        keepPitch.state = e.keepPitch ? .on : .off
        pitch.value = e.semitones
        formants.state = e.preserveFormants ? .on : .off
        reverbSwitch.state = e.reverbOn ? .on : .off
        mix.value = e.reverbMix
        decay.value = e.reverbDecay
        tone.value = 1 - e.reverbDamping
        predelay.value = e.reverbPredelayMs
        size.value = e.reverbSize
        for s in [mix, decay, tone, predelay, size] { s.isEnabled = e.reverbOn }
        wallSwitch.state = e.wallOn ? .on : .off
        wall.value = e.wallAmount
        wall.isEnabled = e.wallOn

        if !p.eqOn {
            note.stringValue = "Bypassed: the EQ window's ON button switches the whole chain (EQ, speed, pitch, reverb, next door)."
            enableButton.title = "Turn On"
            enableButton.isHidden = false
            fitToContent()
            return
        }
        enableButton.title = "Allow Audio Access…"
        let needsTap = e.needsProcessing && !p.currentIsLocal
        let lowQualityStretch = e.keepPitch && abs(e.speed - 1) >= 0.005 && !p.keepPitchUsesSignalsmith
        if needsTap && p.needsAudioPermission {
            note.stringValue = lowQualityStretch
                ? "Keep pitch is using WebKit's basic time-stretch. Allow audio access for Signalsmith quality (and for pitch/reverb on SoundCloud tracks)."
                : "Pitch and reverb on SoundCloud tracks need audio access (macOS calls it “System Audio Recording”). Speed works without it."
            enableButton.isHidden = false
        } else {
            enableButton.isHidden = true
            if let fx = p.tap.effects, abs(e.semitones) >= 0.01, fx.latency > 0 {
                note.stringValue = String(format: "Pitch shifting adds %.0f ms of latency.", fx.latency * 1000)
            } else {
                note.stringValue = "Speed changes SoundCloud's own player; pitch and reverb run after the EQ."
            }
        }
        fitToContent()
    }

    @objc private func controlsChanged() {
        var e = EffectSettings()
        e.speed = (speed.value * 100).rounded() / 100
        e.keepPitch = keepPitch.state == .on
        e.semitones = pitch.value
        e.preserveFormants = formants.state == .on
        e.reverbOn = reverbSwitch.state == .on
        e.reverbMix = mix.value
        e.reverbDecay = decay.value
        e.reverbDamping = 1 - tone.value
        e.reverbPredelayMs = predelay.value
        e.reverbSize = size.value
        e.wallOn = wallSwitch.state == .on
        e.wallAmount = wall.value
        applyingFromControls = true
        Env.player.setEffects(e)
        applyingFromControls = false
        // Update only what the drag doesn't own: preset name, enabled states, note.
        for s in [mix, decay, tone, predelay, size] { s.isEnabled = e.reverbOn }
        wall.isEnabled = e.wallOn
        if let name = Env.player.effectsPresetName { preset.selectItem(withTitle: name) } else {
            if preset.item(withTitle: "Custom") == nil { preset.addItem(withTitle: "Custom") }
            preset.selectItem(withTitle: "Custom")
        }
    }

    @objc private func presetChosen() {
        guard let name = preset.titleOfSelectedItem, let p = EffectSettings.presets.first(where: { $0.name == name }) else { return }
        Env.player.applyEffectsPreset(p)
    }

    @objc private func resetSpeed() { var e = Env.player.effects; e.speed = 1; Env.player.setEffects(e) }
    @objc private func resetPitch() { var e = Env.player.effects; e.semitones = 0; Env.player.setEffects(e) }
    @objc private func enable() {
        if !Env.player.eqOn { Env.player.setEqOn(true) } else { Env.player.requestAudioFeatures("effects") }
    }

    /// Test hook: drive the controls like a user would and return the resulting settings.
    func selfTest() -> EffectSettings {
        speed.simulateUserSet(0.7)
        pitch.simulateUserSet(3)
        reverbSwitch.state = .on
        controlsChanged()
        mix.simulateUserSet(0.5)
        return Env.player.effects
    }

    // MARK: Layout helpers

    private static func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }

    private static func section(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return l
    }

    /// Section heading with an on/off switch right next to it, vertically centered.
    private static func sectionWithSwitch(_ s: String, _ toggle: NSSwitch) -> NSStackView {
        let r = NSStackView(views: [section(s), toggle])
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = 10
        return r
    }

    private static func row(_ views: NSView...) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.spacing = 8
        return r
    }

    private static func smallButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return b
    }
}

/// A standard horizontal slider with a fixed width, a live value readout and a
/// gentle snap to its center value (if any).
@MainActor
private final class ValueSlider: NSObject {
    let view: NSStackView
    private let slider: NSSlider
    private let readout = NSTextField(labelWithString: "")
    private let format: (Double) -> String
    private let step: Double?
    private let center: Double?
    var onChange: (() -> Void)?

    init(range: ClosedRange<Double>, center: Double? = nil, step: Double? = nil, format: @escaping (Double) -> String) {
        slider = NSSlider(value: range.lowerBound, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        self.format = format
        self.step = step
        self.center = center
        slider.isContinuous = true
        slider.controlSize = .regular
        readout.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        readout.alignment = .right
        view = NSStackView(views: [slider, readout])
        view.orientation = .horizontal
        view.spacing = 10
        super.init()
        slider.translatesAutoresizingMaskIntoConstraints = false
        readout.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            slider.widthAnchor.constraint(equalToConstant: 200),
            readout.widthAnchor.constraint(equalToConstant: 64),
        ])
        slider.target = self
        slider.action = #selector(changed)
    }

    var value: Double {
        get { snapped(slider.doubleValue) }
        set { slider.doubleValue = newValue; readout.stringValue = format(snapped(newValue)) }
    }

    var isEnabled: Bool {
        get { slider.isEnabled }
        set { slider.isEnabled = newValue; readout.textColor = newValue ? .labelColor : .tertiaryLabelColor }
    }

    /// Steps, plus a gentle snap to the center value (like the EQ's 0 dB).
    private func snapped(_ v: Double) -> Double {
        var v = v
        if let c = center, abs(v - c) < (slider.maxValue - slider.minValue) * 0.02 { v = c }
        if let s = step { v = (v / s).rounded() * s }
        return v
    }

    func simulateUserSet(_ v: Double) {
        slider.doubleValue = v
        changed()
    }

    @objc private func changed() {
        readout.stringValue = format(value)
        onChange?()
    }
}
