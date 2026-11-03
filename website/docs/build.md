---
title: Build from source
description: Build Rounds from source with the Command Line Tools only, run the Swift tests, make the disk image, and run the docs site on your Mac.
---

## Requirements

- macOS 27 on a Mac with Apple silicon.
- Command Line Tools for Xcode. Run `xcode-select --install` if you do not have them. Xcode is not necessary.

## Build and install

```sh
git clone https://github.com/HenryQW/rounds.git
cd rounds
scripts/bundle.sh --install
open /Applications/Rounds.app
```

`scripts/bundle.sh` builds `build/Rounds.app` and signs it. It uses the identity "Rounds Self-Signed" when a keychain has it, as releases do, else an ad-hoc signature. `--install` also copies it to `/Applications`. To start a new build, quit Rounds first: `pkill -x Rounds`.

After the first launch, install the hooks. See [Install](/install#install-the-hooks).

## Other tasks

| Task | Command |
| --- | --- |
| Run the tests | `scripts/test.sh` |
| Make the disk image `build/Rounds.dmg` | `scripts/dmg.sh` (after `scripts/bundle.sh`) |
| Take the README picture (demo data) | `scripts/screenshots.sh` |
| Run the docs site | `cd website && pnpm install && pnpm dev` |

The version is in the `VERSION` file. The build writes it into the app. To publish a version, see [Release](/release).

## The docs site

Cloudflare Pages builds the docs site from `main` at each push: the project `rounds` runs `pnpm build` in `website` and publishes `website/dist` at [rounds.henry.wang](/). The pnpm and Node versions come from `website/package.json`.
