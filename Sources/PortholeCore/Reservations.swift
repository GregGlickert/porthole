// Port reservations: ~/.porthole/reserved/<port>
// suggest_free_port reserves what it hands out so two agents can't get the same port before either server listens.
// One file per port, created with O_EXCL under the store lock (~/.porthole/.lock), so concurrent MCP processes
// never hand out the same port, and an expired reservation is taken over by exactly one caller.
import Foundation

public enum Reservations {
  public static let ttl: TimeInterval = 2 * 60

  static var dir: URL { Store.homeDir().appendingPathComponent("reserved", isDirectory: true) }

  /// Create `file` only if it doesn't exist. Returns false on EEXIST.
  static func createExclusive(_ file: URL, body: String) throws -> Bool {
    let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
    if fd < 0 {
      if errno == EEXIST { return false }
      throw PortholeError("Couldn't reserve \(file.lastPathComponent): \(String(cString: strerror(errno)))")
    }
    defer { close(fd) }
    let bytes = Array(body.utf8)
    _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    return true
  }

  static func mtime(_ file: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
  }

  /// Try to reserve `port`. Returns false if someone else holds a live reservation.
  /// Runs under the store's cross-process lock, so an expired reservation is taken over by exactly one caller.
  public static func reserve(_ port: Int, now: Date = Date()) throws -> Bool {
    try Store.locked {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let file = dir.appendingPathComponent(String(port))
      let body = "{\"port\":\(port),\"pid\":\(getpid()),\"at\":\"\(ISO.string(now))\"}\n"
      if try createExclusive(file, body: body) { return true }
      guard removeIfExpired(file, now: now) else { return false }
      return try createExclusive(file, body: body)
    }
  }

  /// Remove `file` if its reservation has expired. Callers hold Store.locked.
  static func removeIfExpired(_ file: URL, now: Date) -> Bool {
    guard let m = mtime(file), now.timeIntervalSince(m) > ttl else { return false }
    return unlink(file.path) == 0
  }

  public static func release(_ port: Int) {
    unlink(dir.appendingPathComponent(String(port)).path)
  }

  /// Ports with a live reservation (expired files are cleaned up).
  public static func active(now: Date = Date()) -> Set<Int> {
    (try? Store.locked { activeUnlocked(now: now) }) ?? []
  }

  static func activeUnlocked(now: Date) -> Set<Int> {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
    var out = Set<Int>()
    for name in names {
      guard !name.isEmpty, name.allSatisfy(\.isASCIIDigit), let port = Int(name) else { continue }
      let file = dir.appendingPathComponent(name)
      guard let m = mtime(file) else { continue }
      if now.timeIntervalSince(m) <= ttl { out.insert(port) } else { _ = removeIfExpired(file, now: now) }
    }
    return out
  }
}
