import AIShellCore
import Foundation

@main
enum AIShellMCPMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--version"] {
            print(AIShellProduct.version)
            return
        }
        guard arguments.isEmpty else {
            FileHandle.standardError.write(Data("未対応の引数です。aishell-mcpは引数なし、または--versionで起動してください。\n".utf8))
            exit(64)
        }
        exit(await MCPServer().run())
    }
}
