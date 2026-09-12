import Foundation
import AIShellCore

@main
enum AIShellMCPMain {
    static func main() async {
        if CommandLine.arguments.dropFirst() == ["--version"] {
            print(AIShellProduct.version)
            return
        }
        guard CommandLine.arguments.count == 1 else {
            FileHandle.standardError.write(Data("aishell-mcp: 未対応の引数です。\n".utf8))
            exit(64)
        }
        let outcome = await MCPServer().run()
        exit(outcome.exitCode)
    }
}
