// User config: ~/.porthole/config.json
// { "ignorePorts": [8000], "ignoreCommands": ["claude-science"], "portMin": 3000, "portMax": 9999,
//   "editor": "Zed", "terminal": "Ghostty", "browser": "Arc" }
import Foundation

public struct Config: Equatable, Sendable {
  public var ignorePorts: [Int] = []
  public var ignoreCommands: [String] = []
  public var portMin: Int?
  public var portMax: Int?
  public var editor: String?
  public var terminal: String?
  public var browser: String?

  public init(
    ignorePorts: [Int] = [], ignoreCommands: [String] = [], portMin: Int? = nil, portMax: Int? = nil,
    editor: String? = nil, terminal: String? = nil, browser: String? = nil
  ) {
    self.ignorePorts = ignorePorts
    self.ignoreCommands = ignoreCommands
    self.portMin = portMin
    self.portMax = portMax
    self.editor = editor
    self.terminal = terminal
    self.browser = browser
  }

  /// Effective dev port range: config, else PORTHOLE_PORT_MIN/MAX, else 3000–9999.
  public var min: Int { portMin ?? Defaults.portMin }
  public var max: Int { portMax ?? Defaults.portMax }

  /// Lenient parse of the file's JSON object: wrong types fall back to defaults.
  public init(json obj: [String: Any]) {
    func int(_ v: Any?) -> Int? {
      guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
      let d = n.doubleValue
      return d == d.rounded() ? Int(d) : nil
    }
    func str(_ v: Any?) -> String? {
      guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
      return s
    }
    ignorePorts = (obj["ignorePorts"] as? [Any])?.compactMap { int($0) ?? (($0 as? String).flatMap { Int($0) }) } ?? []
    ignoreCommands = (obj["ignoreCommands"] as? [Any])?.map { "\($0)" } ?? []
    portMin = int(obj["portMin"])
    portMax = int(obj["portMax"])
    editor = str(obj["editor"])
    terminal = str(obj["terminal"])
    browser = str(obj["browser"])
  }

  public var json: [String: Any] {
    var o: [String: Any] = ["ignorePorts": ignorePorts, "ignoreCommands": ignoreCommands]
    if let portMin { o["portMin"] = portMin }
    if let portMax { o["portMax"] = portMax }
    if let editor { o["editor"] = editor }
    if let terminal { o["terminal"] = terminal }
    if let browser { o["browser"] = browser }
    return o
  }

  /// Missing or invalid file → defaults.
  public static func load() -> Config {
    guard let data = try? Data(contentsOf: Store.configURL),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return Config() }
    return Config(json: obj)
  }

  public func save() throws {
    var data = try JSONSerialization.data(
      withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(0x0A)
    try Store.atomicWrite(data, to: Store.configURL, prefix: ".config")
  }
}

public enum Defaults {
  static func envInt(_ name: String, _ fallback: Int) -> Int {
    ProcessInfo.processInfo.environment[name].flatMap { Int($0) } ?? fallback
  }
  public static var portMin: Int { envInt("PORTHOLE_PORT_MIN", 3000) }
  public static var portMax: Int { envInt("PORTHOLE_PORT_MAX", 9999) }
}
