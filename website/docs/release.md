---
title: Release
description: "How a Rounds release is made: a tag starts the workflow, which tests, signs and publishes the app, the Sparkle update feed and the Homebrew cask."
---

A tag starts a release. The GitHub Actions workflow `.github/workflows/release.yml` runs on the `xcode-27` runner (macOS 27, Apple silicon).

## Make a release

1. Write the new version in `VERSION`, for example `0.2.0`, and commit it.
2. Tag the commit with the same version, then push the tag:

```sh
git tag v0.2.0
git push origin v0.2.0
```

The workflow stops if the tag is not `v` followed by the version in `VERSION`.

## What the workflow does

1. If `TAP_TOKEN` is set, it checks that the token works (`scripts/check-tap-token.sh`), before it publishes anything.
2. It runs the tests.
3. It imports the signing certificate into a keychain for the run, builds `Rounds.app` with `scripts/bundle.sh`, stops if the app is not signed with "Rounds Self-Signed", and makes `Rounds.dmg` with `scripts/dmg.sh`.
4. It signs `Rounds.dmg` with the Sparkle key and writes `appcast.xml`, the feed that installed copies of Rounds read for updates. The feed holds the release notes (step 5) as Markdown, so the update window shows them as text. It stops if the key is not set. Then `scripts/verify-update.swift` checks the update as each installed copy will: the signature against `SUPublicEDKey` in the new app, the DMG's length, and the version. It stops on a mismatch.
5. It publishes a GitHub release with two files: `Rounds.dmg`, which is the download, the Homebrew cask's file and the Sparkle update, and `appcast.xml`. The download link on the home page always points to the `Rounds.dmg` of the latest release. The release notes (`scripts/release-notes.sh`) list the commits since the previous tag under Breaking changes, Features, Fixes, Performance, Documentation and Other, by their Conventional Commits type, with the scope in bold and a link to all changes. The first release says "First release."
6. If `TAP_TOKEN` is set, it writes the new version and checksum into `Casks/rounds.rb` in `HenryQW/homebrew-tap`.

## Checks

- **Commits** (`.github/workflows/commits.yml`): each commit pushed to `main`, or in a pull request, must have a Conventional Commits subject (`scripts/check-commits.sh`), so the release notes can group it.
- **Tap token** (`.github/workflows/tap-token.yml`): each Monday, it fails when `TAP_TOKEN` does not work or expires within 30 days. GitHub emails the owner about a failed scheduled run. Run it by hand from the Actions tab after you set a new token.

## Signing

A release is signed with the self-signed certificate "Rounds Self-Signed". Every release then has the same identity, so macOS keeps the permissions you gave Rounds (such as Automation) after an update, and Sparkle can also check the code signature. macOS does not trust the certificate, and Rounds has no Developer ID, so Apple does not notarize it. macOS says that a copy downloaded with a browser is damaged, and users remove the quarantine flag (see [Install](/install#open-rounds-the-first-time); the disk image has a note with the steps). The install script (`website/public/install.sh`) downloads with `curl`, which adds no quarantine flag, and accepts only an app signed with this certificate (it compares the certificate's SHA-256). The cask removes the flag in its `postflight`. If you change the certificate, change the SHA-256 in the script in the same commit.

## The secrets

`SIGNING_CERTIFICATE_P12` and `SIGNING_CERTIFICATE_PASSWORD` are the signing certificate (a base64 p12 file) and its password. Both are in 1Password (account 35brookroad, vault Employee, item "Rounds code signing certificate"; the file is attached as `p12`). The certificate expires on 2046-10-29. To set the secrets again:

```sh
op read --account 35brookroad.1password.com "op://Employee/Rounds code signing certificate/p12" | base64 | tr -d '\n' | gh secret set SIGNING_CERTIFICATE_P12 -R HenryQW/rounds
op read --account 35brookroad.1password.com "op://Employee/Rounds code signing certificate/p12 password" | gh secret set SIGNING_CERTIFICATE_PASSWORD -R HenryQW/rounds
```

A new certificate gives the next release a new identity: macOS asks for permissions again once, and Sparkle accepts that update by its EdDSA signature only.

`SPARKLE_ED_PRIVATE_KEY` is the private half of the EdDSA key that signs updates. Its public half is `SUPublicEDKey` in `Resources/Info.plist`. The key is in 1Password (account 35brookroad, vault Employee, item "Rounds Sparkle EdDSA key"). To set the secret again:

```sh
op read --account 35brookroad.1password.com "op://Employee/Rounds Sparkle EdDSA key/private key" | gh secret set SPARKLE_ED_PRIVATE_KEY -R HenryQW/rounds
```

Keep the key. Rounds has no Developer ID, so Sparkle accepts an update only with a signature from this key. If the key is lost, no installed copy can update, and users must download the next release by hand.

Set `TAP_TOKEN` in the repository settings, under Secrets and variables > Actions: a fine-grained token with write access to the contents of `HenryQW/homebrew-tap`. Without it the release still publishes, and the tap does not change.

## The Homebrew tap

The tap is the repository `HenryQW/homebrew-tap`. Make it once, empty, on GitHub. The workflow adds `Casks/rounds.rb` from the template `packaging/homebrew/rounds.rb`. Users install with:

```sh
brew trust --tap henryqw/tap && brew install --cask henryqw/tap/rounds
```

A tap is a public GitHub repository whose name starts with `homebrew-`. `brew trust --tap henryqw/tap` lets Homebrew load casks from it. `brew install --cask henryqw/tap/rounds` clones `github.com/HenryQW/homebrew-tap` (the first time only), reads `Casks/rounds.rb`, downloads the disk image from the GitHub release, checks its SHA-256, and copies Rounds to `/Applications`. `brew update` gets new versions of the cask. Homebrew does not review a tap. The tap and the `rounds` repository must be public: Homebrew downloads without a GitHub sign-in.

To check the cask before a release, fill in the template and run `brew style` on it.

The official Homebrew cask repository does not take Rounds: it accepts only apps that pass Gatekeeper, so it needs a Developer ID and notarization.
