import Darwin
import Foundation

struct GitHubPlan {
  var approval: Bool
  var graphql: Bool
  var pair: String
  var remote: String?
  var refspec: String?
  var flags: [String] = []
  static let reads: Set<String> = [
    "auth status", "pr list", "pr view", "pr diff", "pr checks", "pr status", "issue list",
    "issue view", "issue status", "repo view", "repo list", "run list", "run view", "workflow list",
    "workflow view", "release list", "release view", "search repos", "search issues", "search prs",
    "search commits", "search code", "status",
  ]
  static let writes: Set<String> = [
    "pr create", "pr comment", "pr edit", "pr ready", "issue create", "issue comment", "issue edit",
  ]
  static func matches(_ value: String, _ expression: String) -> Bool {
    value.range(of: expression, options: .regularExpression) != nil
  }
  init(_ args: [String]) throws {
    guard !args.isEmpty, args.count <= 128,
      args.allSatisfy({ $0.utf8.count <= 16000 && !$0.contains("\0") && !$0.contains("\r") })
    else { throw SideportError("Invalid GitHub arguments") }
    if args[0] == "git" {
      guard args.count >= 4, args[1] == "push" else {
        throw SideportError("Use an explicit HTTPS git push")
      }
      let allowed: Set<String> = [
        "--dry-run", "--porcelain", "--force", "-f", "--force-with-lease", "--delete", "-d",
      ]
      let flags = Array(args.dropFirst(2)).filter { $0.hasPrefix("-") }
      guard flags.allSatisfy(allowed.contains) else { throw SideportError("Unsupported push flag") }
      let positional = Array(args.dropFirst(2)).filter { !$0.hasPrefix("-") }
      guard positional.count == 2, Self.matches(positional[0], #"^[A-Za-z0-9_.][A-Za-z0-9_.-]*$"#)
      else { throw SideportError("Use git push REMOTE SOURCE:refs/heads/BRANCH") }
      let ref = positional[1]
      guard
        Self.matches(
          ref,
          #"^\+?(?:HEAD|[A-Za-z0-9_][A-Za-z0-9_./-]*)?:refs/heads/[A-Za-z0-9_][A-Za-z0-9_./-]*$"#),
        !ref.contains(".."), !ref.contains("//"), !ref.hasSuffix("/"), !ref.hasSuffix(".lock"),
        !flags.contains(where: { ["--delete", "-d"].contains($0) }) || ref.hasPrefix(":")
      else { throw SideportError("Invalid explicit branch refspec") }
      approval =
        flags.contains(where: { !["--dry-run", "--porcelain"].contains($0) }) || ref.hasPrefix("+")
        || ref.hasPrefix(":")
        || Self.matches(ref, #":refs/heads/(main|master|release|production)$"#)
      graphql = false
      pair = "git push"
      remote = positional[0]
      refspec = ref
      self.flags = flags
      return
    }
    let pair = args.prefix(2).joined(separator: " ")
    let blocked: Set<String> = [
      "alias", "extension", "config", "copilot", "codespace", "ssh-key", "gpg-key", "secret",
      "variable",
    ]
    guard !args[0].hasPrefix("-"), !blocked.contains(args[0]),
      !["auth token", "auth login", "auth logout", "auth refresh", "auth switch", "auth setup-git"]
        .contains(pair)
    else { throw SideportError("Credential export and account configuration are not exposed") }
    for arg in args {
      guard
        !Self.matches(
          arg,
          #"^(--hostname|--host|--web|--editor|--verbose|--show-token|--browser|--git-protocol|--insecure-storage)(=|$)"#
        ), arg != "-w", arg != "-e", !(pair == "auth status" && arg == "-t"),
        !(args[0] == "api" && Self.matches(arg, #"^https?://"#))
      else {
        throw SideportError(
          "Host overrides, credential output and interactive launches are blocked")
      }
    }
    self.pair = pair
    graphql = args[0] != "api"
    if args[0] == "api" {
      guard let endpoint = args.dropFirst().first(where: { !$0.hasPrefix("-") }),
        !endpoint.contains(".."), !Self.matches(endpoint, #"[\\\x00-\x20]|://"#)
      else { throw SideportError("Use a relative GitHub API endpoint") }
      var method =
        args.contains(where: { Self.matches($0, #"^(-[fF]|--raw-field|--field|--input)"#) })
        ? "POST" : "GET"
      for i in args.indices {
        if ["-X", "--method"].contains(args[i]), i + 1 < args.count {
          method = args[i + 1].uppercased()
        } else if args[i].hasPrefix("--method=") {
          method = String(args[i].dropFirst(9)).uppercased()
        } else if args[i].hasPrefix("-X") {
          method = String(args[i].dropFirst(2)).uppercased()
        }
      }
      approval =
        !["GET", "HEAD"].contains(method)
        || endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "graphql"
      return
    }
    if pair == "pr create" {
      for flag in ["--head", "--title"] {
        guard args.contains(where: { $0 == flag || $0.hasPrefix(flag + "=") }) else {
          throw SideportError("PR creation requires explicit head, title and body")
        }
      }
      guard
        args.contains(where: {
          $0 == "--body" || $0 == "--body-file" || $0.hasPrefix("--body=")
            || $0.hasPrefix("--body-file=")
        })
      else { throw SideportError("PR creation requires explicit head, title and body") }
    }
    approval =
      !Self.reads.contains(pair) && !Self.reads.contains(args[0]) && !Self.writes.contains(pair)
  }
  static func simple(_ command: String) throws -> [String]? {
    guard matches(command, #"^\s*(gh|/opt/homebrew/bin/gh|/usr/local/bin/gh)(\s|$)"#) else {
      return nil
    }
    var words: [String] = []
    var word = ""
    var quote: Character?
    var active = false
    for c in command.trimmingCharacters(in: .whitespacesAndNewlines) {
      if let q = quote {
        if c == q {
          quote = nil
        } else {
          guard !"\\`$".contains(c) else {
            throw SideportError("Use run_github for shell expansions")
          }
          word.append(c)
        }
        active = true
      } else if c == "\"" || c == "'" {
        quote = c
        active = true
      } else if c == "\n" || c == "\r" {
        throw SideportError("Use run_github for multiline arguments")
      } else if c.isWhitespace {
        if active {
          words.append(word)
          word = ""
          active = false
        }
      } else {
        guard !";&|<>$`\\()\n".contains(c) else {
          throw SideportError("Use run_github for composed authenticated commands")
        }
        word.append(c)
        active = true
      }
    }
    guard quote == nil else { throw SideportError("Unterminated quote") }
    if active { words.append(word) }
    return Array(words.dropFirst())
  }
}
final class NativeGitHub {
  let runtime: RuntimeSupport
  let compatible: CompatibleGitHub
  let approvals: LocalApprovals
  init(_ runtime: RuntimeSupport, _ approvals: LocalApprovals) {
    self.runtime = runtime
    compatible = CompatibleGitHub(runtime)
    self.approvals = approvals
  }
  func call(_ arguments: JSONObject, cwd: String, grants: [Grant]) async throws -> JSONObject {
    guard let args = arguments["args"] as? [String] else {
      throw SideportError("Provide GitHub arguments")
    }
    let plan = try GitHubPlan(args)
    if plan.approval {
      guard let reason = arguments["approval_reason"] as? String, !reason.isEmpty else {
        return textResult(
          [
            "status": "approval_required",
            "hint":
              "Supply approval_reason to request a local decision for this exact remote operation",
          ], error: true)
      }
      guard
        try await approvals.capability(
          "shell_command",
          [
            "command": args.joined(separator: " "), "cwd": cwd,
            "risk": "May change or delete remote data", "rule": "github.remote_change",
          ], reason)
      else { return textResult(["status": "denied"], error: true) }
    }
    let timeout = arguments["timeout_seconds"] as? Double ?? 30
    guard (1...300).contains(timeout) else { throw SideportError("Invalid timeout") }
    let gh = try await compatible.ensure()
    let scratch = runtime.scratch + "/github-" + UUID().uuidString
    try directory(scratch)
    defer { try? FileManager.default.removeItem(atPath: scratch) }
    let config = scratch + "/gh"
    try directory(config)
    try Data().write(to: URL(fileURLWithPath: config + "/hosts.yml"))
    chmod(config + "/hosts.yml", 0o600)
    var executable = gh
    var executionArgs = args
    var allow: [JSONObject] = [
      ["method": "GET", "path": "/**"], ["method": "HEAD", "path": "/**"],
    ]
    if plan.graphql { allow.append(["method": "POST", "path": "/graphql"]) }
    if GitHubPlan.writes.contains(plan.pair) {
      for path in [
        "/repos/*/*/issues", "/repos/*/*/issues/*", "/repos/*/*/issues/*/comments",
        "/repos/*/*/pulls", "/repos/*/*/pulls/*", "/repos/*/*/pulls/*/comments",
      ] { for method in ["POST", "PATCH"] { allow.append(["method": method, "path": path]) } }
    }
    if plan.approval { allow.append(["method": "*", "path": "/**"]) }
    var credential: JSONObject = [
      "upstream": "https://api.github.com", "credential_key": "env://SIDEPORT_PRIVATE_GITHUB",
      "env_var": "GH_TOKEN",
      "credential_format": "Bearer {}",
      "endpoint_policy": ["default": ["decision": "deny"], "allow": allow],
    ]
    var credentialName = "github"
    if let remote = plan.remote, let refspec = plan.refspec {
      guard let developer = runtime.environment["DEVELOPER_DIR"] else {
        throw SideportError("Developer tools are unavailable")
      }
      executable = try canonical(developer + "/usr/bin/git", existing: true)
      func inspect(_ args: [String]) async throws -> String {
        let out = try await runtime.execute(
          executable, ["-c", "core.hooksPath=/dev/null"] + args, cwd: cwd, approved: grants)
        guard out.code == 0, !out.stopped else {
          throw SideportError("Sandboxed Git inspection failed")
        }
        return String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(
          in: .whitespacesAndNewlines)
      }
      let url = try await inspect([
        "config", "--local", "--no-includes", "--get", "remote." + remote + ".url",
      ])
      guard
        GitHubPlan.matches(
          url, #"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?$"#),
        !url.contains(".."), let pathname = URL(string: url)?.path
      else {
        throw SideportError("Configure an HTTPS github.com remote without embedded credentials")
      }
      let repoPath = (pathname.hasSuffix(".git") ? String(pathname.dropLast(4)) : pathname) + ".git"
      credentialName = "github_git"
      credential = [
        "upstream": "https://github.com", "credential_key": "env://SIDEPORT_PRIVATE_GITHUB",
        "env_var": "SIDEPORT_GIT_TOKEN", "inject_header": "Authorization",
        "credential_format": "Basic {}", "inject_mode": "basic_auth",
        "endpoint_policy": [
          "default": ["decision": "deny"],
          "allow": [
            ["method": "GET", "path": repoPath + "/info/refs"],
            ["method": "POST", "path": repoPath + "/git-receive-pack"],
          ],
        ],
      ]
      let bare = scratch + "/push.git"
      try directory(bare + "/refs/heads")
      try directory(bare + "/objects/info")
      try Data("[core]\n repositoryformatversion = 0\n bare = true\n".utf8).write(
        to: URL(fileURLWithPath: bare + "/config"))
      try Data("ref: refs/heads/sideport-push\n".utf8).write(
        to: URL(fileURLWithPath: bare + "/HEAD"))
      var ref = refspec
      if !refspec.hasPrefix(":") {
        let source = String(refspec.split(separator: ":", maxSplits: 1)[0]).trimmingCharacters(
          in: CharacterSet(charactersIn: "+"))
        let commit = try await inspect(["rev-parse", "--verify", source + "^{commit}"])
        let objects = try await inspect([
          "rev-parse", "--path-format=absolute", "--git-path", "objects",
        ])
        guard GitHubPlan.matches(commit, #"^([a-f0-9]{40}|[a-f0-9]{64})$"#), objects.hasPrefix("/"),
          !objects.contains("\n"), !objects.contains("\r")
        else { throw SideportError("Invalid sandboxed Git object lookup") }
        try Data((objects + "\n").utf8).write(
          to: URL(fileURLWithPath: bare + "/objects/info/alternates"))
        try Data((commit + "\n").utf8).write(
          to: URL(fileURLWithPath: bare + "/refs/heads/sideport-push"))
        ref =
          (refspec.hasPrefix("+") ? "+" : "") + "refs/heads/sideport-push:"
          + refspec.split(separator: ":", maxSplits: 1)[1]
      }
      let helper =
        "!f() { printf \"username=x-access-token\\npassword=%s\\n\" \"$SIDEPORT_GIT_TOKEN\"; }; f"
      executionArgs =
        [
          "--git-dir=" + bare, "-c", "core.hooksPath=/dev/null", "-c", "credential.helper=", "-c",
          "credential.https://github.com.helper=" + helper, "-c", "protocol.allow=never", "-c",
          "protocol.https.allow=always", "push",
        ] + plan.flags.filter { !["--delete", "-d"].contains($0) } + [url, ref]
    }
    var readGrants = (runtime.grants + grants).map {
      Grant(path: $0.path, kind: $0.kind, access: "read")
    }
    readGrants.append(
      Grant(
        path: URL(fileURLWithPath: gh).deletingLastPathComponent().path, kind: "directory",
        access: "read"))
    readGrants.append(Grant(path: scratch, kind: "directory", access: "read_write"))
    var profile = try runtime.profile([], extra: readGrants, network: true)
    // Drop default writable caches for credential-bearing requests.
    var fs = profile["filesystem"] as! JSONObject
    fs["allow"] = [scratch]
    fs["allow_file"] = ["/dev/null"]
    profile["filesystem"] = fs
    profile["network"] =
      [
        "tls_intercept": [
          "ca_lifecycle": "session", "ca_validity": "24h", "leaf_validity": "15m",
          "ca_env_vars": ["SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS", "GIT_SSL_CAINFO"],
        ],
        "credentials": [credentialName], "custom_credentials": [credentialName: credential],
      ] as JSONObject
    profile["environment"] =
      [
        "allow_vars": [
          "HOME", "PATH", "LANG", "GH_TOKEN", "SIDEPORT_GIT_TOKEN", "HTTP_PROXY", "HTTPS_PROXY",
          "NO_PROXY", "http_proxy", "https_proxy", "no_proxy", "NONO_PROXY_TOKEN", "SSL_CERT_FILE",
          "NODE_EXTRA_CA_CERTS", "GIT_SSL_CAINFO",
        ],
        "set_vars": [
          "GH_CONFIG_DIR": config, "GH_HOST": "github.com", "GH_PROMPT_DISABLED": "1",
          "GH_NO_UPDATE_NOTIFIER": "1", "GH_PAGER": "cat", "GIT_CONFIG_GLOBAL": "/dev/null",
          "GIT_CONFIG_NOSYSTEM": "1",
        ],
      ] as JSONObject
    guard let credentialHelper = runtime.trustedTools["gh"] else {
      throw SideportError("Local GitHub login is unavailable")
    }
    let captured = try await runtime.supervisor.run(
      credentialHelper, ["auth", "token", "--hostname", "github.com"],
      environment: [
        "HOME": runtime.context.home, "PATH": "/usr/bin:/bin",
        "GH_CONFIG_DIR": runtime.context.home + "/.config/gh",
      ], cwd: runtime.scratch, timeout: 10, limit: 4096)
    let token = String(decoding: captured.stdout, as: UTF8.self).trimmingCharacters(
      in: .whitespacesAndNewlines)
    guard captured.code == 0, !captured.stopped, !token.isEmpty, token.utf8.count <= 2048,
      !token.contains(where: \.isWhitespace)
    else { throw SideportError("Existing GitHub Keychain login is unavailable") }
    return try await runtime.launchProfile(
      profile, executable, executionArgs, cwd: cwd, timeout: timeout,
      environment: [
        "GH_CONFIG_DIR": runtime.context.home + "/.config/gh",
        "SIDEPORT_PRIVATE_GITHUB": plan.remote == nil ? token : "x-access-token:" + token,
      ]
    ).result
  }
  static func credential(_ gh: String) async throws {
    let actual = try canonical(gh, existing: true)
    let context = try NativeContext()
    guard inside(actual, context.work + "/host-tools"), actual == gh,
      URL(fileURLWithPath: actual).lastPathComponent == "gh"
    else { throw SideportError("Invalid credential helper") }
    let out = try await ChildSupervisor().run(
      actual, ["auth", "token", "--hostname", "github.com"],
      environment: [
        "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin",
        "GH_CONFIG_DIR": NSHomeDirectory() + "/.config/gh",
      ], cwd: "/private/tmp", timeout: 10, limit: 4096)
    let token = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(
      in: .whitespacesAndNewlines)
    guard out.code == 0, !out.stopped, !token.isEmpty, !token.contains(where: { $0.isWhitespace })
    else { throw SideportError("Keychain credential unavailable") }
    try FileHandle.standardOutput.write(contentsOf: Data(("x-access-token:" + token).utf8))
  }
}
