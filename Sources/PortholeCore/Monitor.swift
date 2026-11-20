// What the live menu does each tick, as pure functions (the app's Monitor loop drives them).
// Every 5 s it takes a cheap fingerprint of listening ports. The full scan runs only when that fingerprint
// changes or labels/config in ~/.porthole/ change. Once a minute it redraws from the last scan so ages stay
// current, and checks cheaply for what the fingerprint can't see: a branch switch in a running server's
// checkout, or a Docker row whose container name couldn't be read last time.
import Foundation

public enum MonitorLogic {
  public static let pollInterval: TimeInterval = 5
  public static let redrawInterval: TimeInterval = 60
  /// lastSeenAt keeps labels from being pruned. Refresh it for live labeled ports at most this often.
  public static let seenEvery: TimeInterval = 10 * 60

  public struct State: Equatable {
    public var fingerprint: String?
    public var prevFingerprint: String?
    public var dirty: Bool
    public var lastRender: Date
    public init(fingerprint: String? = nil, prevFingerprint: String? = nil, dirty: Bool = true, lastRender: Date = .distantPast) {
      self.fingerprint = fingerprint
      self.prevFingerprint = prevFingerprint
      self.dirty = dirty
      self.lastRender = lastRender
    }
  }

  public struct Plan: Equatable {
    public var portsChanged: Bool
    public var rescan: Bool
    public var redraw: Bool
    public init(portsChanged: Bool, rescan: Bool, redraw: Bool) {
      self.portsChanged = portsChanged
      self.rescan = rescan
      self.redraw = redraw
    }
  }

  /// Which work this tick needs. The first tick (no previous fingerprint) isn't a port change.
  public static func plan(_ s: State, now: Date) -> Plan {
    let portsChanged = s.prevFingerprint != nil && s.fingerprint != s.prevFingerprint
    let rescan = portsChanged || s.dirty
    let redraw = rescan || now.timeIntervalSince(s.lastRender) >= redrawInterval
    return Plan(portsChanged: portsChanged, rescan: rescan, redraw: redraw)
  }

  /// What in ~/.porthole/ affects the menu: labels (minus lastSeenAt, which we write ourselves) and config.
  /// A file event that leaves this unchanged needs no rescan.
  public static func settingsKey(_ servers: Labels = Store.load(), _ config: Config = Config.load()) -> String {
    let labels = servers.sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }.map { key, l in
      [key, l.title, l.description ?? "", l.cwd ?? "", l.branch ?? "", l.registeredAt ?? ""].joined(separator: "\u{1F}")
    }
    let cfg = (try? JSONSerialization.data(withJSONObject: config.json, options: [.sortedKeys]))
      .map { String(decoding: $0, as: UTF8.self) } ?? ""
    return labels.joined(separator: "\u{1E}") + "\u{1D}" + cfg
  }

  /// Entries from a scan at `scannedAt`, with uptimes advanced to `now` so ages are right without rescanning.
  public static func aged(_ entries: [Entry], scannedAt: Date, now: Date) -> [Entry] {
    let dt = max(0, Int(now.timeIntervalSince(scannedAt).rounded()))
    return entries.map { e in
      var e = e
      if let u = e.uptimeSec { e.uptimeSec = u + dt }
      return e
    }
  }

  /// Does the last scan look out of date in ways the port fingerprint can't detect?
  /// `branchOf(root)` reads the checkout's current branch (nil = unknown, which never forces a rescan).
  public static func looksStale(_ entries: [Entry], branchOf: (String) -> String? = { Git.headBranch(root: $0) }) -> Bool {
    entries.contains { e in
      if let d = e.docker { return d.container == nil }  // docker ps failed or timed out last time
      guard let root = e.root, let was = e.branch, let now = branchOf(root), now != was else { return false }
      // Detached: git's short sha can be longer than 7 chars, so compare by common prefix.
      func sha(_ s: String) -> String? {
        guard s.hasPrefix("detached@") else { return nil }
        let h = s.dropFirst("detached@".count)
        return !h.isEmpty && h.allSatisfy(\.isHexDigit) ? String(h) : nil
      }
      if let a = sha(now), let b = sha(was) { return !(a.hasPrefix(b) || b.hasPrefix(a)) }
      return true
    }
  }
}
