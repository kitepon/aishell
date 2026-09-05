import XCTest
@testable import AIShellCore

final class PathResolverTests: XCTestCase {
    func testRelativeUsesFirstRootAndAbsoluteMatchesSecondRoot() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let first = fixture.base.appendingPathComponent("first", isDirectory: true)
        let second = fixture.base.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let secondFile = second.appendingPathComponent("value.txt")
        try Data("value".utf8).write(to: secondFile)
        let resolver = PathResolver(baseDirectory: first)

        XCTAssertEqual(try resolver.resolveDestination("new.txt").path, first.appendingPathComponent("new.txt").path)
        XCTAssertEqual(try resolver.resolveExisting(secondFile.path).path, secondFile.path)
    }

    func testResolvesParentTraversalAndSymlinkOutsideBase() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let outside = fixture.base.appendingPathComponent("outside", isDirectory: true)
        let root = fixture.base.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside
        )

        let resolver = PathResolver(baseDirectory: URL(fileURLWithPath: root.path))

        XCTAssertNoThrow(try resolver.resolveDestination("../outside/new.txt"))

        XCTAssertNoThrow(try resolver.resolveExisting("escape/secret.txt"))

        XCTAssertNoThrow(try resolver.resolveDestination("escape/new.txt"))
    }

    func testAutomaticallyAllowsRegisteredGitWorktree() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let repository = fixture.base.appendingPathComponent("repository", isDirectory: true)
        let worktree = fixture.base.appendingPathComponent("repository-wt-task", isDirectory: true)
        let administrativeDirectory = repository
            .appendingPathComponent(".git/worktrees/task", isDirectory: true)
        try FileManager.default.createDirectory(at: administrativeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("\(worktree.appendingPathComponent(".git").path)\n".utf8).write(
            to: administrativeDirectory.appendingPathComponent("gitdir")
        )
        try Data("gitdir: \(administrativeDirectory.path)\n".utf8).write(
            to: worktree.appendingPathComponent(".git")
        )
        let file = worktree.appendingPathComponent("value.txt")
        try Data("value".utf8).write(to: file)

        let resolver = PathResolver(baseDirectory: URL(fileURLWithPath: repository.path))

        XCTAssertEqual(try resolver.resolveExisting(file.path).path, file.path)
    }

    func testResolvesUnregisteredWorktree() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let repository = fixture.base.appendingPathComponent("repository", isDirectory: true)
        let sibling = fixture.base.appendingPathComponent("repository-wt-fake", isDirectory: true)
        let administrativeDirectory = repository
            .appendingPathComponent(".git/worktrees/fake", isDirectory: true)
        try FileManager.default.createDirectory(at: administrativeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("\(sibling.appendingPathComponent(".git").path)\n".utf8).write(
            to: administrativeDirectory.appendingPathComponent("gitdir")
        )
        try Data("gitdir: /unrelated/admin\n".utf8).write(to: sibling.appendingPathComponent(".git"))
        let file = sibling.appendingPathComponent("value.txt")
        try Data("value".utf8).write(to: file)
        let resolver = PathResolver(baseDirectory: URL(fileURLWithPath: repository.path))

        XCTAssertNoThrow(try resolver.resolveExisting(file.path))
    }
}
