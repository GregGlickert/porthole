// Which editor / terminal / browser the "Open in …" actions use: config.json, else the first one installed.
import Foundation

public struct AppChoice: Equatable, Sendable {
  public var editor: String?
  public var terminal: String?
  public var browser: String?
  public init(editor: String? = nil, terminal: String? = nil, browser: String? = nil) {
    self.editor = editor
    self.terminal = terminal
    self.browser = browser
  }
}

public enum Apps {
  public static let editors = ["Cursor", "Visual Studio Code", "Zed", "Windsurf", "Sublime Text"]
  public static let terminals = ["Ghostty", "iTerm", "Warp", "Terminal"]
  /// "Open" uses Chrome if installed, else the default browser.
  public static let browsers = ["Google Chrome"]

  static var appDirs: [String] {
    ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
     "/System/Applications/Utilities"]
  }

  public static func installed(_ name: String) -> Bool {
    appDirs.contains { FileManager.default.fileExists(atPath: "\($0)/\(name).app") }
  }

  public static func pick(_ config: Config = Config.load(), isInstalled: (String) -> Bool = installed) -> AppChoice {
    AppChoice(
      editor: config.editor ?? editors.first(where: isInstalled),
      terminal: config.terminal ?? terminals.first(where: isInstalled),
      browser: config.browser ?? browsers.first(where: isInstalled))
  }

  /// Open `target` (a folder or URL) in `app` by name. Editors and terminals (Ghostty, iTerm, Terminal, Warp) all
  /// accept a folder this way and open it in the running instance. Don't use `open -n`: Ghostty's exits right away.
  public static func open(_ target: String, in app: String?) throws {
    let args = app.map { ["-a", $0, target] } ?? [target]
    guard Shell.run("/usr/bin/open", args, timeout: 15).status == 0 else {
      throw PortholeError("Couldn't open \(target)\(app.map { " in \($0)" } ?? "").")
    }
  }

  /// Open a localhost URL in the configured browser, falling back to the default browser.
  public static func openURL(_ url: String, config: Config = Config.load()) {
    if let b = pick(config).browser, (try? open(url, in: b)) != nil { return }
    try? open(url, in: nil)
  }
}
