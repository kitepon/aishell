import AIShellCore
import Darwin
import Foundation

@main
enum AIShellRunSupervisorMain {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, arguments[1] == "--request" else {
            FileHandle.standardError.write(Data("usage: aishell-run-supervisor --request <path>\n".utf8))
            Darwin.exit(2)
        }
        do {
            try ManagedRunSupervisorWorker.run(requestURL: URL(fileURLWithPath: arguments[2]))
        } catch {
            FileHandle.standardError.write(Data("aishell-run-supervisor: \(error)\n".utf8))
            Darwin.exit(1)
        }
    }
}
