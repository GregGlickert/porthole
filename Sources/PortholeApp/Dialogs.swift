// Native alerts. Porthole has no windows, so it activates itself first or the alert would open behind other apps.
import AppKit

@MainActor
enum Dialogs {
  private static func alert(_ message: String, info: String, style: NSAlert.Style = .informational) -> NSAlert {
    NSApp.activate()
    let a = NSAlert()
    a.messageText = message
    a.informativeText = info
    a.alertStyle = style
    return a
  }

  /// Text prompt. Returns nil on Cancel.
  static func ask(_ message: String, info: String, defaultAnswer: String) -> String? {
    let a = alert(message, info: info)
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
    field.stringValue = defaultAnswer
    field.placeholderString = "e.g. Upload retry flow"
    a.accessoryView = field
    a.addButton(withTitle: "OK")
    a.addButton(withTitle: "Cancel")
    a.window.initialFirstResponder = field
    return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
  }

  /// Destructive confirmation with Cancel as the default button. The Stop/Kill button is a plain button:
  /// `hasDestructiveAction` draws red text on a red-tinted glass button, which is hard to read.
  static func confirm(_ message: String, info: String, button: String) -> Bool {
    let a = alert(message, info: info, style: .warning)
    a.addButton(withTitle: "Cancel")
    a.addButton(withTitle: button)
    return a.runModal() == .alertSecondButtonReturn
  }

  static func error(_ message: String) {
    let a = alert("Porthole", info: message, style: .warning)
    a.addButton(withTitle: "OK")
    a.runModal()
  }

  static func info(_ message: String, info: String) {
    let a = alert(message, info: info)
    a.addButton(withTitle: "OK")
    a.runModal()
  }
}
