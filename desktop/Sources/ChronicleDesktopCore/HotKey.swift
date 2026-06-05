import Carbon
import Foundation

public struct HotKeySpec: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum ShortcutSpec: Codable, Equatable, Sendable {
    case doubleControl
    case hotKey(HotKeySpec)
}

public enum ShortcutParser {
    public static let defaultSpec = ShortcutSpec.doubleControl

    public static func displayString(for spec: ShortcutSpec) -> String {
        switch spec {
        case .doubleControl:
            "Double Control"
        case let .hotKey(hotKey):
            HotKeyParser.displayString(for: hotKey)
        }
    }

    public static func parse(_ raw: String) -> ShortcutSpec? {
        let normalized = raw
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "+", with: " ")
            .split(separator: " ")
            .map(String.init)
            .joined(separator: " ")

        if normalized == "double control" || normalized == "control control" {
            return .doubleControl
        }

        guard let hotKey = HotKeyParser.parse(raw) else {
            return nil
        }
        return .hotKey(hotKey)
    }
}

public enum HotKeyParser {
    public static let defaultSpec = HotKeySpec(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey | optionKey),
    )

    public static func displayString(for spec: HotKeySpec) -> String {
        var parts: [String] = []
        if spec.modifiers & UInt32(controlKey) != 0 { parts.append("control") }
        if spec.modifiers & UInt32(optionKey) != 0 { parts.append("option") }
        if spec.modifiers & UInt32(cmdKey) != 0 { parts.append("command") }
        if spec.modifiers & UInt32(shiftKey) != 0 { parts.append("shift") }
        parts.append(name(for: spec.keyCode) ?? "space")
        return parts.joined(separator: "+")
    }

    public static func parse(_ raw: String) -> HotKeySpec? {
        let parts = raw
            .lowercased()
            .replacingOccurrences(of: "⌃", with: "control+")
            .replacingOccurrences(of: "⌥", with: "option+")
            .replacingOccurrences(of: "⌘", with: "command+")
            .replacingOccurrences(of: "⇧", with: "shift+")
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var modifiers: UInt32 = 0
        var parsedKeyCode: UInt32?

        for part in parts {
            switch part {
            case "cmd", "command":
                modifiers |= UInt32(cmdKey)
            case "ctrl", "control":
                modifiers |= UInt32(controlKey)
            case "opt", "option", "alt":
                modifiers |= UInt32(optionKey)
            case "shift":
                modifiers |= UInt32(shiftKey)
            default:
                parsedKeyCode = keyCode(for: part)
            }
        }

        guard let parsedKeyCode, modifiers != 0 else {
            return nil
        }
        return HotKeySpec(keyCode: parsedKeyCode, modifiers: modifiers)
    }

    private static func keyCode(for name: String) -> UInt32? {
        switch name {
        case "space":
            UInt32(kVK_Space)
        case "return", "enter":
            UInt32(kVK_Return)
        case "escape", "esc":
            UInt32(kVK_Escape)
        case "a": UInt32(kVK_ANSI_A)
        case "b": UInt32(kVK_ANSI_B)
        case "c": UInt32(kVK_ANSI_C)
        case "d": UInt32(kVK_ANSI_D)
        case "e": UInt32(kVK_ANSI_E)
        case "f": UInt32(kVK_ANSI_F)
        case "g": UInt32(kVK_ANSI_G)
        case "h": UInt32(kVK_ANSI_H)
        case "i": UInt32(kVK_ANSI_I)
        case "j": UInt32(kVK_ANSI_J)
        case "k": UInt32(kVK_ANSI_K)
        case "l": UInt32(kVK_ANSI_L)
        case "m": UInt32(kVK_ANSI_M)
        case "n": UInt32(kVK_ANSI_N)
        case "o": UInt32(kVK_ANSI_O)
        case "p": UInt32(kVK_ANSI_P)
        case "q": UInt32(kVK_ANSI_Q)
        case "r": UInt32(kVK_ANSI_R)
        case "s": UInt32(kVK_ANSI_S)
        case "t": UInt32(kVK_ANSI_T)
        case "u": UInt32(kVK_ANSI_U)
        case "v": UInt32(kVK_ANSI_V)
        case "w": UInt32(kVK_ANSI_W)
        case "x": UInt32(kVK_ANSI_X)
        case "y": UInt32(kVK_ANSI_Y)
        case "z": UInt32(kVK_ANSI_Z)
        default: nil
        }
    }

    private static func name(for keyCode: UInt32) -> String? {
        switch Int(keyCode) {
        case kVK_Space: "space"
        case kVK_Return: "return"
        case kVK_Escape: "escape"
        case kVK_ANSI_A: "a"
        case kVK_ANSI_B: "b"
        case kVK_ANSI_C: "c"
        case kVK_ANSI_D: "d"
        case kVK_ANSI_E: "e"
        case kVK_ANSI_F: "f"
        case kVK_ANSI_G: "g"
        case kVK_ANSI_H: "h"
        case kVK_ANSI_I: "i"
        case kVK_ANSI_J: "j"
        case kVK_ANSI_K: "k"
        case kVK_ANSI_L: "l"
        case kVK_ANSI_M: "m"
        case kVK_ANSI_N: "n"
        case kVK_ANSI_O: "o"
        case kVK_ANSI_P: "p"
        case kVK_ANSI_Q: "q"
        case kVK_ANSI_R: "r"
        case kVK_ANSI_S: "s"
        case kVK_ANSI_T: "t"
        case kVK_ANSI_U: "u"
        case kVK_ANSI_V: "v"
        case kVK_ANSI_W: "w"
        case kVK_ANSI_X: "x"
        case kVK_ANSI_Y: "y"
        case kVK_ANSI_Z: "z"
        default: nil
        }
    }
}
