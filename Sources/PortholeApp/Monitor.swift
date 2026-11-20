// The live menu's engine: a cheap port fingerprint every 5 s, a full scan only when something changed.
// All state lives on one serial queue; results are delivered on the main thread.
import Foundation
import PortholeCore

final class Monitor: @unchecked Sendable {
  private let queue = DispatchQueue(label: "porthole.monitor", qos: .utility)
  private var state = MonitorLogic.State()
  private var entries: [Entry] = []
  private var scannedAt = Date.distantPast
  private var lastSeenWrite = Date.distantPast
  private var shownSettings: String?
  private var timer: DispatchSourceTimer?
  private var watcher: DispatchSourceFileSystemObject?
  private var stopped = false
  /// Re-read only when the settings files change, not on every 5 s tick.
  private var config = Config.load()
  /// Modification time + size of servers.json and config.json at the last check.
  private var filesSignature = ""
  private var debounce: DispatchWorkItem?
  private let onUpdate: @MainActor ([Entry]) -> Void

  init(onUpdate: @escaping @MainActor ([Entry]) -> Void) {
    self.onUpdate = onUpdate
  }

  func start() {
    queue.async { [self] in
      watch()
      let t = DispatchSource.makeTimerSource(queue: queue)
      t.schedule(deadline: .now(), repeating: MonitorLogic.pollInterval, leeway: .milliseconds(500))
      t.setEventHandler { [weak self] in self?.tick() }
      timer = t
      t.resume()
    }
  }

  /// Called on quit. Async, so quitting never waits for a scan in progress (docker can take seconds).
  func stop() {
    queue.async { [self] in
      stopped = true
      timer?.cancel()
      timer = nil
      watcher?.cancel()
      watcher = nil
    }
  }

  /// Rescan now (after a menu action, or Refresh).
  func refresh() {
    queue.async { [self] in
      config = Config.load()
      state.dirty = true
      tick()
    }
  }

  /// Cheap check now (the menu is opening): rescans only if ports changed.
  func poke() {
    queue.async { [self] in tick() }
  }

  // MARK: - watching ~/.porthole

  /// Labels and config are replaced by rename, which is a write to the folder, so watching the folder is enough.
  /// Reservations live in a subfolder and don't affect the menu, so they don't wake us.
  private func watch() {
    let dir = Store.homeDir()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard watcher == nil, !stopped else { return }
    let fd = open(dir.path, O_EVTONLY)
    guard fd >= 0 else {
      queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.watch() }  // retry until it exists
      return
    }
    let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
    src.setEventHandler { [weak self, weak src] in
      guard let self, let src else { return }
      // The folder itself was deleted or moved (rm -rf, a dotfiles tool): our fd now points at the old one,
      // so watch the new folder instead.
      if !src.data.intersection([.rename, .delete]).isEmpty {
        src.cancel()
        self.watcher = nil
        self.queue.asyncAfter(deadline: .now() + 1) { self.watch() }
      }
      self.settingsMayHaveChanged()
    }
    src.setCancelHandler { close(fd) }
    watcher = src
    src.resume()
  }

  private func settingsMayHaveChanged() {
    debounce?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      config = Config.load()
      if MonitorLogic.settingsKey(Store.load(), config) == shownSettings { return }  // only lastSeenAt changed
      state.dirty = true
      tick()
    }
    debounce = work
    queue.asyncAfter(deadline: .now() + .milliseconds(200), execute: work)
  }

  // MARK: - tick

  /// The folder watcher sees files being replaced (how Porthole and most tools save), but not an in-place save
  /// (nano, `>>`, some editors). Two stat calls per tick catch those.
  private func checkSettingsFiles() {
    let sig = [Store.storeURL, Store.configURL].map { url -> String in
      var st = stat()
      guard stat(url.path, &st) == 0 else { return "-" }
      return "\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec):\(st.st_size)"
    }.joined(separator: "|")
    guard sig != filesSignature else { return }
    filesSignature = sig
    config = Config.load()
    if MonitorLogic.settingsKey(Store.load(), config) != shownSettings { state.dirty = true }
  }

  private func tick() {
    checkSettingsFiles()
    let now = Date()
    state.prevFingerprint = state.fingerprint
    let rows = Detect.listeners()
    state.fingerprint = Detect.fingerprint(rows, config: config)
    let p = MonitorLogic.plan(state, now: now)
    var rescan = p.rescan
    if !rescan && p.redraw && MonitorLogic.looksStale(entries) { rescan = true }
    if rescan {
      state.dirty = false
      // Labeled servers that just stopped were live until now; record that before the scan forgets them.
      if p.portsChanged { touchSeen(now) }
      let board = Board.board(live: Detect.scan(config: config, now: now, rows: rows), now: now)
      entries = board.entries
      // Taken from what the scan left on disk, so its own prune/lastSeenAt writes don't trigger another rescan.
      shownSettings = MonitorLogic.settingsKey(board.labels, config)
      scannedAt = Date()
    } else if p.redraw && now.timeIntervalSince(lastSeenWrite) >= MonitorLogic.seenEvery {
      touchSeen(now)
    }
    if rescan || p.redraw {
      state.lastRender = Date()
      let shown = MonitorLogic.aged(entries, scannedAt: scannedAt, now: state.lastRender)
      let onUpdate = onUpdate
      DispatchQueue.main.async { MainActor.assumeIsolated { onUpdate(shown) } }
    }
  }

  /// Best effort: a failed write (bad JSON, read-only disk) must not stop the rescan that follows.
  private func touchSeen(_ now: Date) {
    lastSeenWrite = now
    try? Board.markSeen(entries.filter { $0.status == .labeled }.map(\.port), now: now)
  }
}
