// Branch and checkout root of a folder, read from .git directly (no git process).
import Foundation

public struct GitInfo: Equatable, Sendable {
  public var branch: String?
  public var repo: String?
  public var root: String?
}

public enum Git {
  /// Pure: branch name from a .git/HEAD file's text ("detached@<sha7>" when detached), or nil.
  public static func parseHead(_ text: String) -> String? {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.hasPrefix("ref:") {
      let ref = t.dropFirst(4).trimmingCharacters(in: .whitespaces)
      guard ref.hasPrefix("refs/heads/") else { return nil }
      let name = String(ref.dropFirst("refs/heads/".count))
      return name.isEmpty ? nil : name
    }
    let isSha = t.count >= 7 && t.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    return isSha ? "detached@\(t.prefix(7))" : nil
  }

  /// The git dir for a checkout root: `<root>/.git`, or where a worktree's `.git` file points.
  static func gitDir(root: String) -> String? {
    let dotGit = (root as NSString).appendingPathComponent(".git")
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) else { return nil }
    if isDir.boolValue { return dotGit }
    guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
      let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
    else { return nil }
    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
    let resolved = path.hasPrefix("/") ? path : (root as NSString).appendingPathComponent(path)
    return (resolved as NSString).standardizingPath
  }

  /// Current branch of the checkout at `root`, or nil if unknown.
  public static func headBranch(root: String?) -> String? {
    guard let root, let dir = gitDir(root: root),
      let head = try? String(contentsOfFile: (dir as NSString).appendingPathComponent("HEAD"), encoding: .utf8)
    else { return nil }
    return parseHead(head)
  }

  /// Nearest folder at or above `cwd` that has a `.git` entry.
  public static func root(of cwd: String) -> String? {
    var dir = (cwd as NSString).standardizingPath
    while true {
      if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) { return dir }
      let parent = (dir as NSString).deletingLastPathComponent
      if parent == dir || parent.isEmpty { return nil }
      dir = parent
    }
  }

  /// Like `git rev-parse --abbrev-ref HEAD --show-toplevel`: branch, repo folder name and root.
  public static func info(cwd: String?) -> GitInfo {
    guard let cwd, cwd != "/" else { return GitInfo() }
    guard let root = root(of: cwd) else {
      return GitInfo(branch: nil, repo: (cwd as NSString).lastPathComponent, root: nil)
    }
    return GitInfo(branch: headBranch(root: root), repo: (root as NSString).lastPathComponent, root: root)
  }
}
