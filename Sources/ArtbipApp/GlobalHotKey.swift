import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A system-wide keyboard shortcut, registered through the Carbon Hot Key API.
///
/// Carbon rather than NSEvent.addGlobalMonitorForEvents because the monitor
/// route needs Input Monitoring permission — a scary prompt for a wallpaper
/// app — while RegisterEventHotKey needs none. And rather than SwiftUI's
/// .keyboardShortcut, which inside a MenuBarExtra only becomes an NSMenu key
/// equivalent: those fire while the menu is open and never otherwise, so in an
/// accessory app with no main menu they are decorative.
final class GlobalHotKey {
    /// The C event handler cannot capture context, so actions are looked up by
    /// hot key id through this table.
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private static let signature: OSType = 0x6172_7462   // 'artb'

    private let id: UInt32
    private var ref: EventHotKeyRef?

    init(id: UInt32 = 1) { self.id = id }

    deinit { unbind() }

    /// Bind (or rebind) the shortcut. A negative key code just unbinds, which is
    /// how "no shortcut" is expressed in settings.
    @discardableResult
    func bind(keyCode: Int, modifiers: Int, action: @escaping () -> Void) -> Bool {
        unbind()
        guard keyCode >= 0, modifiers != 0 else { return false }
        Self.installHandlerIfNeeded()
        Self.actions[id] = action
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            // Another app already owns the combination; leave it unbound so the
            // UI can say so rather than silently doing nothing.
            Self.actions[id] = nil
            ref = nil
            return false
        }
        return true
    }

    func unbind() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.actions[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard status == noErr, let action = GlobalHotKey.actions[hkID.id] else {
                return OSStatus(eventNotHandledErr)
            }
            action()
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Resolves the NSWindow hosting a SwiftUI scene.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The view has no window during make, and updateNSView is not guaranteed
        // to run again, so poll briefly rather than resolving to nil once.
        retry(view, attempts: 40)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window { onResolve(window) }
    }

    private func retry(_ view: NSView, attempts: Int) {
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let window = view.window {
                onResolve(window)
            } else {
                retry(view, attempts: attempts - 1)
            }
        }
    }
}

// MARK: - Recorder

/// Click, then press a combination. Captures the next key-down through a local
/// monitor, so the keystroke never reaches the rest of the UI.
struct ShortcutRecorder: View {
    @EnvironmentObject var controller: RotationController
    @State private var recording = false
    @State private var monitor: Any?
    @State private var rejected = false

    var body: some View {
        HStack(spacing: 8) {
            Button(buttonTitle) { recording ? stop() : start() }
                .frame(width: 130)
            if controller.settings.hotKeyCode >= 0 && !recording {
                Button("Clear") { set(code: -1, modifiers: 0, label: "None") }
                    .buttonStyle(.borderless)
            }
        }
        .onDisappear(perform: stop)
        .help(rejected ? "That combination is already taken by another app."
                       : "Click, then press the keys you want.")
    }

    private var buttonTitle: String {
        if recording { return "Press keys…" }
        if rejected { return "Taken — retry" }
        return controller.settings.hotKeyCode >= 0 ? controller.settings.hotKeyLabel : "None"
    }

    private func start() {
        recording = true
        rejected = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape abandons; a bare key with no modifiers would steal that key
            // system-wide, so require at least one.
            if Int(event.keyCode) == kVK_Escape {
                stop()
                return nil
            }
            let mods = HotKeyFormat.carbonModifiers(event.modifierFlags)
            guard mods != 0, let key = HotKeyFormat.keyName(event) else { return nil }
            set(code: Int(event.keyCode), modifiers: mods,
                label: HotKeyFormat.label(modifiers: mods, key: key))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func set(code: Int, modifiers: Int, label: String) {
        controller.updateSettings {
            $0.hotKeyCode = code
            $0.hotKeyModifiers = modifiers
            $0.hotKeyLabel = label
        }
        // The menu-bar label owns the registration and rebinds on change; it
        // reports back here if the system refused the combination.
        rejected = code >= 0 && !controller.hotKeyBound
    }
}

// MARK: - Modifier translation and display

enum HotKeyFormat {
    /// NSEvent modifier flags -> Carbon modifier mask.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var mask = 0
        if flags.contains(.command) { mask |= cmdKey }
        if flags.contains(.option) { mask |= optionKey }
        if flags.contains(.control) { mask |= controlKey }
        if flags.contains(.shift) { mask |= shiftKey }
        return mask
    }

    /// "⌥⌘A" — modifiers in the order macOS shows them, then the key itself.
    static func label(modifiers: Int, key: String) -> String {
        var out = ""
        if modifiers & controlKey != 0 { out += "⌃" }
        if modifiers & optionKey != 0 { out += "⌥" }
        if modifiers & shiftKey != 0 { out += "⇧" }
        if modifiers & cmdKey != 0 { out += "⌘" }
        return out + key.uppercased()
    }

    /// A printable name for the pressed key, preferring the layout-independent
    /// character and falling back to names for keys that have no glyph.
    static func keyName(_ event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
                  chars.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            return chars
        }
    }
}

