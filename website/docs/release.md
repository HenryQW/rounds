---
title: Release
description: How a release of Rounds is made and put on Homebrew.
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

1. It runs the tests.
2. It builds `Rounds.app` with `scripts/bundle.sh` and the disk image with `scripts/dmg.sh`.
3. It publishes a GitHub release with `Rounds-<version>.dmg`, its SHA-256 file, and `Rounds.dmg`. The download link on the home page always points to the `Rounds.dmg` of the latest release. The release notes list the subject of each commit since the previous tag, with a link to all changes. The first release says "First release."
4. If `TAP_TOKEN` is set, it writes the new version and checksum into `Casks/rounds.rb` in `HenryQW/homebrew-tap`.


## Signing

A release has an ad-hoc signature: Rounds has no Developer ID, so Apple does not notarize it. macOS blocks the downloaded app at the first launch, and users remove the quarantine flag or click Open Anyway (see [Install](/install#open-rounds-the-first-time)). The cask shows the same command after each install.

## The secret

Set `TAP_TOKEN` in the repository settings, under Secrets and variables > Actions: a fine-grained token with write access to the contents of `HenryQW/homebrew-tap`. Without it the release still publishes, and the tap does not change.

## The Homebrew tap

The tap is the repository `HenryQW/homebrew-tap`. Make it once, empty, on GitHub. The workflow adds `Casks/rounds.rb` from the template `packaging/homebrew/rounds.rb`. Users install with:

```sh
brew trust --tap henryqw/tap && brew install --cask henryqw/tap/rounds
```

A tap is a public GitHub repository whose name starts with `homebrew-`. `brew trust --tap henryqw/tap` lets Homebrew load casks from it. `brew install --cask henryqw/tap/rounds` clones `github.com/HenryQW/homebrew-tap` (the first time only), reads `Casks/rounds.rb`, downloads the disk image from the GitHub release, checks its SHA-256, and copies Rounds to `/Applications`. `brew update` gets new versions of the cask. Homebrew does not review a tap. The tap and the `rounds` repository must be public: Homebrew downloads without a GitHub sign-in.

To check the cask before a release, fill in the template and run `brew style` on it.

The official Homebrew cask repository does not take Rounds: it accepts only apps that pass Gatekeeper, so it needs a Developer ID and notarization.
