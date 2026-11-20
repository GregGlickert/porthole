// Merge live scan results with stored labels. Pure core + thin I/O wrappers.
import Foundation

public enum Status: String, Codable, Sendable { case labeled, unlabeled, stale }

/// One row of the board: a live port and its label (if any).
public struct Entry: Equatable, Sendable {
  public var port: Int
  public var status: Status
  public var title: String?
  public var description: String?
  public var staleTitle: String?
  public var registeredAt: String?
  public var branch: String?
  public var repo: String?
  public var cwd: String?
  public var root: String?
  public var command: String
  public var pids: [Int]
  public var docker: DockerInfo?
  public var uptimeSec: Int?

  public var url: String { "http://localhost:\(port)" }

  public init(port: Int, status: Status = .unlabeled, command: String = "node", pids: [Int] = [1]) {
    self.port = port
    self.status = status
    self.command = command
    self.pids = pids
  }
}

extension Entry: Encodable {
  enum K: String, CodingKey {
    case port, url, status, title, description, staleTitle, registeredAt, branch, repo, cwd, root, command, pids,
      docker, uptimeSec
  }
  enum D: String, CodingKey { case container, image, project, service, workingDir, containerPort }

  /// Same shape as the Node version's list_servers output: nulls kept, docker is `false` or an object.
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: K.self)
    try c.encode(port, forKey: .port)
    try c.encode(url, forKey: .url)
    try c.encode(status, forKey: .status)
    try c.encode(title, forKey: .title)
    try c.encode(description, forKey: .description)
    try c.encode(staleTitle, forKey: .staleTitle)
    try c.encode(registeredAt, forKey: .registeredAt)
    try c.encode(branch, forKey: .branch)
    try c.encode(repo, forKey: .repo)
    try c.encode(cwd, forKey: .cwd)
    try c.encode(root, forKey: .root)
    try c.encode(command, forKey: .command)
    try c.encode(pids, forKey: .pids)
    if let d = docker {
      var dc = c.nestedContainer(keyedBy: D.self, forKey: .docker)
      if d.container != nil || d.project != nil || d.image != nil {
        try dc.encode(d.container, forKey: .container)
        try dc.encode(d.image, forKey: .image)
        try dc.encode(d.project, forKey: .project)
        try dc.encode(d.service, forKey: .service)
        try dc.encode(d.workingDir, forKey: .workingDir)
        try dc.encode(d.containerPort, forKey: .containerPort)
      }
    } else {
      try c.encode(false, forKey: .docker)
    }
    try c.encode(uptimeSec, forKey: .uptimeSec)
  }
}

public enum Board {
  public static let pruneAfter: TimeInterval = 24 * 60 * 60
  static let seenWriteInterval: TimeInterval = 60

  /// Pure merge. Returns the board plus labels to prune (unseen for 24 h) and labeled ports seen live.
  public static func merge(_ live: [Live], _ servers: Labels, now: Date = Date())
    -> (entries: [Entry], prune: [String], seen: [String])
  {
    var entries: [Entry] = []
    var seen: [String] = []
    let livePorts = Set(live.map { String($0.port) })
    for l in live {
      let key = String(l.port)
      let rec = servers[key]
      var status = Status.unlabeled
      if let rec {
        // Same port, different checkout → someone else's label. cwd is unknown for docker; trust the label then.
        if let rc = rec.cwd, let lc = l.cwd, !rc.isEmpty, !lc.isEmpty, rc != lc { status = .stale } else { status = .labeled }
        if status == .labeled { seen.append(key) }
      }
      var e = Entry(port: l.port, status: status, command: l.command, pids: l.pids)
      e.title = status == .labeled ? rec?.title : nil
      e.description = status == .labeled ? rec?.description.flatMap { $0.isEmpty ? nil : $0 } : nil
      e.staleTitle = status == .stale ? rec?.title : nil
      e.registeredAt = rec?.registeredAt
      e.branch = l.branch
      e.repo = l.repo
      e.cwd = l.cwd
      e.root = l.root
      e.docker = l.docker
      e.uptimeSec = l.uptimeSec
      entries.append(e)
    }
    var prune: [String] = []
    for (key, rec) in servers where !livePorts.contains(key) {
      if isExpired(rec, now: now) { prune.append(key) }
    }
    return (entries, prune.sorted(), seen)
  }

  /// Unseen for 24 h. Like Node's `lastSeenAt || registeredAt`: an empty or unreadable lastSeenAt falls back.
  static func isExpired(_ rec: Label, now: Date) -> Bool {
    let last = ISO.date(rec.lastSeenAt) ?? ISO.date(rec.registeredAt) ?? Date(timeIntervalSince1970: 0)
    return now.timeIntervalSince(last) > pruneAfter
  }

  /// Live board. Side effects: refresh lastSeenAt (throttled) and prune old labels.
  public static func get(live: [Live]? = nil, now: Date = Date()) -> [Entry] {
    board(live: live, now: now).entries
  }

  /// The board plus the labels as they are on disk afterwards (including this call's own prune/lastSeenAt
  /// writes), so the menu can tell its own writes apart from someone else's edit.
  public static func board(live: [Live]? = nil, now: Date = Date()) -> (entries: [Entry], labels: Labels) {
    let live = live ?? Detect.scan(now: now)
    let servers = Store.load()
    let (entries, prune, seen) = merge(live, servers, now: now)
    let needsSeen = seen.filter {
      now.timeIntervalSince(ISO.date(servers[$0]?.lastSeenAt) ?? .distantPast) > seenWriteInterval
    }
    var after = servers
    if !prune.isEmpty || !needsSeen.isEmpty {
      _ = try? Store.update { s in
        // Recheck under the lock: a label registered since our unlocked read must not be pruned.
        for p in prune where s[p].map({ isExpired($0, now: now) }) == true { s[p] = nil }
        for p in needsSeen { s[p]?.lastSeenAt = ISO.string(now) }
        after = s
        return true
      }
    }
    return (entries, after)
  }

  /// Record that labeled `ports` were live just now. The menu calls this right before rescanning after a port
  /// closes: it only rescans on change, so lastSeenAt would otherwise be as old as the last change and the
  /// 24 h prune could drop a label the moment its server stops.
  public static func markSeen(_ ports: [Int], now: Date = Date()) throws {
    guard !ports.isEmpty else { return }
    try Store.update { s in
      var touched = false
      for p in ports where s[String(p)] != nil {
        s[String(p)]?.lastSeenAt = ISO.string(now)
        touched = true
      }
      return touched  // nothing to record → don't rewrite the file
    }
  }

  /// Pure: first `count` ports in [min, max] that nothing listens on and no label claims,
  /// starting at `preferred` (if in range) and wrapping around.
  public static func freePorts(
    listening: Set<Int>, labeled: some Sequence<String>, min: Int, max: Int, preferred: Int? = nil,
    count: Int = 1, reserved: some Sequence<Int> = [Int]()
  ) -> [Int] {
    var taken = listening
    for k in labeled { if let p = Int(k) { taken.insert(p) } }
    taken.formUnion(reserved)
    guard max >= min else { return [] }
    let start = preferred.flatMap { $0 >= min && $0 <= max ? $0 : nil } ?? min
    let span = max - min + 1
    var out: [Int] = []
    var i = 0
    while i < span && out.count < count {
      let p = min + (start - min + i) % span
      if !taken.contains(p) && !Detect.ignorePorts.contains(p) { out.append(p) }
      i += 1
    }
    return out
  }

  /// Free ports, each reserved for 2 minutes so a parallel agent won't be handed the same one.
  /// `isFree` double-checks a candidate against ports held by other users (which libproc can't see).
  public static func suggestFreePorts(
    preferred: Int? = nil, count: Int = 1, isFree: (Int) -> Bool = Ports.isBindable
  ) throws -> [Int] {
    let cfg = Config.load()
    let listening = Detect.listeningPorts()
    let labeled = Store.load().keys
    var out: [Int] = []
    var lost = Set<Int>()  // reserved by another process between our read and reserve(), or held by another user
    while out.count < count {
      let reserved = Reservations.active().union(out).union(lost)
      guard
        let p = freePorts(
          listening: listening, labeled: labeled, min: cfg.min, max: cfg.max, preferred: preferred, count: 1,
          reserved: reserved
        ).first
      else { break }  // range exhausted
      if isFree(p), try Reservations.reserve(p) { out.append(p) } else { lost.insert(p) }
    }
    return out
  }

  public static func findLive(_ port: Int, live: [Live]? = nil) -> Live? {
    (live ?? Detect.scan()).first { $0.port == port }
  }

  public static func validPort(_ port: Int) throws {
    guard (1...65535).contains(port) else { throw PortholeError("Invalid port: \(port)") }
  }

  /// Register/overwrite a label. Waits up to `wait` seconds for the port to start listening (agents often
  /// register right after launching a server). `known` is what the caller already knows about the server
  /// (the menu passes it); it's used instead of a full scan while something is still listening on the port.
  @discardableResult
  public static func register(
    port: Int, title: String, description: String? = nil, wait: TimeInterval = 10,
    known: (cwd: String?, branch: String?)? = nil
  ) async throws -> Label {
    try validPort(port)
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { throw PortholeError("title is required") }
    var found: (cwd: String?, branch: String?)?
    if let known, !Detect.listeners(on: port).isEmpty {
      found = known
    } else if let l = findLive(port) {
      found = (l.cwd, l.branch)
    }
    let deadline = Date().addingTimeInterval(wait)
    while found == nil && Date() < deadline {
      try await Task.sleep(for: .seconds(1))
      if let l = findLive(port) { found = (l.cwd, l.branch) }
    }
    guard let found else {
      throw PortholeError(
        "Nothing is listening on port \(port) (checked \(Int(wait.rounded()))s). Start the dev server first, then register it."
      )
    }
    let now = ISO.string(Date())
    let desc = description?.trimmingCharacters(in: .whitespacesAndNewlines)
    let rec = Label(
      port: port, title: title, description: desc?.isEmpty == false ? desc : nil, cwd: found.cwd,
      branch: found.branch, registeredAt: now, lastSeenAt: now)
    try Store.update { s in
      s[String(port)] = rec
      return true
    }
    Reservations.release(port)
    return rec
  }

  @discardableResult
  public static func updateLabel(port: Int, title: String? = nil, description: String? = nil) throws -> Label {
    let key = String(port)
    if title == nil && description == nil {
      throw PortholeError("Nothing to update: pass title and/or description.")
    }
    if let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw PortholeError("title cannot be empty (use remove_server to clear a label).")
    }
    var rec: Label?
    try Store.update { s in
      guard var r = s[key] else { throw PortholeError("Port \(key) is not registered. Use register_server first.") }
      if let title { r.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
      if let description {
        let d = description.trimmingCharacters(in: .whitespacesAndNewlines)
        r.description = d.isEmpty ? nil : d
      }
      s[key] = r
      rec = r
      return true
    }
    return rec!
  }

  /// Clear a label. Returns whether there was one.
  @discardableResult
  public static func remove(port: Int) throws -> Bool {
    var existed = false
    try Store.update { s in
      existed = s[String(port)] != nil
      s[String(port)] = nil
      return true
    }
    return existed
  }
}
