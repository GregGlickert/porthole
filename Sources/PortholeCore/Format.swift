// Human-readable text for the menu, dialogs and `porthole list`.
import Foundation

public enum Format {
  /// One line, no control characters (labels come from agents and hand edits).
  public static func clean(_ s: String?) -> String {
    let collapsed = (s ?? "").replacingOccurrences(of: #"\s*[\n\r]+\s*"#, with: " / ", options: .regularExpression)
    return collapsed.trimmingCharacters(in: .whitespaces)
  }

  public static func truncate(_ s: String?, _ n: Int) -> String {
    let c = clean(s)
    return c.count > n ? String(c.prefix(n - 1)) + "…" : c
  }

  /// 90 → "1m", 7380 → "2h 3m", 200000 → "2d 7h".
  public static func humanAge(_ sec: Double?) -> String? {
    guard let sec, sec.isFinite, sec >= 0 else { return nil }
    let m = Int(sec / 60)
    let h = m / 60
    let d = h / 24
    if d > 0 { return h % 24 > 0 ? "\(d)d \(h % 24)h" : "\(d)d" }
    if h > 0 { return m % 60 > 0 ? "\(h)h \(m % 60)m" : "\(h)h" }
    return "\(max(1, m))m"
  }

  public static func humanAge(_ sec: Int?) -> String? { humanAge(sec.map(Double.init)) }

  /// "branch · folder", dropping the folder when the branch name already contains it (common with worktrees).
  public static func where2(_ branch: String?, _ repo: String?) -> String {
    if let branch, let repo, !repo.isEmpty, branch.contains(repo) { return branch }
    return [branch, repo].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
  }

  /// "project · service" for compose containers, else the container name.
  public static func dockerWhere(_ d: DockerInfo?) -> String {
    guard let d, d.container != nil || d.project != nil else { return "docker" }
    if let p = d.project, let s = d.service { return "\(p) · \(s)" }
    return d.container ?? d.project ?? "docker"
  }

  /// Where a port runs: Docker project/service, else "branch · folder", else the process name.
  public static func location(_ e: Entry) -> String {
    if e.docker != nil { return dockerWhere(e.docker) }
    let w = where2(e.branch, e.repo)
    return w.isEmpty ? e.command : w
  }

  /// One-line description for dialogs: "balance · frontend (container balance-frontend-1)" or "feat/x · app (node)".
  public static func describe(_ e: Entry) -> String {
    describe(docker: e.docker, branch: e.branch, repo: e.repo, command: e.command)
  }

  public static func describe(docker: DockerInfo?, branch: String?, repo: String?, command: String) -> String {
    if let d = docker {
      guard let c = d.container else { return "Docker" }
      return "\(dockerWhere(d)) (container \(clean(c)))"
    }
    let loc = where2(branch, repo)
    return loc.isEmpty ? clean(command) : "\(loc) (\(clean(command)))"
  }

  /// Wrap text into lines of at most `width` chars: keep sentences together when they fit, otherwise break
  /// on words. Never leaves a final line of one short word.
  public static func wrap(_ text: String, width: Int = 60) -> [String] {
    let sentences = splitSentences(clean(text))
    var lines: [String] = []
    var cur = ""
    func push() {
      if !cur.isEmpty { lines.append(cur) }
      cur = ""
    }
    for sentence in sentences {
      if !cur.isEmpty && cur.count + 1 + sentence.count <= width {
        cur += " " + sentence
        continue
      }
      push()
      for w in sentence.split(whereSeparator: \.isWhitespace) {
        if !cur.isEmpty && cur.count + 1 + w.count > width { push() }
        cur = cur.isEmpty ? String(w) : cur + " " + w
      }
    }
    push()
    // Orphan control: pull a lone short word back onto the previous line.
    if lines.count > 1, let last = lines.last, !last.contains(" "), last.count <= 12 {
      lines.removeLast()
      lines[lines.count - 1] += " " + last
    }
    return lines
  }

  /// Split after . ! ? followed by whitespace.
  static func splitSentences(_ s: String) -> [String] {
    var out: [String] = []
    var cur = ""
    var prevEnd = false
    for ch in s {
      if prevEnd && ch.isWhitespace {
        if !cur.isEmpty { out.append(cur) }
        cur = ""
        prevEnd = false
        continue
      }
      if cur.isEmpty && ch.isWhitespace { continue }
      cur.append(ch)
      prevEnd = ch == "." || ch == "!" || ch == "?"
    }
    if !cur.isEmpty { out.append(cur) }
    return out
  }
}
