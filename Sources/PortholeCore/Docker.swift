// Docker-published ports: which container is behind each host port (via the docker CLI).
import Foundation

/// Container behind a published port. All fields nil means "Docker, but `docker ps` was unavailable".
public struct DockerInfo: Equatable, Sendable {
  public var id: String?
  public var container: String?
  public var image: String?
  public var project: String?
  public var service: String?
  public var workingDir: String?
  public var containerPort: Int?
  public var uptimeSec: Int?

  public init(
    id: String? = nil, container: String? = nil, image: String? = nil, project: String? = nil,
    service: String? = nil, workingDir: String? = nil, containerPort: Int? = nil, uptimeSec: Int? = nil
  ) {
    self.id = id
    self.container = container
    self.image = image
    self.project = project
    self.service = service
    self.workingDir = workingDir
    self.containerPort = containerPort
    self.uptimeSec = uptimeSec
  }
}

public enum Docker {
  static let format =
    "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Label \"com.docker.compose.project\"}}\t{{.Label \"com.docker.compose.service\"}}"
    + "\t{{.Label \"com.docker.compose.project.working_dir\"}}"

  static let portRe = try! NSRegularExpression(pattern: #":(\d+)(?:-(\d+))?->(\d+)(?:-\d+)?/tcp$"#)

  /// Parse `docker ps --format <format>` into [hostPort: info].
  /// Ports look like `0.0.0.0:8080->8080/tcp, [::]:8080->8080/tcp` or ranges `0.0.0.0:8000-8001->8000-8001/tcp`.
  public static func parsePs(_ text: String) -> [Int: DockerInfo] {
    var map: [Int: DockerInfo] = [:]
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
      let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      func field(_ i: Int) -> String? { i < f.count && !f[i].isEmpty ? f[i] : nil }
      for part in (field(3) ?? "").split(separator: ",") {
        let s = part.trimmingCharacters(in: .whitespaces)
        guard let m = portRe.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { continue }
        func group(_ i: Int) -> Int? { Range(m.range(at: i), in: s).flatMap { Int(s[$0]) } }
        guard let lo = group(1), let cport = group(3) else { continue }
        let hi = group(2) ?? lo
        guard hi >= lo else { continue }
        for p in lo...hi where map[p] == nil {
          map[p] = DockerInfo(
            id: field(0), container: field(1), image: field(2), project: field(4), service: field(5),
            workingDir: field(6), containerPort: cport + (p - lo))
        }
      }
    }
    return map
  }

  /// Parse `docker inspect -f '{{.Id}}\t{{.State.StartedAt}}'` into [shortId: startedAt].
  public static func parseStarted(_ text: String) -> [String: Date] {
    var map: [String: Date] = [:]
    for line in text.split(separator: "\n") {
      let f = line.trimmingCharacters(in: .whitespaces).split(separator: "\t").map(String.init)
      guard f.count >= 2, !f[0].isEmpty, let t = ISO.date(f[1]) else { continue }
      map[String(f[0].prefix(12))] = t
    }
    return map
  }

  /// Container info per published host port; empty if docker is missing or not running.
  public static func ports(now: Date = Date()) -> [Int: DockerInfo] {
    var ports = parsePs(Shell.run("docker", ["ps", "--format", format]).stdout)
    let ids = Array(Set(ports.values.compactMap(\.id))).sorted()
    if !ids.isEmpty {
      let started = parseStarted(Shell.run("docker", ["inspect", "-f", "{{.Id}}\t{{.State.StartedAt}}"] + ids).stdout)
      for (p, c) in ports {
        guard let id = c.id, let t = started[String(id.prefix(12))] else { continue }
        ports[p]?.uptimeSec = max(0, Int(now.timeIntervalSince(t).rounded()))
      }
    }
    return ports
  }

  public static func stop(_ container: String) throws {
    let r = Shell.run("docker", ["stop", container], timeout: 60)
    guard r.status == 0 else {
      let why = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      throw PortholeError("Could not stop container \(container): \(why.isEmpty ? "docker stop failed" : why)")
    }
  }
}
