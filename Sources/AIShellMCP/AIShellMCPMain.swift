import Foundation
import AIShellCore

@main
enum AIShellMCPMain {
    static func main() async {
        if CommandLine.arguments.dropFirst() == ["--prepare-manager"] {
            do {
                guard let executable = Bundle.main.executableURL else {
                    throw AIShellError.invalidPath("実行中のMCP helperを特定できません。")
                }
                let app = executable.resolvingSymlinksInPath()
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let result = try await NativeApplicationService().prepareManagerApplication(at: app)
                let data = try JSONEncoder().encode(result)
                print(String(decoding: data, as: UTF8.self))
                return
            } catch {
                FileHandle.standardError.write(Data("MANAGER_PREPARATION_FAILED: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        let outcome = await MCPServer().run()
        exit(outcome.exitCode)
    }
}
