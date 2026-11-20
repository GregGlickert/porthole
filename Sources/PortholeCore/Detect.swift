// Live detection of listening dev servers, straight from the kernel via libproc (no lsof/netstat/ps).
// libproc only reports processes you own, which covers every dev server you start. Ports held by root or
// other users are caught by Ports.isBindable() where it matters (suggest_free_port).
import Darwin
import Foundation

/// One TCP listening socket: which process, which port.
public struct Listener: Hashable, Sendable {
  public let pid: Int
  public let command: String
  public let port: Int
  public init(pid: Int, command: String, port: Int) {
    self.pid = pid
    self.command = command
    self.port = port
  }
}

/// A listening dev-range port after grouping by port, with where it runs.
public struct Live: Equatable, Sendable {
  public var port: Int
  public var pids: [Int]
  public var command: String
  public var cwd: String?
  public var branch: String?
  public var repo: String?
  public var root: String?
  /// nil = not Docker. Non-nil = published by Docker (fields are nil if `docker ps` was unavailable).
  public var docker: DockerInfo?
  public var uptimeSec: Int?

  public init(
    port: Int, pids: [Int], command: String, cwd: String? = nil, branch: String? = nil, repo: String? = nil,
    root: String? = nil, docker: DockerInfo? = nil, uptimeSec: Int? = nil
  ) {
    self.port = port
    self.pids = pids
    self.command = command
    self.cwd = cwd
    self.branch = branch
    self.repo = repo
    self.root = root
    self.docker = docker
    self.uptimeSec = uptimeSec
  }
}

public enum Detect {
  /// macOS/system processes that hold ports in the dev range but are never "your app".
  public static let ignoreCommands: Set<String> = [
    "ControlCenter",  // AirPlay receiver on 5000/7000
    "rapportd", "sharingd", "identityservicesd", "launchd", "mDNSResponder",
  ]
  /// Databases / caches that aren't web dev servers.
  public static let ignorePorts: Set<Int> = [3306, 5432, 6379, 9200, 9300]
  public static let dockerCommands: Set<String> = [
    "com.docker.backend", "com.docker.vpnkit", "vpnkit-bridge", "docker-proxy",
  ]

  public static func isDevCandidate(command: String, port: Int, config: Config = Config()) -> Bool {
    port >= config.min && port <= config.max && !ignorePorts.contains(port) && !ignoreCommands.contains(command)
      && !config.ignorePorts.contains(port) && !config.ignoreCommands.contains(command)
  }

  // MARK: libproc

  static func allPids() -> [pid_t] {
    let n = proc_listallpids(nil, 0)
    guard n > 0 else { return [] }
    var buf = [pid_t](repeating: 0, count: Int(n) + 64)
    let got = buf.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    return Array(buf.prefix(Int(max(0, got))))
  }

  static func listenPorts(_ pid: pid_t) -> Set<Int> {
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return [] }
    let stride = MemoryLayout<proc_fdinfo>.stride
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
    let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
    guard got > 0 else { return [] }
    var ports = Set<Int>()
    let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
    for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
      var si = socket_fdinfo()
      guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, infoSize) >= infoSize,
        si.psi.soi_kind == SOCKINFO_TCP
      else { continue }
      let tcp = si.psi.soi_proto.pri_tcp
      guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
      // insi_lport holds the port in network byte order in its low 16 bits.
      ports.insert(Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))))
    }
    return ports
  }

  static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
    var b = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, size) == size ? b : nil
  }

  /// The process name lsof's `c` field shows (e.g. "com.docker.backend", not netstat's 16-char cut),
  /// so `ignoreCommands` entries from the Node version keep matching.
  static func command(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
    let n = proc_name(pid, &buf, UInt32(buf.count))
    if n > 0 { return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    guard var b = bsdInfo(pid) else { return "?" }
    return withUnsafeBytes(of: &b.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
  }

  public static func cwd(pid: Int) -> String? {
    var v = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid_t(pid), PROC_PIDVNODEPATHINFO, 0, &v, size) == size else { return nil }
    let path = withUnsafeBytes(of: &v.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    return path.isEmpty ? nil : path
  }

  /// Seconds since the process started.
  public static func uptime(pid: Int, now: Date = Date()) -> Int? {
    guard let b = bsdInfo(pid_t(pid)), b.pbi_start_tvsec > 0 else { return nil }
    let started = Double(b.pbi_start_tvsec) + Double(b.pbi_start_tvusec) / 1e6
    return max(0, Int((now.timeIntervalSince1970 - started).rounded()))
  }

  /// Every TCP listener this user can see, deduped by (pid, port) across IPv4/IPv6. About 3 ms.
  public static func listeners() -> [Listener] {
    var out: [Listener] = []
    for pid in allPids() where pid > 0 {
      let ports = listenPorts(pid)
      if ports.isEmpty { continue }
      let name = command(pid)
      for port in ports.sorted() { out.append(Listener(pid: Int(pid), command: name, port: port)) }
    }
    return out
  }

  /// Cheap change detector for the menu: sorted "pid:port" of dev-range listeners.
  /// Only the range and ignored ports apply (a renamed process shows up on the next full scan anyway).
  public static func fingerprint(_ rows: [Listener] = listeners(), config: Config = Config.load()) -> String {
    var c = config
    c.ignoreCommands = []
    return rows.filter { isDevCandidate(command: "", port: $0.port, config: c) }
      .map { "\($0.pid):\($0.port)" }.sorted().joined(separator: ",")
  }

  /// PIDs listening on `port` right now. Used by actions to check what the menu showed is still true.
  public static func listeners(on port: Int) -> Set<Int> {
    Set(listeners().filter { $0.port == port }.map(\.pid))
  }

  /// Like listeners(on:), minus Docker's own processes: those must never be signalled.
  public static func killablePids(on port: Int) -> Set<Int> {
    Set(listeners().filter { $0.port == port && !dockerCommands.contains($0.command) }.map(\.pid))
  }

  /// Pure: the PIDs from `pids` that are still in `listening` (a PID that stopped listening may have been reused).
  public static func filterLivePids(_ pids: [Int], _ listening: Set<Int>) -> [Int] {
    pids.filter { listening.contains($0) }
  }

  /// Every TCP port anything this user owns is listening on (no dev-range filtering).
  public static func listeningPorts() -> Set<Int> { Set(listeners().map(\.port)) }

  /// All listening dev-range ports, grouped by port, with folder, branch, uptime and Docker info.
  /// `rows` lets a caller that just listed listeners (the menu's 5 s check) skip listing them again.
  public static func scan(config: Config = Config.load(), now: Date = Date(), rows: [Listener]? = nil) -> [Live] {
    var byPort: [Int: Live] = [:]
    for l in rows ?? listeners() where isDevCandidate(command: l.command, port: l.port, config: config) {
      if var cur = byPort[l.port] {
        if !cur.pids.contains(l.pid) { cur.pids.append(l.pid) }
        // Docker if any listener is Docker (e.g. an ssh tunnel and Docker both on the port), so the menu offers
        // "Stop container" and never "Kill", which would signal Docker itself.
        if cur.docker == nil && dockerCommands.contains(l.command) { cur.docker = DockerInfo() }
        byPort[l.port] = cur
      } else {
        let isDocker = dockerCommands.contains(l.command)
        byPort[l.port] = Live(port: l.port, pids: [l.pid], command: l.command, docker: isDocker ? DockerInfo() : nil)
      }
    }
    let containers = byPort.values.contains { $0.docker != nil } ? Docker.ports(now: now) : [:]
    var git: [String: GitInfo] = [:]
    return byPort.values.map { s -> Live in
      var s = s
      if s.docker != nil {
        let c = containers[s.port]
        s.docker = c ?? DockerInfo()
        s.cwd = nil
        s.root = c?.workingDir
        s.branch = nil
        s.repo = c?.project
        s.uptimeSec = c?.uptimeSec
        return s
      }
      let cwd = cwd(pid: s.pids[0])
      s.cwd = cwd
      if let cwd {
        let g = git[cwd] ?? Git.info(cwd: cwd)
        git[cwd] = g
        s.branch = g.branch
        s.repo = g.repo
        s.root = g.root ?? (cwd != "/" ? cwd : nil)
      }
      s.uptimeSec = uptime(pid: s.pids[0], now: now)
      return s
    }.sorted { $0.port < $1.port }
  }
}

public enum Ports {
  /// True if nothing (any user) is listening on `port`. A strict wildcard bind (no SO_REUSEADDR) fails on any
  /// overlapping bind, including TIME_WAIT leftovers of a server that just stopped; in that case a localhost
  /// connect tells the two apart: refused on both loopbacks means nothing is actually listening.
  public static func isBindable(_ port: Int) -> Bool {
    if bind4(port) && bind6(port) { return true }
    return !accepts(port, v6: false) && !accepts(port, v6: true)
  }

  /// Does something accept connections on localhost:`port`? Loopback connects finish (or are refused) at once.
  static func accepts(_ port: Int, v6: Bool) -> Bool {
    let s = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
    guard s >= 0 else { return true }  // can't tell; assume taken
    defer { close(s) }
    var tv = timeval(tv_sec: 0, tv_usec: 300_000)
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    if v6 {
      var a = sockaddr_in6()
      a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
      a.sin6_family = sa_family_t(AF_INET6)
      a.sin6_port = in_port_t(UInt16(port).bigEndian)
      a.sin6_addr = in6addr_loopback
      return withUnsafePointer(to: &a) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
      } == 0
    }
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = in_port_t(UInt16(port).bigEndian)
    a.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    return withUnsafePointer(to: &a) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    } == 0
  }

  static func bind4(_ port: Int) -> Bool {
    let s = socket(AF_INET, SOCK_STREAM, 0)
    guard s >= 0 else { return true }  // can't tell; don't block
    defer { close(s) }
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = in_port_t(UInt16(port).bigEndian)
    a.sin_addr = in_addr(s_addr: INADDR_ANY)
    return withUnsafePointer(to: &a) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    } == 0
  }

  static func bind6(_ port: Int) -> Bool {
    let s = socket(AF_INET6, SOCK_STREAM, 0)
    guard s >= 0 else { return true }
    defer { close(s) }
    var on: Int32 = 1
    setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
    var a = sockaddr_in6()
    a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    a.sin6_family = sa_family_t(AF_INET6)
    a.sin6_port = in_port_t(UInt16(port).bigEndian)
    a.sin6_addr = in6addr_any
    return withUnsafePointer(to: &a) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
    } == 0
  }
}
