import Foundation
@testable import AIShellCore

extension RuntimeStore {
    func setWorkingDirectoryForTesting(_ url: URL) {
        workingDirectory = url
    }
}
