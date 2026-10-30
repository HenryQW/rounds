---
title: Build from source
description: Build Rounds with the Command Line Tools, run the tests, and run the docs site.
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

`scripts/bundle.sh` builds `build/Rounds.app` and signs it with an ad-hoc signature. `--install` also copies it to `/Applications`. To start a new build, quit Rounds first: `pkill -x Rounds`.

After the first launch, install the hooks. See [Install](/install#install-the-hooks).

## Other tasks

| Task | Command |
| --- | --- |
| Run the tests | `scripts/test.sh` |
| Make the disk image `build/Rounds-<version>.dmg` | `scripts/dmg.sh` (after `scripts/bundle.sh`) |
| Take the docs screenshots (demo data) | `scripts/screenshots.sh` |
| Run the docs site | `cd website && pnpm install && pnpm dev` |

The version is in the `VERSION` file. The build writes it into the app.

## The docs site

Cloudflare Pages builds the docs site from `main` at each push: the project `rounds` runs `pnpm build` in `website` and publishes `website/dist` at [rounds.henry.wang](https://rounds.henry.wang). The pnpm and Node versions come from `website/package.json`.
