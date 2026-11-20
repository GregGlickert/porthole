// Persistent label store: ~/.porthole/servers.json, keyed by port.
// Shared by every MCP process, the CLI and the menu app, so writes are atomic (tmp file + rename).
// The format is the same one the Node version wrote: { "version": 1, "servers": { "<port>": Label } }.
import Foundation

public struct PortholeError: Error, LocalizedError, CustomStringConvertible, Equatable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
  public var description: String { message }
}

/// One stored label. Dates are kept as the ISO strings on disk so a round trip never changes them.
public struct Label: Codable, Equatable, Sendable {
  public var port: Int
  public var title: String
  public var description: String?
  public var cwd: String?
  public var branch: String?
  public var registeredAt: String?
  public var lastSeenAt: String?

  public init(
    port: Int, title: String, description: String? = nil, cwd: String? = nil, branch: String? = nil,
    registeredAt: String? = nil, lastSeenAt: String? = nil
  ) {
    self.port = port
    self.title = title
    self.description = description
    self.cwd = cwd
    self.branch = branch
    self.registeredAt = registeredAt
    self.lastSeenAt = lastSeenAt
  }

  enum CodingKeys: String, CodingKey { case port, title, description, cwd, branch, registeredAt, lastSeenAt }

  /// Lenient: a hand edit can leave fields missing or of the wrong type; keep what's usable.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    port = (try? c.decode(Int.self, forKey: .port)) ?? 0
    title = (try? c.decode(String.self, forKey: .title)) ?? ""
    description = try? c.decode(String.self, forKey: .description)
    cwd = try? c.decode(String.self, forKey: .cwd)
    branch = try? c.decode(String.self, forKey: .branch)
    registeredAt = try? c.decode(String.self, forKey: .registeredAt)
    lastSeenAt = try? c.decode(String.self, forKey: .lastSeenAt)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(port, forKey: .port)
    try c.encode(title, forKey: .title)
    try c.encodeIfPresent(description, forKey: .description)
    try c.encode(cwd, forKey: .cwd)  // null, like the Node version
    try c.encode(branch, forKey: .branch)
    try c.encodeIfPresent(registeredAt, forKey: .registeredAt)
    try c.encodeIfPresent(lastSeenAt, forKey: .lastSeenAt)
  }
}

/// Labels keyed by port number as a string ("3000"), matching the file.
public typealias Labels = [String: Label]

public enum Store {
  public static func homeDir() -> URL {
    if let h = ProcessInfo.processInfo.environment["PORTHOLE_HOME"], !h.isEmpty {
      return URL(fileURLWithPath: h, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".porthole", isDirectory: true)
  }

  public static var storeURL: URL { homeDir().appendingPathComponent("servers.json") }
  public static var configURL: URL { homeDir().appendingPathComponent("config.json") }

  /// Keep only well-formed records: digit keys with object values (a hand edit can leave `"3000": null`).
  static func sane(_ servers: Any?) -> Labels {
    guard let dict = servers as? [String: Any] else { return [:] }
    var out: Labels = [:]
    for (k, v) in dict {
      guard !k.isEmpty, k.allSatisfy(\.isASCIIDigit), let obj = v as? [String: Any],
        let data = try? JSONSerialization.data(withJSONObject: obj),
        var label = try? JSONDecoder().decode(Label.self, from: data)
      else { continue }
      if label.port == 0, let p = Int(k) { label.port = p }
      out[k] = label
    }
    return out
  }

  /// Labels on disk; empty when missing or unreadable.
  public static func load() -> Labels {
    guard let data = try? Data(contentsOf: storeURL),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return sane(obj["servers"])
  }

  struct File: Encodable {
    let version = 1
    let servers: Labels
  }

  public static func save(_ servers: Labels) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try enc.encode(File(servers: servers))
    data.append(0x0A)
    try atomicWrite(data, to: storeURL, prefix: ".servers")
  }

  /// Write to a temp file in the same folder, then rename over the target (atomic on one volume).
  static func atomicWrite(_ data: Data, to url: URL, prefix: String) throws {
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // Unique per write: two writes in one process and millisecond must not share a temp file.
    let tmp = dir.appendingPathComponent("\(prefix).\(getpid()).\(UUID().uuidString).tmp")
    try data.write(to: tmp)
    if rename(tmp.path, url.path) != 0 {
      let err = String(cString: strerror(errno))
      try? FileManager.default.removeItem(at: tmp)
      throw PortholeError("Couldn't save \(url.path): \(err)")
    }
  }

  /// Like load(), but throws if servers.json exists and isn't valid JSON, so a writer never saves over it.
  static func loadForWrite() throws -> Labels {
    let data: Data
    do {
      data = try Data(contentsOf: storeURL)
    } catch let err as CocoaError where err.code == .fileReadNoSuchFile {
      return [:]
    }
    guard !hasTrailingComma(data), let obj = try? JSONSerialization.jsonObject(with: data) else {
      throw PortholeError(
        "\(storeURL.path) isn't valid JSON; fix or delete it (porthole edit labels). Not overwriting it.")
    }
    return sane((obj as? [String: Any])?["servers"])
  }

  /// Foundation's parser accepts `{"a": 1,}`, which strict JSON (and the Node version) rejects. A trailing comma
  /// usually means a hand edit went wrong, so treat it as invalid rather than saving over the user's file.
  static func hasTrailingComma(_ data: Data) -> Bool {
    var inString = false
    var escaped = false
    var pendingComma = false
    for b in data {
      if inString {
        if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { inString = false }
        continue
      }
      switch b {
      case 0x22: inString = true; pendingComma = false
      case 0x2C: pendingComma = true
      case 0x7D, 0x5D: if pendingComma { return true }
      case 0x20, 0x09, 0x0A, 0x0D: break
      default: pendingComma = false
      }
    }
    return false
  }

  /// Read-modify-write. `body` mutates the labels and returns whether to save (false skips the write).
  @discardableResult
  public static func update(_ body: (inout Labels) throws -> Bool) throws -> Bool {
    try locked {
      var servers = try loadForWrite()
      guard try body(&servers) else { return false }
      try save(servers)
      return true
    }
  }

  private static let threadLock = NSLock()

  /// Serialize read-modify-write cycles: across threads in this process (the MCP SDK handles tool calls
  /// concurrently) and across processes (several agents' MCP servers, the CLI and the menu app) via flock
  /// on ~/.porthole/.lock. Without it, two parallel register_server calls could each save over the other.
  public static func locked<T>(_ body: () throws -> T) throws -> T {
    threadLock.lock()
    defer { threadLock.unlock() }
    let dir = homeDir()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fd = open(dir.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
    if fd >= 0 {
      while flock(fd, LOCK_EX) != 0 && errno == EINTR {}
    }
    defer {
      if fd >= 0 {
        flock(fd, LOCK_UN)
        close(fd)
      }
    }
    return try body()
  }
}

extension Character {
  var isASCIIDigit: Bool { isASCII && isNumber }
}

/// ISO 8601 with milliseconds ("2026-11-19T19:41:57.847Z"), the format JavaScript's toISOString() writes.
public enum ISO {
  nonisolated(unsafe) private static let withMs: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()
  private static let lock = NSLock()

  public static func string(_ date: Date) -> String {
    lock.withLock { withMs.string(from: date) }
  }

  /// Parses JS-style ISO dates, including Docker's nanosecond fractions ("…:15.123456789Z").
  public static func date(_ s: String?) -> Date? {
    guard var s, !s.isEmpty else { return nil }
    // Trim the fraction to milliseconds: the formatter only understands up to 3 digits.
    if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
      let digits = s[s.index(after: dot)..<end]
      if digits.count > 3 { s.replaceSubrange(s.index(dot, offsetBy: 4)..<end, with: "") }
    }
    return lock.withLock { withMs.date(from: s) ?? plain.date(from: s) }
  }

  /// Milliseconds since 1970, or 0 when missing or invalid (like `Date.parse(x) || 0`).
  public static func ms(_ s: String?) -> Double {
    (date(s)?.timeIntervalSince1970 ?? 0) * 1000
  }
}
