# The cask for HenryQW/homebrew-tap. The release workflow fills in the version and the SHA-256 and commits it to the tap
# as Casks/rounds.rb.
cask "rounds" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/HenryQW/rounds/releases/download/v#{version}/Rounds-#{version}.dmg"
  name "Rounds"
  desc "Keeps a tab on your AI coding agents from the edge of your screen"
  homepage "https://rounds.henry.wang/"

  depends_on arch: :arm64
  depends_on macos: :golden_gate

  app "Rounds.app"

  zap trash: [
    "~/Library/Application Support/Rounds",
    "~/Library/Preferences/com.henryqw.rounds.plist",
  ]

  caveats <<~EOS
    Rounds has no Developer ID signature, so macOS blocks it at first. To open it, run:
      xattr -dr com.apple.quarantine /Applications/Rounds.app
    Run it again after each upgrade.

    Before you uninstall Rounds, click Remove Hooks in Settings > Sources, for Claude Code and Codex.
    The hooks run a helper inside Rounds.app.
  EOS
end
