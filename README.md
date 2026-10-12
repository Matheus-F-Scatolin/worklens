# Worklens

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B-lightgrey.svg)
![Status: personal project](https://img.shields.io/badge/Status-personal%20project-orange.svg)

**A menu-bar app that watches your own screen and shows you, as a timeline you can read, where
your day actually went.**

<p align="center">
  <img src="docs/media/today.png" width="760"
       alt="The Today page: a waterfall of the day's active time by app, ending in the day's total.">
</p>

<p align="center">
  <img src="docs/media/week.png" width="760"
       alt="The Weeks page: one column per day, each block of work colored by app, meetings in white.">
</p>

<sub>The built-in sample week, which the welcome window's tour opens. Invented days, not a real one.</sub>

## Install

You need macOS 14+ and a Swift 6.1+ toolchain (`xcode-select --install` is enough). Worklens
builds from source, so its signature, and the permissions macOS ties to it, survive updates.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Matheus-F-Scatolin/worklens/main/scripts/bootstrap.sh)"
```

It names every step and asks once, then builds and installs Worklens into
`~/Library/Application Support/Worklens/src` and opens it. Safe to re-run. Leave that folder
where it is, or the app can no longer update itself.

Or paste this into [Claude Code](https://claude.com/claude-code). It shows you the plan, waits
for your yes, and never asks for your Gemini key:

```text
Set up Worklens on this Mac: https://github.com/Matheus-F-Scatolin/worklens
Follow the "If someone asks you to install Worklens" section of its CLAUDE.md.
```

Or from a checkout of your own ([docs/user/setup.md](docs/user/setup.md)):

```bash
git clone https://github.com/Matheus-F-Scatolin/worklens.git
cd worklens
make setup
```

## First run

Worklens opens on a welcome window and captures nothing until you finish it. Take the tour to
look around the sample week, allow Screen Recording when macOS asks, then paste a key from
<https://aistudio.google.com/apikey>. Use a billing-enabled project: on Google's free tier your
prompts and images may be used to train their models.

## Cost

About $0.10 a day, roughly $2 a month at the defaults, paid to Google for your own key, with a
hard daily cap ([docs/user/cost.md](docs/user/cost.md)).

## Privacy

Everything stays in one folder on your Mac, apart from what Gemini needs to describe a frame and
the update check or integrations you turn on. No analytics, no account, no server.
[PRIVACY.md](PRIVACY.md) lists every host the code can reach and how to delete anything.

## Docs

- [docs/user/index.md](docs/user/index.md): every page for someone running Worklens
- [CONTRIBUTING.md](CONTRIBUTING.md): toolchain, make targets and conventions
- [SECURITY.md](SECURITY.md): how to report something privately

## License

MIT, see [LICENSE](LICENSE). Copyright © 2026 Matheus F. Scatolin.
