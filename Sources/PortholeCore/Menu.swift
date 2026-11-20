// The menu as data: what each row says and does. The app turns this into an NSMenu; tests check it directly.
import Foundation

public enum MenuAction: Equatable, Sendable {
  case openURL(String)
  case copy(String)
  /// Open a folder in an app by name (nil = Finder).
  case openFolder(String, app: String?)
  case promptLabel(port: Int, current: String?, describe: String, cwd: String?, branch: String?)
  case removeLabel(port: Int)
  case hidePort(Int)
  case unhide(String)
  case confirmKill(port: Int, pids: [Int], title: String?, describe: String)
  case confirmStop(port: Int, container: String, title: String?, describe: String)
  case editConfig
  case editLabels
  case openLink(String)
  case refresh
  case toggleLaunchAtLogin
  case installCLI
  case quit
}

public enum MenuStyle: Equatable, Sendable {
  case normal
  /// Gray, regular size (descriptions).
  case secondary
  /// Gray, small (details like folder and PID).
  case detail
}

public struct MenuNode: Equatable, Sendable {
  public var title: String
  public var style: MenuStyle = .normal
  /// SF Symbol name.
  public var symbol: String?
  public var action: MenuAction?
  public var children: [MenuNode] = []
  public var isSeparator = false
  /// Shown before the title in a fixed-width digit column (port rows).
  public var port: Int?
  public var checked = false
  public var keyEquivalent = ""

  public init(
    _ title: String, style: MenuStyle = .normal, symbol: String? = nil, action: MenuAction? = nil,
    children: [MenuNode] = [], port: Int? = nil, checked: Bool = false, keyEquivalent: String = ""
  ) {
    self.title = title
    self.style = style
    self.symbol = symbol
    self.action = action
    self.children = children
    self.port = port
    self.checked = checked
    self.keyEquivalent = keyEquivalent
  }

  public static let separator: MenuNode = {
    var n = MenuNode("")
    n.isSeparator = true
    return n
  }()
}

public struct MenuContext: Sendable {
  public var apps: AppChoice
  public var config: Config
  public var version: String
  public var repoURL: String?
  public var launchAtLogin: Bool
  public var cliInstalled: Bool
  public var now: Date

  public init(
    apps: AppChoice = AppChoice(), config: Config = Config(), version: String = Porthole.version,
    repoURL: String? = Porthole.repoURL, launchAtLogin: Bool = false, cliInstalled: Bool = true, now: Date = Date()
  ) {
    self.apps = apps
    self.config = config
    self.version = version
    self.repoURL = repoURL
    self.launchAtLogin = launchAtLogin
    self.cliInstalled = cliInstalled
    self.now = now
  }
}

public enum Menu {
  /// Text next to the menu bar icon: the number of ports, or nothing.
  public static func statusTitle(_ entries: [Entry]) -> String { entries.isEmpty ? "" : "\(entries.count)" }

  public static func build(_ entries: [Entry], _ ctx: MenuContext) -> [MenuNode] {
    var out: [MenuNode] = []
    if entries.isEmpty { out.append(MenuNode("No dev servers running", style: .secondary)) }
    for e in entries { out.append(row(e, ctx)) }
    out.append(.separator)
    out.append(settings(ctx))
    out.append(about(ctx))
    out.append(MenuNode("Refresh", symbol: "arrow.clockwise", action: .refresh, keyEquivalent: "r"))
    out.append(.separator)
    out.append(MenuNode("Quit Porthole", action: .quit, keyEquivalent: "q"))
    return out
  }

  /// One row per port: click opens it in the browser, hover shows details and actions.
  static func row(_ e: Entry, _ ctx: MenuContext) -> MenuNode {
    let loc = Format.location(e)
    let label = e.status == .labeled ? Format.truncate(e.title, 48) : (loc.isEmpty ? "unlabeled" : Format.truncate(loc, 48))
    var sub: [MenuNode] = []

    let subtitle: String
    switch e.status {
    case .labeled: subtitle = loc
    case .stale: subtitle = "unlabeled (old label: \(Format.truncate(e.staleTitle, 30)))"
    case .unlabeled: subtitle = "unlabeled · \(e.docker != nil ? (e.docker?.image ?? "docker") : e.command)"
    }
    if !subtitle.isEmpty { sub.append(MenuNode(Format.truncate(subtitle, 60), style: .detail)) }
    if e.status == .labeled, let d = e.description, !d.isEmpty {
      sub += Format.wrap(d, width: 60).map { MenuNode($0, style: .secondary) }
      sub.append(.separator)
    }

    var ages: [String] = []
    if let up = Format.humanAge(e.uptimeSec) { ages.append("up \(up)") }
    if e.status == .labeled, let reg = ISO.date(e.registeredAt),
      let ago = Format.humanAge(ctx.now.timeIntervalSince(reg))
    {
      ages.append("labeled \(ago) ago")
    }
    if !ages.isEmpty { sub.append(MenuNode(ages.joined(separator: " · "), style: .detail, symbol: "clock")) }
    if let cwd = e.cwd, cwd != "/" { sub.append(MenuNode(Format.truncate(cwd, 70), style: .detail)) }
    if let d = e.docker, let c = d.container {
      let cport = d.containerPort.flatMap { $0 != e.port ? " → :\($0)" : nil } ?? ""
      sub.append(MenuNode("container \(Format.clean(c))\(cport) · image \(Format.clean(d.image))", style: .detail))
    } else if e.docker == nil {
      sub.append(MenuNode("PID \(e.pids.map(String.init).joined(separator: ", ")) · \(Format.clean(e.command))", style: .detail))
    }

    sub.append(.separator)
    sub.append(MenuNode("Open \(e.url)", symbol: "safari", action: .openURL(e.url)))
    sub.append(MenuNode("Copy URL", symbol: "doc.on.doc", action: .copy(e.url)))
    if let root = e.root {
      sub.append(.separator)
      if let ed = ctx.apps.editor {
        sub.append(MenuNode("Open in \(Format.clean(ed))", symbol: "chevron.left.forwardslash.chevron.right", action: .openFolder(root, app: ed)))
      }
      if let t = ctx.apps.terminal {
        sub.append(MenuNode("Open in \(Format.clean(t))", symbol: "terminal", action: .openFolder(root, app: t)))
      }
      sub.append(MenuNode("Open in Finder", symbol: "folder", action: .openFolder(root, app: nil)))
    }
    let describe = Format.describe(e)
    let current = e.status == .labeled ? e.title : nil
    let prompt = MenuAction.promptLabel(port: e.port, current: current, describe: describe, cwd: e.cwd, branch: e.branch)
    if e.status == .labeled {
      sub.append(MenuNode("Rename…", symbol: "pencil", action: prompt))
    } else {
      sub.append(MenuNode("Label this port…", symbol: "tag", action: prompt))
    }
    if e.status != .unlabeled { sub.append(MenuNode("Remove label", symbol: "tag.slash", action: .removeLabel(port: e.port))) }
    sub.append(MenuNode("Hide this port", symbol: "eye.slash", action: .hidePort(e.port)))
    if e.docker == nil {
      sub.append(.separator)
      sub.append(MenuNode("Kill server…", symbol: "xmark.octagon",
        action: .confirmKill(port: e.port, pids: e.pids, title: current, describe: describe)))
    } else if let c = e.docker?.container {
      // Never kill the PID for Docker ports (it's Docker itself); stop just that container.
      sub.append(.separator)
      sub.append(MenuNode("Stop container…", symbol: "stop.circle",
        action: .confirmStop(port: e.port, container: c, title: current, describe: describe)))
    }
    return MenuNode(label, action: .openURL(e.url), children: sub, port: e.port)
  }

  static func settings(_ ctx: MenuContext) -> MenuNode {
    let cfg = ctx.config
    var sub: [MenuNode] = []
    if cfg.ignorePorts.isEmpty && cfg.ignoreCommands.isEmpty {
      sub.append(MenuNode("Nothing hidden", style: .secondary))
    } else {
      if !cfg.ignorePorts.isEmpty { sub.append(MenuNode("Hidden ports", style: .detail)) }
      for p in cfg.ignorePorts.sorted() {
        sub.append(MenuNode(":\(p)  — click to show again", symbol: "eye.slash", action: .unhide(String(p))))
      }
      if !cfg.ignoreCommands.isEmpty { sub.append(MenuNode("Hidden processes", style: .detail)) }
      for c in cfg.ignoreCommands {
        sub.append(MenuNode("\(Format.clean(c))  — click to show again", symbol: "eye.slash", action: .unhide(c)))
      }
    }
    sub.append(.separator)
    sub.append(MenuNode("Port range: \(cfg.min)–\(cfg.max)", style: .secondary))
    sub.append(MenuNode("Open config file…", symbol: "doc.text", action: .editConfig))
    sub.append(MenuNode("Open labels file…", symbol: "tag", action: .editLabels))
    sub.append(.separator)
    sub.append(MenuNode("Launch at login", action: .toggleLaunchAtLogin, checked: ctx.launchAtLogin))
    sub.append(MenuNode(
      ctx.cliInstalled ? "Reinstall command-line tool…" : "Install command-line tool…", symbol: "terminal",
      action: .installCLI))
    return MenuNode("Settings", symbol: "gearshape", children: sub)
  }

  static func about(_ ctx: MenuContext) -> MenuNode {
    var sub = [
      MenuNode("Porthole \(ctx.version)", style: .secondary),
      MenuNode("Which feature is running on which localhost port.", style: .detail),
    ]
    if let url = ctx.repoURL {
      sub.append(.separator)
      sub.append(MenuNode("View on GitHub", symbol: "link", action: .openLink(url)))
    }
    return MenuNode("About Porthole", symbol: "info.circle", children: sub)
  }
}
