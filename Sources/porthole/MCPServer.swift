// Porthole MCP server (stdio). Lets any MCP-capable coding agent label which feature is running on which port.
// Tool names, schemas and descriptions match the Node version, so agents see no difference.
import Foundation
import MCP
import PortholeCore

enum MCPServer {
  static let instructions =
    "Porthole tracks which feature/branch is running on which localhost port and shows it in the macOS menu bar. "
    + "Whenever you start a local dev server (or the user says one is running), call register_server with its port and a short title "
    + "describing the feature being tested. Before picking a port for a new dev server, call suggest_free_port to avoid collisions. "
    + "Use list_servers to answer \"what is on port X?\"."

  static func port(_ description: String = "localhost port, e.g. 3001") -> Value {
    ["type": "integer", "minimum": 1, "maximum": 65535, "description": .string(description)]
  }

  static func schema(_ properties: [String: Value], required: [String] = []) -> Value {
    var s: [String: Value] = [
      "type": "object", "properties": .object(properties), "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#",
    ]
    if !required.isEmpty { s["required"] = .array(required.map { .string($0) }) }
    return .object(s)
  }

  static let tools: [Tool] = [
    Tool(
      name: "register_server", title: "Register dev server",
      description:
        "Label a running local dev server with the feature it is serving. Branch and working directory are detected automatically. "
        + "Waits up to 10s for the port to start listening. Overwrites any existing label on that port.",
      inputSchema: schema(
        [
          "port": port(),
          "title": [
            "type": "string", "minLength": 1, "maxLength": 80,
            "description": "Short (≤8 words) feature summary, e.g. \"Upload retry flow\"",
          ],
          "description": ["type": "string", "maxLength": 500, "description": "Optional 1–2 sentence detail of what to test"],
        ], required: ["port", "title"])),
    Tool(
      name: "update_server", title: "Update dev server label",
      description: "Change the title and/or description of an already-registered port.",
      inputSchema: schema(
        [
          "port": port(), "title": ["type": "string", "minLength": 1, "maxLength": 80],
          "description": ["type": "string", "maxLength": 500],
        ], required: ["port"])),
    Tool(
      name: "remove_server", title: "Remove dev server label",
      description: "Clear the label for a port (does not stop the server).",
      inputSchema: schema(["port": port()], required: ["port"])),
    Tool(
      name: "list_servers", title: "List dev servers",
      description:
        "List every listening local dev server (ports 3000–9999) with its label, branch, repo folder, uptimeSec and status "
        + "(labeled | unlabeled | stale — stale means a different checkout now owns the port) and root (checkout folder). "
        + "Docker-published ports include docker: {container, image, project, service, containerPort}. Pass port to get just one.",
      inputSchema: schema(["port": port()])),
    Tool(
      name: "suggest_free_port", title: "Suggest free port",
      description:
        "Return free localhost port(s) in the dev range (default 3000–9999) that nothing is listening on and no label claims. "
        + "Call this before starting a new dev server so parallel checkouts do not collide. "
        + "Returned ports are reserved for 2 minutes (other callers will not get them) until you call register_server.",
      inputSchema: schema([
        "preferred": port("Start searching here, e.g. the framework default 3000"),
        "count": ["type": "integer", "minimum": 1, "maximum": 20, "description": "How many ports to return (default 1)"],
      ])),
  ]

  // MARK: argument checks (the SDK doesn't validate against the schema)

  struct Args {
    let raw: [String: Value]

    func int(_ key: String, in range: ClosedRange<Int>, required: Bool = false) throws -> Int? {
      guard let v = raw[key], v != .null else {
        if required { throw PortholeError("\(key) is required") }
        return nil
      }
      let n: Int?
      switch v {
      case .int(let i): n = i
      case .double(let d) where d == d.rounded(): n = Int(exactly: d)
      default: n = nil
      }
      guard let n, range.contains(n) else {
        throw PortholeError("\(key) must be an integer from \(range.lowerBound) to \(range.upperBound)")
      }
      return n
    }

    func string(_ key: String, maxLength: Int, minLength: Int = 0, required: Bool = false) throws -> String? {
      guard let v = raw[key], v != .null else {
        if required { throw PortholeError("\(key) is required") }
        return nil
      }
      guard case .string(let s) = v else { throw PortholeError("\(key) must be a string") }
      guard s.count >= minLength, s.count <= maxLength else {
        throw PortholeError("\(key) must be \(minLength)–\(maxLength) characters")
      }
      return s
    }
  }

  static func json(_ value: some Encodable) throws -> CallTool.Result {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let text = String(decoding: try enc.encode(value), as: UTF8.self)
    return .init(content: [.text(text: text, annotations: nil, _meta: nil)])
  }

  static func call(_ name: String, _ args: Args) async throws -> CallTool.Result {
    switch name {
    case "register_server":
      let port = try args.int("port", in: 1...65535, required: true)!
      let title = try args.string("title", maxLength: 80, minLength: 1, required: true)!
      let description = try args.string("description", maxLength: 500)
      let rec = try await Board.register(port: port, title: title, description: description)
      return try json(["registered": rec])
    case "update_server":
      let port = try args.int("port", in: 1...65535, required: true)!
      let rec = try Board.updateLabel(
        port: port, title: try args.string("title", maxLength: 80, minLength: 1),
        description: try args.string("description", maxLength: 500))
      return try json(["updated": rec])
    case "remove_server":
      let port = try args.int("port", in: 1...65535, required: true)!
      return try json(["removed": try Board.remove(port: port)])
    case "list_servers":
      let only = try args.int("port", in: 1...65535)
      let servers = Board.get().filter { only == nil || $0.port == only }
      return try json(["servers": servers])
    case "suggest_free_port":
      let ports = try Board.suggestFreePorts(
        preferred: try args.int("preferred", in: 1...65535), count: try args.int("count", in: 1...20) ?? 1)
      return try json(["ports": ports])
    default:
      throw PortholeError("Unknown tool: \(name)")
    }
  }

  static func run() async throws {
    let server = Server(
      name: "porthole", version: Porthole.version, instructions: instructions,
      capabilities: .init(tools: .init(listChanged: false)))
    await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
    await server.withMethodHandler(CallTool.self) { params in
      do {
        return try await call(params.name, Args(raw: params.arguments ?? [:]))
      } catch {
        let msg = (error as? PortholeError)?.message ?? error.localizedDescription
        return .init(content: [.text(text: "Error: \(msg)", annotations: nil, _meta: nil)], isError: true)
      }
    }
    try await server.start(transport: StdioTransport())
    await server.waitUntilCompleted()
  }
}
