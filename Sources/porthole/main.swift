// porthole — which feature is on which localhost port. CLI for terminals, plus `porthole mcp` for agents.
import ArgumentParser
import Foundation
import PortholeCore

struct PortArg: ExpressibleByArgument {
  let value: Int
  init?(argument: String) {
    guard let n = Int(argument), (1...65535).contains(n) else { return nil }
    value = n
  }
  static var defaultCompletionKind: CompletionKind { .default }
}

@main
struct PortholeCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "porthole",
    abstract: "Which feature is running on which localhost port.",
    version: Porthole.version,
    subcommands: [
      List.self, Register.self, Remove.self, Open.self, Copy.self, Kill.self, Ignore.self, Unignore.self,
      Ignored.self, OpenEditor.self, OpenTerminal.self, Edit.self, MCP.self,
    ],
    defaultSubcommand: List.self)
}

func fail(_ error: Error) -> Never {
  let msg = (error as? PortholeError)?.message ?? error.localizedDescription
  FileHandle.standardError.write(Data((msg + "\n").utf8))
  exit(1)
}

struct List: ParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Show live dev servers and their labels.")
  @Flag(help: "Print JSON (the same shape as the list_servers MCP tool).") var json = false

  func run() throws {
    let entries = Board.get()
    if json {
      let enc = JSONEncoder()
      enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      print(String(decoding: try enc.encode(["servers": entries]), as: UTF8.self))
      return
    }
    if entries.isEmpty { return print("No dev servers running.") }
    for e in entries {
      let loc = e.docker != nil ? "docker · \(Format.dockerWhere(e.docker))" : Format.location(e)
      let label: String
      switch e.status {
      case .labeled: label = e.title ?? ""
      case .stale: label = "(stale label: \(e.staleTitle ?? ""))"
      case .unlabeled: label = "(unlabeled)"
      }
      print(":\(String(e.port).padding(toLength: 5, withPad: " ", startingAt: 0))  \(label.padding(toLength: max(36, label.count), withPad: " ", startingAt: 0))  \(loc)")
      if let d = e.description { print("        \(d)") }
    }
  }
}

struct Register: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Label the server on <port>.")
  @Argument var port: PortArg
  @Argument var title: String
  @Argument(parsing: .remaining) var description: [String] = []

  func run() async throws {
    do {
      let rec = try await Board.register(
        port: port.value, title: title, description: description.isEmpty ? nil : description.joined(separator: " "),
        wait: 3)
      print("Registered :\(rec.port) — \(rec.title)\(rec.branch.map { " (\($0))" } ?? "")")
    } catch { fail(error) }
  }
}

struct Remove: ParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Clear the label on <port>.")
  @Argument var port: PortArg
  func run() throws {
    do { print(try Board.remove(port: port.value) ? "Removed." : "No label for that port.") } catch { fail(error) }
  }
}

struct Open: ParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Open http://localhost:<port> (Chrome, else the default browser).")
  @Argument var port: PortArg
  func run() { Apps.openURL("http://localhost:\(port.value)") }
}

struct Copy: ParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Copy http://localhost:<port> to the clipboard.")
  @Argument var port: PortArg
  func run() { Shell.run("/usr/bin/pbcopy", [], input: "http://localhost:\(port.value)") }
}

struct Kill: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "SIGTERM the process on <port> (docker stop for containers).")
  @Argument var port: PortArg
  @Argument(help: "Only these comma-separated PIDs, if they're still listening on <port>.") var pids: String?

  func run() throws {
    do {
      var list: [Int]?
      // Like Node: "" or "-" means "whatever is on the port"; empty list items are invalid.
      if let pids, pids != "-", !pids.isEmpty {
        let parsed = pids.split(separator: ",", omittingEmptySubsequences: false).map { Int($0) }
        guard parsed.allSatisfy({ ($0 ?? 0) > 0 }) else { throw PortholeError("Invalid PID list: \(pids)") }
        list = parsed.compactMap { $0 }
      }
      print(try Actions.kill(port: port.value, pids: list))
    } catch { fail(error) }
  }
}

struct Ignore: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Hide a port or a process name (e.g. claude-science) from the board.")
  @Argument var target: String
  func run() throws {
    do { print(try Actions.ignore(target, add: true)) } catch { fail(error) }
  }
}

struct Unignore: ParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Undo ignore.")
  @Argument var target: String
  func run() throws {
    do { print(try Actions.ignore(target, add: false)) } catch { fail(error) }
  }
}

struct Ignored: ParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Show the ignore list (~/.porthole/config.json).")
  func run() {
    let c = Config.load()
    let ports = c.ignorePorts.map(String.init).joined(separator: ", ")
    let cmds = c.ignoreCommands.joined(separator: ", ")
    print("ports: \(ports.isEmpty ? "(none)" : ports)\ncommands: \(cmds.isEmpty ? "(none)" : cmds)")
  }
}

/// Folder for "Open in …": the git checkout root (or the compose project folder for Docker).
func openFolder(_ port: Int, kind: String, dir: String?) throws {
  var dir = dir
  if dir == nil {
    guard let l = Board.findLive(port) else { throw PortholeError("Nothing listening on \(port).") }
    guard let root = l.root else { throw PortholeError("No folder known for :\(port).") }
    dir = root
  }
  let apps = Apps.pick()
  guard let app = kind == "editor" ? apps.editor : apps.terminal else {
    let example = kind == "editor" ? "Visual Studio Code" : "Terminal"
    throw PortholeError("No \(kind) found. Set \"\(kind)\" in ~/.porthole/config.json, e.g. \"\(example)\".")
  }
  try Apps.open(dir!, in: app)
}

struct OpenEditor: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "open-editor", abstract: "Open the server's checkout in your editor (config: \"editor\").")
  @Argument var port: PortArg
  @Argument var dir: String?
  func run() throws {
    do { try openFolder(port.value, kind: "editor", dir: dir) } catch { fail(error) }
  }
}

struct OpenTerminal: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "open-terminal", abstract: "Open a terminal in the server's checkout (config: \"terminal\").")
  @Argument var port: PortArg
  @Argument var dir: String?
  func run() throws {
    do { try openFolder(port.value, kind: "terminal", dir: dir) } catch { fail(error) }
  }
}

struct Edit: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Open ~/.porthole/config.json or servers.json in your text editor.")
  @Argument(help: "config or labels") var which: String = "config"
  func run() throws {
    do {
      let url = try Actions.editableFile(labels: which == "labels")
      Shell.run("/usr/bin/open", ["-t", url.path])
    } catch { fail(error) }
  }
}

struct MCP: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Run the MCP server on stdio (for coding agents).")
  func run() async throws { try await MCPServer.run() }
}
