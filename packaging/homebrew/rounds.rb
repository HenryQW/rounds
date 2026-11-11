# The cask for HenryQW/homebrew-tap. The release workflow fills in the version and the SHA-256 and commits it to the tap
# as Casks/rounds.rb.
cask "rounds" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/HenryQW/rounds/releases/download/v#{version}/Rounds.dmg"
  name "Rounds"
  desc "Keeps a tab on your AI coding agents from the edge of your screen"
  homepage "https://rounds.henry.wang/"

  # Rounds updates itself with Sparkle, so brew upgrade leaves it alone unless --greedy.
  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :golden_gate

  app "Rounds.app"

  # Rounds has no Developer ID, so macOS calls a quarantined copy damaged.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Rounds.app"]
  end

  zap trash: [
    "~/Library/Application Support/Rounds",
    "~/Library/Preferences/com.henryqw.rounds.plist",
  ]

  caveats <<~EOS
    Before you uninstall Rounds, click Remove Hooks in Settings > Agents, for Claude Code and Codex.
    The hooks run a helper inside Rounds.app.
  EOS
end
