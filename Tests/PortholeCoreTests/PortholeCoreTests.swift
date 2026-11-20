import Foundation
import Testing

@testable import PortholeCore

/// Every test here shares one temp PORTHOLE_HOME, so they run one at a time.
@Suite(.serialized)
struct PortholeCoreTests {
  static let home: URL = {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("porthole-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    setenv("PORTHOLE_HOME", dir.path, 1)
    return dir
  }()

  init() throws {
    _ = Self.home
    try Store.save([:])
    try? FileManager.default.removeItem(at: Store.configURL)
    try? FileManager.default.removeItem(at: Reservations.dir)
  }

  static func live(_ port: Int, _ cwd: String?, branch: String? = "feat/x", repo: String? = nil, command: String = "node",
                   docker: DockerInfo? = nil, uptime: Int? = nil) -> Live {
    Live(port: port, pids: [1000 + port], command: command, cwd: cwd, branch: branch,
         repo: repo ?? ((cwd ?? "docker") as NSString).lastPathComponent, root: nil, docker: docker, uptimeSec: uptime)
  }

  static let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
  static var nowISO: String { ISO.string(now) }
  static let balanceApi = DockerInfo(container: "balance-api-1", image: "balance-api", project: "balance", service: "api", containerPort: 8080)

  // MARK: store

  @Test func storeRoundTrips() throws {
    try Store.save(["3001": Label(port: 3001, title: "A", registeredAt: "x")])
    #expect(Store.load()["3001"]?.title == "A")
  }

  @Test func invalidJSONIsNeverOverwritten() throws {
    let bad = #"{ "version": 1, "servers": { "3000": { "title": "A" }, } }"#
    try bad.write(to: Store.storeURL, atomically: true, encoding: .utf8)
    #expect(throws: PortholeError.self) { try Board.markSeen([3000]) }
    #expect(throws: PortholeError.self) { try Store.update { _ in true } }
    #expect(try String(contentsOf: Store.storeURL, encoding: .utf8) == bad)
  }

  @Test func loadDropsMalformedRecordsAndMarkSeenSkipsNoOpWrites() throws {
    let json = #"{"version":1,"servers":{"3000":null,"3001":"x","3002":{"port":3002,"title":"ok"}}}"#
    try json.write(to: Store.storeURL, atomically: true, encoding: .utf8)
    #expect(Array(Store.load().keys) == ["3002"])
    let before = try FileManager.default.attributesOfItem(atPath: Store.storeURL.path)[.modificationDate] as? Date
    try Board.markSeen([4000])
    let after = try FileManager.default.attributesOfItem(atPath: Store.storeURL.path)[.modificationDate] as? Date
    #expect(before == after)
  }

  @Test func readsNodeWrittenFile() throws {
    let node = """
      {
        "version": 1,
        "servers": {
          "3002": {
            "port": 3002,
            "title": "PR 3409",
            "description": "Webpack dev server",
            "cwd": "/Users/me/app",
            "branch": "worktree-fix",
            "registeredAt": "2026-11-19T20:26:58.034Z",
            "lastSeenAt": "2026-11-19T20:42:31.824Z"
          },
          "3000": { "port": 3000, "title": "Main", "cwd": null, "branch": null, "registeredAt": "2026-11-19T19:41:57.847Z" }
        }
      }
      """
    try node.write(to: Store.storeURL, atomically: true, encoding: .utf8)
    let s = Store.load()
    #expect(s["3002"] == Label(port: 3002, title: "PR 3409", description: "Webpack dev server", cwd: "/Users/me/app",
                               branch: "worktree-fix", registeredAt: "2026-11-19T20:26:58.034Z", lastSeenAt: "2026-11-19T20:42:31.824Z"))
    #expect(s["3000"]?.cwd == nil)
    // Saving keeps the Node shape: nulls for cwd/branch, dates untouched.
    try Store.save(s)
    let text = try String(contentsOf: Store.storeURL, encoding: .utf8)
    #expect(text.contains(#""cwd" : null"#) || text.contains(#""cwd": null"#))
    #expect(text.contains("2026-11-19T20:26:58.034Z"))
  }

  @Test func markSeenRefreshesLabeledPortsOnly() throws {
    try Store.save(["3000": Label(port: 3000, title: "A", lastSeenAt: "2026-01-01T00:00:00.000Z")])
    try Board.markSeen([3000, 3001], now: ISO.date("2026-02-01T00:00:00Z")!)
    #expect(Array(Store.load().keys) == ["3000"])
    #expect(Store.load()["3000"]?.lastSeenAt == "2026-02-01T00:00:00.000Z")
  }

  @Test func parallelUpdatesNeverLoseALabel() throws {
    // The MCP SDK runs tool calls concurrently; every register must survive.
    DispatchQueue.concurrentPerform(iterations: 40) { i in
      _ = try? Store.update { s in
        s[String(5000 + i)] = Label(port: 5000 + i, title: "t\(i)")
        return true
      }
    }
    #expect(Store.load().count == 40)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: Store.homeDir().path).filter { $0.hasSuffix(".tmp") }
    #expect(leftovers.isEmpty)
  }

  @Test func emptyStringsBehaveLikeNode() {
    let now = Date()
    let servers: Labels = [
      "3001": Label(port: 3001, title: "A", cwd: ""),
      "3002": Label(port: 3002, title: "B", registeredAt: ISO.string(now), lastSeenAt: ""),
    ]
    let (entries, prune, _) = Board.merge([Self.live(3001, "/a")], servers, now: now)
    #expect(entries[0].status == .labeled)  // cwd "" is unknown, not a different checkout
    #expect(prune.isEmpty)  // lastSeenAt "" falls back to registeredAt
  }

  // MARK: reservations

  @Test func reserveHasOneWinnerAndExpires() throws {
    #expect(try Reservations.reserve(3005))
    #expect(try !Reservations.reserve(3005))  // a second agent loses
    #expect(Reservations.active() == [3005])
    #expect(try Reservations.reserve(3005, now: Date().addingTimeInterval(Reservations.ttl + 1)))  // expired → takeover
    Reservations.release(3005)
    #expect(Reservations.active().isEmpty)
    #expect(try Reservations.reserve(3005))
    Reservations.release(3005)
  }

  @Test func expiredTakeoverNeverRemovesAFreshReservation() throws {
    try FileManager.default.createDirectory(at: Reservations.dir, withIntermediateDirectories: true)
    let file = Reservations.dir.appendingPathComponent("3006")
    // A caller that saw the file as expired (judged with an old clock) must not remove a fresh one.
    #expect(try Reservations.reserve(3006))
    #expect(!Reservations.removeIfExpired(file, now: Date()))
    #expect(FileManager.default.fileExists(atPath: file.path))
    // A genuinely expired one is removed, and leaves no stray files behind.
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Reservations.ttl - 5)], ofItemAtPath: file.path)
    #expect(Reservations.removeIfExpired(file, now: Date()))
    #expect(try FileManager.default.contentsOfDirectory(atPath: Reservations.dir.path).isEmpty)
    // Many processes' worth of takeovers at once: exactly one wins.
    #expect(try Reservations.reserve(3006))
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Reservations.ttl - 5)], ofItemAtPath: file.path)
    let wins = ManagedAtomicCounter()
    DispatchQueue.concurrentPerform(iterations: 16) { _ in if (try? Reservations.reserve(3006)) == true { wins.add() } }
    #expect(wins.value == 1)
    Reservations.release(3006)
  }

  // MARK: merge / board

  @Test func mergeLabeledUnlabeledStale() {
    let servers: Labels = [
      "3001": Label(port: 3001, title: "Upload retry", cwd: "/a", registeredAt: Self.nowISO),
      "3002": Label(port: 3002, title: "Old feature", cwd: "/old", registeredAt: Self.nowISO),
    ]
    let (entries, _, _) = Board.merge([Self.live(3001, "/a"), Self.live(3002, "/new"), Self.live(3003, "/c")], servers)
    #expect(entries.map(\.port) == [3001, 3002, 3003])
    #expect(entries.map(\.status) == [.labeled, .stale, .unlabeled])
    #expect(entries.map(\.title) == ["Upload retry", nil, nil])
    #expect(entries.map(\.staleTitle) == [nil, "Old feature", nil])
  }

  @Test func dockerPortWithLabelStaysLabeled() {
    let servers: Labels = ["8080": Label(port: 8080, title: "Jellyfin", cwd: nil, registeredAt: Self.nowISO)]
    let (entries, _, _) = Board.merge([Self.live(8080, nil, command: "com.docker.backend", docker: DockerInfo())], servers)
    #expect(entries[0].status == .labeled)
  }

  @Test func mergePassesDockerInfoAndUptime() {
    let (entries, _, _) = Board.merge([Self.live(8080, nil, repo: "balance", command: "com.docker.backend", docker: Self.balanceApi, uptime: 60)], [:])
    #expect(entries[0].docker == Self.balanceApi)
    #expect(entries[0].uptimeSec == 60)
  }

  @Test func getBoardPrunesLabelsUnseenFor24h() throws {
    let now = Date()
    try Store.save([
      "3001": Label(port: 3001, title: "old", registeredAt: ISO.string(now.addingTimeInterval(-Board.pruneAfter - 1))),
      "3002": Label(port: 3002, title: "recent", registeredAt: ISO.string(now.addingTimeInterval(-1))),
    ])
    #expect(Board.get(live: [], now: now).isEmpty)
    #expect(Array(Store.load().keys) == ["3002"])
  }

  @Test func listServersJSONMatchesNodeShape() throws {
    let (entries, _, _) = Board.merge([Self.live(3001, "/a"), Self.live(8080, nil, command: "com.docker.backend", docker: DockerInfo())], [:])
    let data = try JSONEncoder().encode(entries)
    let arr = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    #expect(arr[0]["docker"] as? Bool == false)
    #expect(arr[0]["url"] as? String == "http://localhost:3001")
    #expect(arr[0]["title"] is NSNull)
    #expect((arr[1]["docker"] as? [String: Any])?.isEmpty == true)
  }

  @Test func updateLabelRejectsBlankTitlesAndEmptyUpdates() throws {
    try Store.save(["4910": Label(port: 4910, title: "Keep me", registeredAt: "x")])
    #expect(throws: PortholeError("title cannot be empty (use remove_server to clear a label).")) {
      try Board.updateLabel(port: 4910, title: "   ")
    }
    #expect(throws: PortholeError("Nothing to update: pass title and/or description.")) { try Board.updateLabel(port: 4910) }
    #expect(Store.load()["4910"]?.title == "Keep me")
    #expect(try Board.updateLabel(port: 4910, description: "d").title == "Keep me")
  }

  @Test func removeReportsWhetherALabelExisted() throws {
    try Store.save(["4911": Label(port: 4911, title: "x")])
    #expect(try Board.remove(port: 4911))
    #expect(try !Board.remove(port: 4911))
  }

  // MARK: free ports

  @Test func freePortsSkipsListeningLabeledAndDBPorts() {
    #expect(Board.freePorts(listening: [3000, 3001], labeled: ["3002"], min: 3000, max: 3010, count: 2) == [3003, 3004])
    #expect(Board.freePorts(listening: [], labeled: [], min: 3000, max: 3010, preferred: 3009, count: 3) == [3009, 3010, 3000])
    #expect(Board.freePorts(listening: [], labeled: [], min: 5431, max: 5433, count: 3) == [5431, 5433])
    #expect(Board.freePorts(listening: [], labeled: [], min: 3000, max: 3010, preferred: 80) == [3000])
    #expect(Board.freePorts(listening: [3000], labeled: [], min: 3000, max: 3010, count: 2, reserved: [3001]) == [3002, 3003])
  }

  @Test func suggestFreePortsReservesAndSkipsUnbindable() throws {
    try Config(portMin: 4950, portMax: 4960).save()
    let first = try Board.suggestFreePorts(preferred: 4950, count: 2, isFree: { $0 != 4950 })
    #expect(first == [4951, 4952])
    let second = try Board.suggestFreePorts(preferred: 4950, count: 1, isFree: { $0 != 4950 })
    #expect(second == [4953])  // 4951/4952 are reserved for the first caller
  }

  @Test func bindProbeSeesARealListener() throws {
    let s = socket(AF_INET, SOCK_STREAM, 0)
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET)
    a.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    a.sin_port = 0
    _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    listen(s, 1)
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
    let port = Int(UInt16(bigEndian: a.sin_port))
    #expect(!Ports.isBindable(port))
    // And libproc sees our own listener.
    #expect(Detect.listeners(on: port) == [Int(getpid())])
    // A port with only a TIME_WAIT leftover (server stopped, connection closed) counts as free.
    let c = socket(AF_INET, SOCK_STREAM, 0)
    _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(c, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    let accepted = accept(s, nil, nil)
    close(accepted)  // server side closes first → TIME_WAIT on the server's port
    close(s)
    usleep(50_000)
    close(c)
    #expect(Ports.isBindable(port))
  }

  // MARK: detect

  @Test func isDevCandidateFiltersSystemDBAndRange() {
    #expect(!Detect.isDevCandidate(command: "ControlCenter", port: 7000))
    #expect(!Detect.isDevCandidate(command: "com.docker.backend", port: 5432))
    #expect(Detect.isDevCandidate(command: "node", port: 3001))
    #expect(!Detect.isDevCandidate(command: "node", port: 60009))
    let cfg = Config(ignorePorts: [8000], ignoreCommands: ["claude-science"], portMin: 3000, portMax: 4000)
    #expect(!Detect.isDevCandidate(command: "node", port: 8000, config: cfg))
    #expect(!Detect.isDevCandidate(command: "claude-science", port: 3500, config: cfg))
    #expect(!Detect.isDevCandidate(command: "node", port: 4500, config: cfg))
    #expect(Detect.isDevCandidate(command: "node", port: 3500, config: cfg))
  }

  @Test func filterLivePidsDropsReusedPids() {
    #expect(Detect.filterLivePids([10, 20], [20, 30]) == [20])
    #expect(Detect.filterLivePids([10], []).isEmpty)
  }

  @Test func parseDockerPs() {
    let text = [
      "a1b2c3d4e5f6\tbalance-api-1\tbalance-api\t0.0.0.0:5678->5678/tcp, [::]:5678->5678/tcp, 0.0.0.0:8080->8080/tcp, [::]:8080->8080/tcp\tbalance\tapi",
      "b1b2c3d4e5f6\tbalance-postgres-1\tpostgres:17\t0.0.0.0:5432->5432/tcp\tbalance\tpostgres",
      "c1b2c3d4e5f6\tworker\tredis\t6379/tcp\t\t",
      "d1b2c3d4e5f6\tranged\tnginx\t0.0.0.0:9000-9001->80-81/tcp\t\t",
    ].joined(separator: "\n")
    let m = Docker.parsePs(text)
    #expect(m.keys.sorted() == [5432, 5678, 8080, 9000, 9001])
    #expect(m[8080] == DockerInfo(id: "a1b2c3d4e5f6", container: "balance-api-1", image: "balance-api", project: "balance",
                                  service: "api", workingDir: nil, containerPort: 8080))
    #expect(m[9001]?.containerPort == 81)
    #expect(m[9000]?.project == nil)
    #expect(Docker.parsePs("").isEmpty)
  }

  @Test func parseDockerStartedKeysByShortId() {
    let m = Docker.parseStarted("a1b2c3d4e5f6aaaaaaaa\t2026-11-19T19:19:15.29Z\nbad\tnope\n")
    #expect(m.count == 1)
    #expect(m["a1b2c3d4e5f6"] == ISO.date("2026-11-19T19:19:15.290Z"))
    // Docker writes nanoseconds.
    #expect(ISO.date("2026-11-19T19:19:15.123456789Z") == ISO.date("2026-11-19T19:19:15.123Z"))
  }

  @Test func parseHeadAndHeadBranch() throws {
    #expect(Git.parseHead("ref: refs/heads/feat/x\n") == "feat/x")
    #expect(Git.parseHead("1a2b3c4d5e6f\n") == "detached@1a2b3c4")
    #expect(Git.parseHead("garbage") == nil)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("porthole-head-\(UUID().uuidString)").path
    let fm = FileManager.default
    try fm.createDirectory(atPath: "\(root)/main/.git/worktrees/wt", withIntermediateDirectories: true)
    try "ref: refs/heads/main\n".write(toFile: "\(root)/main/.git/HEAD", atomically: true, encoding: .utf8)
    try "ref: refs/heads/feat/wt\n".write(toFile: "\(root)/main/.git/worktrees/wt/HEAD", atomically: true, encoding: .utf8)
    try fm.createDirectory(atPath: "\(root)/wt/web", withIntermediateDirectories: true)
    try "gitdir: ../main/.git/worktrees/wt\n".write(toFile: "\(root)/wt/.git", atomically: true, encoding: .utf8)
    #expect(Git.headBranch(root: "\(root)/main") == "main")
    #expect(Git.headBranch(root: "\(root)/wt") == "feat/wt")
    #expect(Git.headBranch(root: "\(root)/nope") == nil)
    // info() walks up from a subfolder to the checkout root.
    #expect(Git.info(cwd: "\(root)/wt/web") == GitInfo(branch: "feat/wt", repo: "wt", root: "\(root)/wt"))
    #expect(Git.info(cwd: "/") == GitInfo())
  }

  // MARK: monitor logic

  @Test func planRescansOnlyOnChange() {
    let t = Date(timeIntervalSince1970: 1000)
    let base = MonitorLogic.State(fingerprint: "a", prevFingerprint: "a", dirty: false, lastRender: t)
    let soon = t.addingTimeInterval(0.5)
    #expect(MonitorLogic.plan(base, now: soon) == .init(portsChanged: false, rescan: false, redraw: false))
    var b = base
    b.fingerprint = "b"
    #expect(MonitorLogic.plan(b, now: soon) == .init(portsChanged: true, rescan: true, redraw: true))
    var d = base
    d.dirty = true
    #expect(MonitorLogic.plan(d, now: soon) == .init(portsChanged: false, rescan: true, redraw: true))
    #expect(MonitorLogic.plan(base, now: t.addingTimeInterval(MonitorLogic.redrawInterval)) == .init(portsChanged: false, rescan: false, redraw: true))
    var first = base
    first.prevFingerprint = nil
    #expect(!MonitorLogic.plan(first, now: soon).portsChanged)
  }

  @Test func agedAdvancesUptimes() {
    var a = Entry(port: 1)
    a.uptimeSec = 60
    let b = Entry(port: 2)
    let out = MonitorLogic.aged([a, b], scannedAt: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 120))
    #expect(out.map(\.uptimeSec) == [180, nil])
  }

  @Test func settingsKeyIgnoresLastSeenAt() {
    let a: Labels = ["3000": Label(port: 3000, title: "A", lastSeenAt: "2026-01-01")]
    let b: Labels = ["3000": Label(port: 3000, title: "A", lastSeenAt: "2026-06-01")]
    let c: Labels = ["3000": Label(port: 3000, title: "B", lastSeenAt: "2026-01-01")]
    #expect(MonitorLogic.settingsKey(a, Config()) == MonitorLogic.settingsKey(b, Config()))
    #expect(MonitorLogic.settingsKey(a, Config()) != MonitorLogic.settingsKey(c, Config()))
    #expect(MonitorLogic.settingsKey(a, Config()) != MonitorLogic.settingsKey(a, Config(ignorePorts: [3000])))
  }

  @Test func looksStaleOnBranchSwitchOrMissingDocker() {
    func e(branch: String? = "main", docker: DockerInfo? = nil) -> Entry {
      var x = Entry(port: 3000)
      x.root = "/r"
      x.branch = branch
      x.docker = docker
      return x
    }
    #expect(!MonitorLogic.looksStale([e()], branchOf: { _ in "main" }))
    #expect(MonitorLogic.looksStale([e()], branchOf: { _ in "feat/x" }))
    #expect(!MonitorLogic.looksStale([e()], branchOf: { _ in nil }))
    #expect(!MonitorLogic.looksStale([e(branch: "detached@1a2b3c4d5")], branchOf: { _ in "detached@1a2b3c4" }))
    #expect(MonitorLogic.looksStale([e(branch: "detached@1a2b3c4")], branchOf: { _ in "detached@9f9f9f9" }))
    #expect(MonitorLogic.looksStale([e(docker: DockerInfo())]))
    #expect(!MonitorLogic.looksStale([e(docker: DockerInfo(container: "web-1"))]))
  }

  // MARK: format

  @Test func humanAge() {
    #expect(Format.humanAge(30) == "1m")
    #expect(Format.humanAge(3600) == "1h")
    #expect(Format.humanAge(17640) == "4h 54m")
    #expect(Format.humanAge(200000) == "2d 7h")
    #expect(Format.humanAge(nil as Int?) == nil)
  }

  @Test func wrapKeepsSentencesAndAvoidsOrphans() {
    let lines = Format.wrap("Docker frontend from the main checkout (test/print-blank-fix). Test that printed reports aren't blank.", width: 60)
    #expect(lines.allSatisfy { $0.count <= 60 || !$0.contains(" ") })
    #expect(lines.last!.contains(" "))
    #expect(Format.wrap("Short one. Another.", width: 60) == ["Short one. Another."])
    #expect(Format.wrap("aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj kkkk llll x", width: 60).count == 1)
  }

  @Test func describeForDialogs() {
    func d(_ l: Live) -> String { Format.describe(docker: l.docker, branch: l.branch, repo: l.repo, command: l.command) }
    #expect(d(Self.live(3000, nil, docker: Self.balanceApi)) == "balance · api (container balance-api-1)")
    #expect(d(Self.live(3001, "/x/myapp", repo: "myapp")) == "feat/x · myapp (node)")
    #expect(Format.describe(docker: nil, branch: nil, repo: nil, command: "claude-science") == "claude-science")
    #expect(d(Self.live(8081, nil, docker: DockerInfo())) == "Docker")
  }

  @Test func pickApps() {
    let has: (String) -> Bool = { $0 == "Visual Studio Code" || $0 == "Terminal" }
    #expect(Apps.pick(Config(), isInstalled: has) == AppChoice(editor: "Visual Studio Code", terminal: "Terminal", browser: nil))
    #expect(Apps.pick(Config(editor: "Zed", terminal: "iTerm", browser: "Arc"), isInstalled: has) == AppChoice(editor: "Zed", terminal: "iTerm", browser: "Arc"))
    #expect(Apps.pick(Config(), isInstalled: { $0 == "Google Chrome" }).browser == "Google Chrome")
    #expect(Apps.pick(Config(), isInstalled: { _ in false }) == AppChoice())
  }

  @Test func configParsesLeniently() throws {
    let c = Config(json: ["ignorePorts": [8000, "8001", true], "ignoreCommands": ["x"], "portMin": 3000, "portMax": "9", "editor": "  "])
    #expect(c.ignorePorts == [8000, 8001])
    #expect(c.ignoreCommands == ["x"])
    #expect(c.portMin == 3000 && c.portMax == nil && c.editor == nil)
  }

  @Test func ignoreAndUnignore() throws {
    try Actions.ignore("8000", add: true)
    try Actions.ignore("claude-science", add: true)
    #expect(Config.load().ignorePorts == [8000])
    #expect(Config.load().ignoreCommands == ["claude-science"])
    try Actions.ignore("8000", add: false)
    #expect(Config.load().ignorePorts.isEmpty)
  }

  // MARK: menu

  static func flat(_ nodes: [MenuNode]) -> [MenuNode] { nodes.flatMap { [$0] + flat($0.children) } }

  @Test func menuRowsOpenOnClickAndHaveActions() {
    let (entries, _, _) = Board.merge(
      [Self.live(3001, "/a"), Self.live(8080, nil, command: "com.docker.backend", docker: DockerInfo())],
      ["3001": Label(port: 3001, title: "Upload retry", description: "Adds backoff", cwd: "/a", registeredAt: "x")])
    let menu = Menu.build(entries, MenuContext())
    #expect(Menu.statusTitle(entries) == "2")
    let row = menu[0]
    #expect(row.port == 3001 && row.title == "Upload retry" && row.action == .openURL("http://localhost:3001"))
    #expect(row.children.contains { $0.action == .openURL("http://localhost:3001") && $0.title == "Open http://localhost:3001" })
    #expect(row.children.last?.action == .confirmKill(port: 3001, pids: [4001], title: "Upload retry", describe: "feat/x (node)"))
    #expect(row.children.dropLast().last?.isSeparator == true)  // Kill is last, after a separator
    let docker = menu[1]
    #expect(docker.title == "docker")
    #expect(docker.children.contains { $0.title == "Label this port…" })
    // No container identified (docker ps unavailable) → neither kill nor stop.
    #expect(!docker.children.contains { if case .confirmKill = $0.action { true } else if case .confirmStop = $0.action { true } else { false } })
  }

  @Test func menuDockerRowsShowContainerAndStop() {
    let (entries, _, _) = Board.merge(
      [
        Self.live(8080, nil, command: "com.docker.backend", docker: Self.balanceApi, uptime: 3600),
        Self.live(3000, nil, command: "com.docker.backend",
                  docker: DockerInfo(container: "balance-frontend-1", image: "balance-api", project: "balance", service: "frontend", containerPort: 3000)),
      ],
      ["8080": Label(port: 8080, title: "Main API", cwd: nil, registeredAt: ISO.string(Self.now.addingTimeInterval(-40 * 60)))])
    let menu = Menu.build(entries, MenuContext(now: Self.now))
    let titles = Self.flat(menu).map(\.title)
    #expect(titles.contains("balance · api"))
    #expect(titles.contains("container balance-api-1 · image balance-api"))
    #expect(titles.contains("up 1h · labeled 40m ago"))
    #expect(!titles.contains { $0.contains("com.docker.backend") })
    #expect(menu[1].title == "balance · frontend")
    #expect(menu[1].children.last?.action == .confirmStop(port: 3000, container: "balance-frontend-1", title: nil,
                                                          describe: "balance · frontend (container balance-frontend-1)"))
    #expect(!titles.contains("Kill server…"))
  }

  @Test func menuLabelRenameOpenInAndHiddenCwd() {
    let (entries, _, _) = Board.merge(
      [Self.live(3001, "/a"), Self.live(8000, "/", command: "claude-science")],
      ["3001": Label(port: 3001, title: "A", cwd: "/a", registeredAt: Self.nowISO)])
    var withRoot = entries
    withRoot[0].root = "/repo"
    let menu = Menu.build(withRoot, MenuContext(apps: AppChoice(editor: "Zed", terminal: "Ghostty")))
    let r = menu[0].children
    #expect(r.contains { $0.title == "Rename…" && $0.action == .promptLabel(port: 3001, current: "A", describe: "feat/x (node)", cwd: "/a", branch: "feat/x") })
    #expect(r.contains { $0.action == .openFolder("/repo", app: "Zed") && $0.title == "Open in Zed" })
    #expect(r.contains { $0.action == .openFolder("/repo", app: "Ghostty") })
    #expect(r.contains { $0.action == .openFolder("/repo", app: nil) && $0.title == "Open in Finder" })
    #expect(menu[1].children.contains { $0.title == "Label this port…" })
    #expect(!menu[1].children.contains { $0.title == "/" })
    #expect(!menu[1].children.contains { $0.title.hasPrefix("Open in") })  // no folder → no open-in items
    // Every action item has an icon (except the top-level row and Quit/Launch at login).
    for n in Self.flat(menu.flatMap(\.children)) where n.action != nil && n.action != .toggleLaunchAtLogin {
      #expect(n.symbol != nil, "\(n.title)")
    }
  }

  @Test func menuSettingsAndAbout() {
    let ctx = MenuContext(config: Config(ignorePorts: [8000], ignoreCommands: ["claude-science"]), version: "0.2.0",
                          repoURL: "https://github.com/x/porthole", launchAtLogin: true)
    let menu = Menu.build([], ctx)
    #expect(menu[0].title == "No dev servers running")
    let settings = menu.first { $0.title == "Settings" }!
    #expect(settings.children.contains { $0.title == ":8000  — click to show again" && $0.action == .unhide("8000") })
    #expect(settings.children.contains { $0.action == .unhide("claude-science") })
    #expect(settings.children.contains { $0.title == "Port range: 3000–9999" })
    #expect(settings.children.contains { $0.action == .toggleLaunchAtLogin && $0.checked })
    let about = menu.first { $0.title == "About Porthole" }!
    #expect(about.children.contains { $0.title == "Porthole 0.2.0" })
    #expect(about.children.contains { $0.action == .openLink("https://github.com/x/porthole") })
    #expect(menu.last?.action == .quit)
    let empty = Menu.build([], MenuContext()).first { $0.title == "Settings" }!
    #expect(empty.children.first?.title == "Nothing hidden")
  }
}

final class ManagedAtomicCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var n = 0
  func add() { lock.withLock { n += 1 } }
  var value: Int { lock.withLock { n } }
}
