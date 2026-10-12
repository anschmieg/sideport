import AppKit
import Foundation

enum SideportBootstrap {
    static func prepare() throws {
        guard let resources = Bundle.main.resourceURL else { throw NSError(domain: "Sideport", code: 1, userInfo: [NSLocalizedDescriptionKey: "App resources are missing."]) }
        let state = ProcessInfo.processInfo.environment["SIDEPORT_HOME"] ?? (NSHomeDirectory() + "/Library/Application Support/Sideport")
        let marker = URL(fileURLWithPath: state).appendingPathComponent("work/bundle-version.json")
        // Nothing is kept running while disconnected. A current installation needs no helper launch.
        if let data = try? Data(contentsOf: marker), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], value["version"] as? String == "0.2.2" { return }
        let child = Process()
        child.executableURL = resources.appendingPathComponent("Runtime/work/node/bin/node")
        child.arguments = [resources.appendingPathComponent("bootstrap.mjs").path, "--target", state]
        child.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let pipe = Pipe(); child.standardOutput = pipe; child.standardError = pipe
        try child.run(); let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
        guard child.terminationStatus == 0 else { throw NSError(domain: "Sideport", code: 2, userInfo: [NSLocalizedDescriptionKey: String(data: bytes, encoding: .utf8) ?? "Could not prepare bundled runtime."]) }
    }
}
