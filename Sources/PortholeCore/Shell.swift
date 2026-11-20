// Run a command with a timeout and capture its output. Used for the few things that still need a process:
// docker, and `open -a` for editors/terminals.
//
// Built on posix_spawn + poll + waitpid rather than Foundation's Process: Process.waitUntilExit polls the run
// loop and adds ~70 ms to every call, which made `docker ps` 4× slower than the Node version.
import Darwin
import Foundation

public struct ShellResult: Sendable {
  public var status: Int32
  public var stdout: String
  public var stderr: String
}

public enum Shell {
  /// Folders to search for tools like docker. GUI apps and MCP clients often start us with a minimal PATH.
  public static var searchPath: [String] {
    let env = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let extra = [
      "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.docker/bin",
      "/Applications/Docker.app/Contents/Resources/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]
    var seen = Set<String>()
    return (env + extra).filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  public static func which(_ name: String) -> String? {
    if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
    return searchPath.map { ($0 as NSString).appendingPathComponent(name) }
      .first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  /// Runs `cmd` (looked up on `searchPath`). Never throws: a missing tool or a timeout gives status -1.
  /// On timeout the whole process group is killed (so helpers it started can't keep our pipes open) and
  /// whatever output arrived so far is returned.
  @discardableResult
  public static func run(_ cmd: String, _ args: [String], timeout: TimeInterval = 4, input: String? = nil) -> ShellResult {
    guard let path = which(cmd) else { return ShellResult(status: -1, stdout: "", stderr: "\(cmd) not found") }

    var outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1], inPipe: [Int32] = [-1, -1]
    guard pipe(&outPipe) == 0, pipe(&errPipe) == 0, pipe(&inPipe) == 0 else {
      for fd in outPipe + errPipe + inPipe where fd >= 0 { close(fd) }
      return ShellResult(status: -1, stdout: "", stderr: "pipe failed")
    }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
    posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    // Only fds 0–2 reach the child, it gets default signal handling, and it leads its own process group
    // so a timeout can kill everything it started.
    var defaults = sigset_t()
    sigfillset(&defaults)
    posix_spawnattr_setsigdefault(&attr, &defaults)
    var noMask = sigset_t()
    sigemptyset(&noMask)
    posix_spawnattr_setsigmask(&attr, &noMask)
    posix_spawnattr_setpgroup(&attr, 0)
    posix_spawnattr_setflags(
      &attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

    var env = ProcessInfo.processInfo.environment
    env["PATH"] = searchPath.joined(separator: ":")
    let argv = ([path] + args).map { strdup($0) } + [nil]
    let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      for p in argv { free(p) }
      for p in envp { free(p) }
    }

    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, path, &actions, &attr, argv, envp)
    // The child has its own copies now.
    close(inPipe[0])
    close(outPipe[1])
    close(errPipe[1])
    guard spawned == 0 else {
      close(inPipe[1])
      close(outPipe[0])
      close(errPipe[0])
      return ShellResult(status: -1, stdout: "", stderr: String(cString: strerror(spawned)))
    }

    var pending = Array((input ?? "").utf8)[...]
    var stdinFD: Int32 = inPipe[1]
    if pending.isEmpty {
      close(stdinFD)
      stdinFD = -1
    } else {
      _ = fcntl(stdinFD, F_SETFL, fcntl(stdinFD, F_GETFL) | O_NONBLOCK)
      signal(SIGPIPE, SIG_IGN)  // a child that exits without reading stdin must not kill us
    }

    var out = Data(), err = Data()
    var outFD = outPipe[0], errFD = errPipe[0]
    let deadline = Date().addingTimeInterval(timeout)
    var timedOut = false
    var buf = [UInt8](repeating: 0, count: 65536)

    // Write stdin and drain stdout/stderr together, so neither side can fill a pipe and stall.
    while outFD >= 0 || errFD >= 0 || stdinFD >= 0 {
      let remaining = deadline.timeIntervalSinceNow
      if remaining <= 0 {
        timedOut = true
        break
      }
      var fds: [pollfd] = []
      if outFD >= 0 { fds.append(pollfd(fd: outFD, events: Int16(POLLIN), revents: 0)) }
      if errFD >= 0 { fds.append(pollfd(fd: errFD, events: Int16(POLLIN), revents: 0)) }
      if stdinFD >= 0 { fds.append(pollfd(fd: stdinFD, events: Int16(POLLOUT), revents: 0)) }
      let n = poll(&fds, nfds_t(fds.count), Int32(min(remaining * 1000, 1000)) + 1)
      if n < 0 && errno != EINTR { break }
      for f in fds where f.revents != 0 {
        if f.fd == stdinFD {
          let w = pending.withUnsafeBytes { write(stdinFD, $0.baseAddress, $0.count) }
          if w > 0 { pending = pending.dropFirst(w) }
          if pending.isEmpty || (w < 0 && errno != EAGAIN) {
            close(stdinFD)
            stdinFD = -1
          }
          continue
        }
        let r = read(f.fd, &buf, buf.count)
        if r > 0 {
          if f.fd == outFD { out.append(contentsOf: buf[0..<r]) } else { err.append(contentsOf: buf[0..<r]) }
        } else if r == 0 || errno != EINTR {
          close(f.fd)
          if f.fd == outFD { outFD = -1 } else { errFD = -1 }
        }
      }
    }
    for fd in [outFD, errFD, stdinFD] where fd >= 0 { close(fd) }

    var status: Int32 = 0
    if timedOut {
      kill(-pid, SIGKILL)  // the whole group
      kill(pid, SIGKILL)
    } else {
      // Output is closed, so the child is exiting; give it until the deadline (+1 s) before forcing it.
      let reapBy = max(deadline, Date()).addingTimeInterval(1)
      while true {
        let r = waitpid(pid, &status, WNOHANG)
        if r == pid { break }
        if r < 0 {
          if errno == EINTR { continue }
          return ShellResult(status: -1, stdout: String(decoding: out, as: UTF8.self), stderr: "wait failed")
        }
        if Date() > reapBy {
          kill(-pid, SIGKILL)
          kill(pid, SIGKILL)
          timedOut = true
          break
        }
        usleep(1000)
      }
      if !timedOut {
        let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -1  // WIFEXITED / WEXITSTATUS
        return ShellResult(status: code, stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self))
      }
    }
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    return ShellResult(status: -1, stdout: String(decoding: out, as: UTF8.self), stderr: "timed out")
  }
}
