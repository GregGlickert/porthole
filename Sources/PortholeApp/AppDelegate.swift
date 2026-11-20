// Porthole menu bar app: one status item, a live menu, and the actions behind it.
import AppKit
import PortholeCore
import ServiceManagement
import os

let log = Logger(subsystem: "io.github.gregglickert.porthole", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private var statusItem: NSStatusItem!
  private var statusMenu: StatusMenu!
  private var monitor: Monitor!
  private var entries: [Entry] = []
  /// Concurrent: a slow action (docker stop can take a minute) must not hold up Open or Hide on another row.
  private let work = DispatchQueue(label: "porthole.actions", qos: .userInitiated, attributes: .concurrent)

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = statusItem.button {
      button.image = Self.menuBarIcon()
      button.imagePosition = .imageLeft
      button.toolTip = "Porthole"
    }
    statusMenu = StatusMenu(target: self, selector: #selector(runMenuAction(_:)))
    statusMenu.menu.delegate = self
    statusItem.menu = statusMenu.menu
    render()
    monitor = Monitor { [weak self] entries in
      self?.entries = entries
      self?.render()
    }
    monitor.start()
  }

  func applicationWillTerminate(_ notification: Notification) {
    monitor?.stop()
  }

  /// Opening Porthole again (Spotlight, Finder) while it's running just shows the menu.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    statusItem.button?.performClick(nil)
    return false
  }

  func menuWillOpen(_ menu: NSMenu) {
    monitor.poke()
  }

  private func render() {
    statusItem.button?.title = Menu.statusTitle(entries)
    let ctx = MenuContext(
      apps: Apps.pick(), config: Config.load(), launchAtLogin: SMAppService.mainApp.status == .enabled,
      cliInstalled: CLITool.isInstalled)
    statusMenu.update(Menu.build(entries, ctx))
  }

  static func menuBarIcon() -> NSImage? {
    if let url = Bundle.main.url(forResource: "porthole-icon", withExtension: "png"), let img = NSImage(contentsOf: url) {
      img.size = NSSize(width: 18, height: 18)
      img.isTemplate = true
      return img
    }
    return NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Porthole")
  }

  // MARK: - actions

  @objc func runMenuAction(_ sender: NSMenuItem) {
    guard let action = (sender.representedObject as? ActionBox)?.action else { return }
    log.info("menu action: \(String(describing: action), privacy: .public)")
    switch action {
    case .openURL(let url):
      background { Apps.openURL(url) }
    case .copy(let url):
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(url, forType: .string)
    case .openFolder(let path, let app):
      if let app {
        background { try Apps.open(path, in: app) }
      } else {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
      }
    case .openLink(let link):
      if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    case .promptLabel(let port, let current, let describe, let cwd, let branch):
      promptLabel(port: port, current: current, describe: describe, cwd: cwd, branch: branch)
    case .removeLabel(let port):
      background { try Board.remove(port: port) }
    case .hidePort(let port):
      background { try Actions.ignore(String(port), add: true) }
    case .unhide(let target):
      background { try Actions.ignore(target, add: false) }
    case .confirmKill(let port, let pids, let title, let describe):
      let what = title.map { "\"\($0)\" — " } ?? ""
      let pidList = pids.map(String.init).joined(separator: ", ")
      if confirm("Kill \(what)\(describe) on :\(port)?", info: "PID \(pidList)", button: "Kill") {
        background { try Actions.kill(port: port, pids: pids) }
      }
    case .confirmStop(let port, let container, let title, let describe):
      let what = title.map { "\"\($0)\" — " } ?? ""
      if confirm("Stop \(what)\(describe) on :\(port)?", info: "Runs: docker stop \(container)", button: "Stop") {
        background { try Actions.stopContainer(port: port, container: container) }
      }
    case .editConfig, .editLabels:
      do {
        let url = try Actions.editableFile(labels: action == .editLabels)
        background { Shell.run("/usr/bin/open", ["-t", url.path]) }
      } catch { show(error) }
    case .refresh:
      monitor.refresh()
    case .toggleLaunchAtLogin:
      toggleLaunchAtLogin()
    case .installCLI:
      installCLI()
    case .quit:
      NSApp.terminate(nil)
    }
  }

  /// Run `body` off the main thread, then rescan; show any error in an alert.
  private func background(_ body: @escaping @Sendable () throws -> Void) {
    let monitor = monitor!
    work.async {
      do {
        try body()
      } catch {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.show(error) } }
      }
      monitor.refresh()
    }
  }

  private func promptLabel(port: Int, current: String?, describe: String, cwd: String?, branch: String?) {
    guard let text = Dialogs.ask(
      "Label for :\(port)", info: "\(describe)\n\nLeave empty to remove the label.", defaultAnswer: current ?? "")
    else { return }
    let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let monitor = monitor!
    Task.detached {
      do {
        if title.isEmpty {
          try Board.remove(port: port)
        } else if current != nil {
          try Board.updateLabel(port: port, title: title)
        } else {
          try await Board.register(port: port, title: title, wait: 0, known: (cwd, branch))
        }
      } catch {
        await MainActor.run { self.show(error) }
      }
      monitor.refresh()
    }
  }

  private func confirm(_ message: String, info: String, button: String) -> Bool {
    Dialogs.confirm(message, info: info, button: button)
  }

  private func show(_ error: Error) {
    Dialogs.error((error as? PortholeError)?.message ?? error.localizedDescription)
  }

  private func toggleLaunchAtLogin() {
    let service = SMAppService.mainApp
    do {
      if service.status == .enabled {
        try service.unregister()
      } else {
        try service.register()
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
      }
    } catch {
      Dialogs.error("Couldn't change Launch at login: \(error.localizedDescription)")
    }
    render()
  }

  private func installCLI() {
    do {
      let path = try CLITool.install()
      Dialogs.info(
        "Command-line tool installed",
        info: "\(path) now points at this copy of Porthole. MCP clients configured with that path keep working.")
    } catch { show(error) }
    render()
  }
}

/// ~/.porthole/bin/porthole: the path MCP clients are configured with. A symlink to the CLI inside the app.
@MainActor
enum CLITool {
  static var link: URL { Store.homeDir().appendingPathComponent("bin/porthole") }
  static var bundled: URL? {
    let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/porthole")
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
  }

  static var isInstalled: Bool {
    guard let bundled, let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return false }
    return URL(fileURLWithPath: dest).standardizedFileURL == bundled.standardizedFileURL
  }

  static func install() throws -> String {
    guard let bundled else { throw PortholeError("This copy of Porthole doesn't include the porthole command (run it from Porthole.app).") }
    let fm = FileManager.default
    try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    if (try? fm.attributesOfItem(atPath: link.path)) != nil { try fm.removeItem(at: link) }
    try fm.createSymbolicLink(at: link, withDestinationURL: bundled)
    return link.path
  }
}
