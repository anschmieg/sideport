import Darwin
import Foundation

final class RuntimeSupport {
  let context: NativeContext
  let supervisor: ChildSupervisor
  let scratch: String
  var grants: [Grant] = []
  var environment: [String: String] = [:]
  var trustedTools: [String: String] = [:]
  var trustedSourcePaths = [
    "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/opt/homebrew/Cellar/gh", "/usr/local/Cellar/gh",
    "/opt/homebrew/bin/smithery", "/usr/local/bin/smithery",
    "/opt/homebrew/lib/node_modules/@smithery/cli", "/usr/local/lib/node_modules/@smithery/cli",
  ]
  let hostTools: String
  static let excluded = [
    "system_read_macos", "system_write_macos", "user_caches_macos", "node_runtime", "bun_runtime",
    "git_config", "go_runtime", "go_runtime_macos", "homebrew_macos", "java_runtime",
    "mise_manager", "nix_runtime", "python_runtime", "rust_runtime", "user_tools",
    "claude_code_macos", "codex_macos", "vscode_macos",
  ]
  init(_ context: NativeContext, _ supervisor: ChildSupervisor) throws {
    self.context = context
    self.supervisor = supervisor
    trustedSourcePaths.append(context.home + "/.local/bin/smithery")
    hostTools = context.work + "/host-tools/" + UUID().uuidString
    try directory(hostTools)
    // Credential-bearing host invocations must not execute code from an
    // agent-writable toolchain. Freeze installed helpers before accepting RPC.
    for name in ["gh", "smithery"] {
      let candidates =
        ["/opt/homebrew/bin/" + name, "/usr/local/bin/" + name]
        + (name == "smithery" ? [context.home + "/.local/bin/smithery"] : [])
      guard let source = candidates.compactMap({ try? canonical($0, existing: true) }).first else {
        continue
      }
      if name == "gh" {
        guard
          GitHubPlan.matches(source, #"^/(opt/homebrew|usr/local)/(Cellar/gh/[^/]+/bin|bin)/gh$"#)
        else { continue }
        trustedSourcePaths.append(source)
        let destination = hostTools + "/gh"
        try FileManager.default.copyItem(atPath: source, toPath: destination)
        chmod(destination, 0o500)
        trustedTools[name] = destination
      } else {
        let package = URL(fileURLWithPath: source).deletingLastPathComponent()
          .deletingLastPathComponent().path
        guard source == package + "/dist/index.js",
          let metadata = try? jsonObject(
            Data(contentsOf: URL(fileURLWithPath: package + "/package.json"))),
          metadata["name"] as? String == "@smithery/cli"
        else { continue }
        trustedSourcePaths.append(package)
        try FileManager.default.copyItem(atPath: package, toPath: hostTools + "/smithery")
        trustedTools[name] = hostTools + "/smithery/dist/index.js"
      }
    }
    var template = Array("/private/tmp/sideport-native-XXXXXX".utf8CString)
    guard let path = mkdtemp(&template) else {
      throw SideportError("Cannot create sandbox scratch directory")
    }
    scratch = String(cString: path)
    chmod(scratch, 0o700)
    func add(_ path: String, _ access: String) {
      if let actual = try? canonical(path, existing: true), (try? context.checkGrant(actual)) != nil
      {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: actual, isDirectory: &isDir)
        if !grants.contains(where: { $0.path == actual }) {
          grants.append(
            Grant(path: actual, kind: isDir.boolValue ? "directory" : "file", access: access))
        }
      }
    }
    let resources = NativeResources.directory
    if let data = try? Data(contentsOf: resources.appendingPathComponent("BuildLocations.json")),
      let locations = try? jsonObject(data)
    {
      for path in locations["installations"] as? [String] ?? [] {
        add(NSString(string: path).expandingTildeInPath, "read")
      }
      for path in locations["caches"] as? [String] ?? [] {
        add(NSString(string: path).expandingTildeInPath, "read_write")
      }
    }
    for path in [
      "/bin", "/usr/bin", "/usr/lib", "/usr/share", "/System/Library", "/System/Cryptexes",
      "/private/etc/ssl", "/private/etc/hosts", "/etc/hosts", "/etc/resolv.conf",
      "/var/run/resolv.conf", "/etc/services", "/etc/ssl", "/private/etc/resolv.conf",
      "/private/var/run/resolv.conf", "/private/etc/services", "/private/etc/localtime",
      "/private/var/select", "/Library/Developer/CommandLineTools", "/dev/null", "/dev/random",
      "/dev/urandom",
    ] { add(path, path.hasPrefix("/dev/") ? "read_write" : "read") }
    for alias in [
      "/etc/hosts", "/etc/resolv.conf", "/var/run/resolv.conf", "/etc/services", "/etc/localtime",
      "/etc/ssl", "/var/select",
    ] {
      if let actual = try? canonical(alias, existing: true),
        let attributes = try? FileManager.default.attributesOfItem(atPath: actual)
      {
        grants.append(
          Grant(
            path: alias,
            kind: attributes[.type] as? FileAttributeType == .typeDirectory ? "directory" : "file",
            access: "read"))
      }
    }
    add(scratch, "read_write")
    if let actual = try? canonical(NSTemporaryDirectory(), existing: true),
      actual.hasPrefix("/private/var/folders/"), actual.hasSuffix("/T")
    {
      add(actual, "read_write")
    }
    let own = Bundle.main.bundleURL.path
    let code = own.hasSuffix(".app") ? own : context.codeLocation
    grants.append(
      Grant(path: code, kind: code.hasSuffix(".app") ? "directory" : "file", access: "read"))
    environment = [
      "HOME": context.home,
      "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:" + context.home
        + "/.cargo/bin:" + context.home + "/.bun/bin:" + context.home
        + "/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": scratch + "/",
      "LANG": "en_US.UTF-8", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
      "OPENSSL_CONF": "/dev/null",
    ]
    func fallback(_ name: String) -> String {
      let p = scratch + "/" + name
      try? directory(p)
      return p
    }
    let cargo = fallback("cargo")
    for name in ["registry", "git"] {
      let cache = context.home + "/.cargo/" + name
      if FileManager.default.fileExists(atPath: cache) {
        try? FileManager.default.createSymbolicLink(
          atPath: cargo + "/" + name, withDestinationPath: cache)
      }
    }
    environment["CARGO_HOME"] = cargo
    environment["RUSTUP_HOME"] = context.home + "/.rustup"
    for (key, location) in [
      "NPM_CONFIG_CACHE": context.home + "/.npm",
      "BUN_INSTALL_CACHE_DIR": context.home + "/.bun/install/cache",
      "GOCACHE": context.home + "/Library/Caches/go-build",
      "GOMODCACHE": context.home + "/go/pkg/mod",
      "PIP_CACHE_DIR": context.home + "/Library/Caches/pip",
      "UV_CACHE_DIR": context.home + "/Library/Caches/uv",
    ] {
      environment[key] = FileManager.default.fileExists(atPath: location) ? location : fallback(key)
    }
    environment["NPM_CONFIG_USERCONFIG"] = scratch + "/npm-user.conf"
    environment["NPM_CONFIG_GLOBALCONFIG"] = scratch + "/npm-global.conf"
    FileManager.default.createFile(atPath: scratch + "/npm-user.conf", contents: Data())
    FileManager.default.createFile(atPath: scratch + "/npm-global.conf", contents: Data())
    for path in [
      "/var/db/xcode_select_link", "/Library/Developer/CommandLineTools",
      "/Applications/Xcode.app/Contents/Developer",
    ] {
      if let actual = try? canonical(path, existing: true) {
        add(actual, "read")
        environment["DEVELOPER_DIR"] = actual
        environment["PATH"] = actual + "/usr/bin:" + environment["PATH"]!
        if let sdk = try? canonical(actual + "/SDKs/MacOSX.sdk", existing: true) {
          add(sdk, "read")
          environment["SDKROOT"] = sdk
        }
        break
      }
    }
  }
  func close() {
    try? FileManager.default.removeItem(atPath: scratch)
    try? FileManager.default.removeItem(atPath: hostTools)
  }
  var codeWriteRules: [String] {
    // Escape as Seatbelt string literals, never interpolate raw path syntax.
    let paths = [context.codeLocation, context.work + "/host-tools"] + trustedSourcePaths
    return paths.map {
      let quoted = $0.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
      return "(deny file-write* (subpath \"" + quoted + "\"))"
    } + [
      "(deny network-outbound (subpath \"/\"))",
      "(allow network-outbound (path \"/private/var/run/mDNSResponder\"))",
      "(allow network-outbound (path \"/var/run/mDNSResponder\"))",
      "(deny job-creation)",
      "(deny system-audit)",
      "(deny mach-priv-task-port)",
      // Screen/Accessibility services can be proxied through multiple daemons.
      // Do not rely on an exhaustive denylist of GUI service names.
      "(deny mach-lookup)",
      "(deny mach-per-user-lookup)",
      // Limit process inspection and signals to the untrusted job. Credential
      // environments also require CS_RESTRICT; these rules alone do not hide
      // KERN_PROCARGS from same-user callers on macOS.
      "(deny process-info*)",
      "(allow process-info* (target self))",
      "(allow process-info* (target same-sandbox))",
      "(allow process-info-listpids)",
      "(deny signal)",
      "(allow signal (target self))",
      "(allow signal (target same-sandbox))",
    ]
      + [
        "com.apple.system.logger", "com.apple.logd", "com.apple.dnssd.service",
        "com.apple.networkd", "com.apple.SystemConfiguration.configd",
        "com.apple.trustd", "com.apple.trustd.agent",
      ].map { "(allow mach-lookup (global-name \"" + $0 + "\"))" }
      + [
        "com.apple.windowserver.active", "com.apple.windowserver", "com.apple.WindowServer",
        "com.apple.coreservices.launchservicesd", "com.apple.tccd", "com.apple.axserver",
        "com.apple.xpc.launchd",
        "com.apple.securityd", "com.apple.SecurityServer", "com.apple.securityd.xpc",
        "com.apple.replayd", "com.apple.replayd.capture",
        "com.apple.replaykit.sharingsession", "com.apple.replaykit.sharingsession.notification",
        "com.apple.usernotifications.delegate.com.apple.ReplayKitNotifications",
        "com.apple.coreservices.uauseractivitypasteboardclient.xpc",
      ].map { "(deny mach-lookup (global-name \"" + $0 + "\"))" } + [
        "(deny mach-lookup (global-name-regex \"^com\\\\.apple\\\\.(pasteboard|pboard)(\\\\..*)?$\"))"
      ]
  }
  func profile(_ approved: [Grant], extra: [Grant] = [], network: Bool = false, deny: [String] = [])
    throws -> JSONObject
  {
    var filesystem: JSONObject = [
      "read": [], "read_file": [], "allow": [], "allow_file": [], "deny": context.denied + deny,
    ]
    for g in grants + approved + extra {
      guard g.path.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[]{}")) == nil else {
        throw SideportError("Sandbox paths cannot contain glob characters")
      }
      let key = (g.access == "read_write" ? "allow" : "read") + (g.kind == "file" ? "_file" : "")
      var array = filesystem[key] as! [String]
      if !array.contains(g.path) { array.append(g.path) }
      filesystem[key] = array
    }
    return [
      "meta": ["name": "Sideport native sandbox"], "groups": ["exclude": Self.excluded],
      "unsafe_macos_seatbelt_rules": codeWriteRules,
      "filesystem": filesystem, "network": ["block": !network],
      "security": [
        "signal_mode": "allow_same_sandbox", "process_info_mode": "isolated",
        "ipc_mode": "shared_memory_only", "capability_elevation": false,
      ],
    ]
  }
  // Downloaded npm code gets only its advertised file scope, not shell caches
  // or another provider's scratch directory.
  func providerProfile(_ approved: [Grant], extra: [Grant], network: Bool = false) throws
    -> JSONObject
  {
    var profile = try self.profile([], extra: [], network: network)
    var fs: JSONObject = [
      "read": [], "read_file": [], "allow": [], "allow_file": [], "deny": context.denied,
    ]
    let system = [
      "/bin", "/usr/bin", "/usr/lib", "/usr/share", "/System/Library", "/System/Cryptexes",
      "/private/etc/ssl", "/private/etc/hosts", "/etc/hosts", "/etc/resolv.conf",
      "/var/run/resolv.conf", "/etc/services", "/etc/ssl", "/private/etc/resolv.conf",
      "/private/var/run/resolv.conf", "/private/etc/services", "/private/etc/localtime",
      "/dev/urandom", "/dev/random", "/dev/null",
    ].compactMap { path -> Grant? in
      guard let actual = try? canonical(path, existing: true) else { return nil }
      let attributes = try? FileManager.default.attributesOfItem(atPath: actual)
      return Grant(
        path: path,
        kind: attributes?[.type] as? FileAttributeType == .typeDirectory ? "directory" : "file",
        access: path == "/dev/null" ? "read_write" : "read")
    }
    for grant in system + approved + extra {
      guard grant.path.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[]{}")) == nil else {
        throw SideportError("Invalid provider scope path")
      }
      let key =
        (grant.access == "read_write" ? "allow" : "read") + (grant.kind == "file" ? "_file" : "")
      var values = fs[key] as! [String]
      if !values.contains(grant.path) { values.append(grant.path) }
      fs[key] = values
    }
    profile["filesystem"] = fs
    return profile
  }
  func launchProfile(
    _ profile: JSONObject, _ executable: String, _ args: [String], cwd: String,
    timeout: Double = 30, environment override: [String: String] = [:], input: Data? = nil,
    outputLimit: Int = 1_048_576
  ) async throws -> CommandOutput {
    let file = context.session + "/" + UUID().uuidString + ".profile.json"
    try privateWrite(profile, file)
    defer { try? FileManager.default.removeItem(atPath: file) }
    var env = environment
    for (key, value) in override { env[key] = value }
    env["XDG_CONFIG_HOME"] = context.work + "/nono-config"
    env["XDG_STATE_HOME"] = context.work + "/nono-state"
    env["XDG_CACHE_HOME"] = context.work + "/nono-cache"
    env["SIDEPORT_HOME"] = context.root
    env["MAC_CHATGPT_APPROVAL_DIR"] = context.session
    return try await supervisor.run(
      context.work + "/nono-bin/nono",
      ["run", "--silent", "--profile", file, "--no-rollback", "--", executable] + args,
      environment: env, cwd: cwd, timeout: timeout, limit: outputLimit, inputData: input)
  }
  func execute(
    _ executable: String, _ args: [String], cwd: String, approved: [Grant], network: Bool = false,
    timeout: Double = 30
  ) async throws -> CommandOutput {
    try await launchProfile(
      profile(approved, network: network), executable, args, cwd: cwd, timeout: timeout)
  }
}
enum NativeResources {
  static var directory: URL {
    if let path = ProcessInfo.processInfo.environment["SIDEPORT_RESOURCES"] {
      return URL(fileURLWithPath: path)
    }
    let bundle = Bundle.main.resourceURL ?? Bundle.main.bundleURL
    if FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Tools.json").path) {
      return bundle
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
      "Resources")
  }
}
