import Foundation
import Testing
@testable import RoundsCore

@Suite struct RemoteOwnerTests {
    private let owner = RemoteOwner("github.com/HenryQW")!

    @Test func ownerTextIsOneHostAndOneAccount() {
        #expect(RemoteOwner("GitHub.com/HenryQW")?.description == "github.com/HenryQW")
        #expect(RemoteOwner(" github.com/Evermark ")?.account == "Evermark")
        for text in ["", "github.com", "HenryQW", "https://github.com/HenryQW", "github.com/HenryQW/Rounds", "github.com/",
                     "/HenryQW", "github.com:22/HenryQW", "github.com/Henry QW", "github.com/..", "-x.com/a", "github.com/~a"] {
            #expect(RemoteOwner(text) == nil, "\(text)")
        }
    }

    @Test(arguments: [
        ("https://github.com/HenryQW/Rounds.git", true),
        ("https://github.com/henryqw/rounds", true),
        ("https://GitHub.com/HenryQW/Rounds/", true),
        ("https://user:token@github.com/HenryQW/Rounds.git", true),
        ("https://github.com:443/HenryQW/Rounds.git", true),
        ("ssh://git@github.com/HenryQW/Rounds.git", true),
        ("ssh://git@github.com:22/HenryQW/Rounds.git", true),
        ("git@github.com:HenryQW/Rounds.git", true),
        ("github.com:HenryQW/Rounds.git", true),
        ("work:HenryQW/Rounds.git", true),
        ("ssh://work/HenryQW/Rounds.git", true),
        ("https://github.com/Evermark/hub.git", false),
        ("git@github.com:Evermark/hub.git", false),
        ("https://gitlab.com/HenryQW/Rounds.git", false),
        ("https://github.com/HenryQW", false),
        ("https://github.com/HenryQW.git", false),
        ("https://github.com/HenryQW-fork/Rounds.git", false),
        ("https://github.com/HenryQW%2F..%2FEvermark/hub.git", false),
        ("https://github.com/../Evermark/hub.git", false),
        ("https://github.com//HenryQW/Rounds.git", false),
        ("https://HenryQW@evil.example/HenryQW/Rounds.git", false),
        ("https://github.com@evil.example/HenryQW/Rounds.git", false),
        ("https://github.com/HenryQW/Rounds.git?x=1", false),
        ("ssh://git@github.com/~HenryQW/Rounds.git", false),
        ("other:HenryQW/Rounds.git", false),
        ("unknown:HenryQW/Rounds.git", false),
        ("file:///Users/henry/HenryQW/Rounds", false),
        ("/Users/henry/HenryQW/Rounds", false),
        ("./HenryQW/Rounds", false),
        ("ftp://github.com/HenryQW/Rounds.git", false),
        ("https://github.com/HenryQW/Rounds.git\n", false),
        ("git@[::1]:HenryQW/Rounds.git", false),
        ("", false),
    ])
    func ownerCheckAllowsOnlyTheOwnersRemotes(url: String, allowed: Bool) {
        // `work` is an SSH alias of github.com, `other` an alias of another host, and `unknown` does not resolve.
        let aliases = ["work": "github.com", "other": "gitlab.com", "github.com": "github.com"]
        #expect(remoteBelongs(url, to: owner, sshHostName: { aliases[$0] }) == allowed)
    }

    @Test func sshAliasResolvesWithTheSSHConfiguration() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let config = base.appending(path: "config")
        try Data("Host work\n  HostName github.com\nHost far\n  HostName git.example.invalid\n".utf8).write(to: config)
        #expect(resolveSSHHostName("work", configFile: config.path) == "github.com")
        #expect(resolveSSHHostName("far", configFile: config.path) == "git.example.invalid")
        #expect(resolveSSHHostName("github.com", configFile: config.path) == "github.com")
        // An option in place of a host name never reaches ssh.
        #expect(resolveSSHHostName("-oProxyCommand=touch x", configFile: config.path) == nil)
        #expect(remoteBelongs("git@work:HenryQW/Rounds.git", to: owner,
                              sshHostName: { resolveSSHHostName($0, configFile: config.path) }))
        #expect(!remoteBelongs("git@far:HenryQW/Rounds.git", to: owner,
                               sshHostName: { resolveSSHHostName($0, configFile: config.path) }))
    }
}
