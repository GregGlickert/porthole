// Actions shared by the CLI and the menu app.
import Foundation

public enum Actions {
  /// SIGTERM what's on `port`. With `pids` (the menu passes the PIDs it showed), only those still listening on
  /// the port are signalled, so a reused PID is never hit. Docker ports get `docker stop` instead (killing the
  /// PID would kill Docker itself). Returns a one-line summary.
  @discardableResult
  public static func kill(port: Int, pids: [Int]? = nil) throws -> String {
    if let given = pids {
      let live = Detect.filterLivePids(given, Detect.killablePids(on: port))
      guard !live.isEmpty else {
        throw PortholeError("Nothing listening on \(port) with PID \(given.map(String.init).joined(separator: ", ")) anymore.")
      }
      return signal(port: port, pids: live, what: "")
    }
    guard let l = Board.findLive(port) else { throw PortholeError("Nothing listening on \(port).") }
    if let d = l.docker { return try stopContainer(port: port, container: d.container) }
    return signal(port: port, pids: l.pids, what: " (\(l.command))")
  }

  static func signal(port: Int, pids: [Int], what: String) -> String {
    var failed: [String] = []
    for pid in pids where Darwin.kill(pid_t(pid), SIGTERM) != 0 {
      failed.append("Could not kill \(pid): \(String(cString: strerror(errno)))")
    }
    let sent = "Sent SIGTERM to \(pids.map(String.init).joined(separator: ", "))\(what) on :\(port)"
    return ([sent] + failed).joined(separator: "\n")
  }

  @discardableResult
  public static func stopContainer(port: Int, container: String?) throws -> String {
    guard let container else {
      throw PortholeError(
        "Port \(port) is published by Docker but its container couldn't be identified (is `docker ps` working?).")
    }
    try Docker.stop(container)
    return "Stopped container \(container) on :\(port)"
  }

  /// Hide (or unhide) a port number or a process name from the board.
  @discardableResult
  public static func ignore(_ target: String, add: Bool) throws -> String {
    try Store.locked { try ignoreUnlocked(target, add: add) }
  }

  static func ignoreUnlocked(_ target: String, add: Bool) throws -> String {
    var cfg = Config.load()
    if let port = Int(target), target.allSatisfy(\.isASCIIDigit) {
      try Board.validPort(port)
      cfg.ignorePorts.removeAll { $0 == port }
      if add { cfg.ignorePorts.append(port) }
      try cfg.save()
      return "\(add ? "Ignoring" : "No longer ignoring") port \(port)."
    }
    cfg.ignoreCommands.removeAll { $0 == target }
    if add { cfg.ignoreCommands.append(target) }
    try cfg.save()
    return "\(add ? "Ignoring" : "No longer ignoring") command \"\(target)\"."
  }

  /// The file `porthole edit` opens, created with defaults if missing.
  public static func editableFile(labels: Bool) throws -> URL {
    let url = labels ? Store.storeURL : Store.configURL
    if !FileManager.default.fileExists(atPath: url.path) {
      if labels {
        try Store.save([:])
      } else {
        try Config(portMin: Defaults.portMin, portMax: Defaults.portMax).save()
      }
    }
    return url
  }
}
