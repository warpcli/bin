# Changelog

## [0.5.0] - 2026-08-23

### <!-- 0 -->⛰️  Features

- Port CLI framework, commands and interactive TUI
- Port github, gitlab, codeberg, hashicorp and goinstall
- Port release-asset selection and unpacking
- Port styles, table, progress, prompts and overlay
- Add squiz-box wrappers for tar, zip and codecs
- Port bayes classifier, neural net and seed model
- Port ELF parsing, patching and file-type detection
- Port manifest and state handling to D

### <!-- 1 -->🐛 Bug Fixes

- Ignore extensionless checksum manifests
- Prefer plain builds and recognise every architecture
- Read PAX and GNU long-name tar entries
- Reject foreign-OS builds and match aliases on token boundaries
- Restore the paginator, status bar and help layout
- Resolve subcommands when flags precede them

### <!-- 3 -->📚 Documentation

- Point the repository URL at termworks/geto
- Correct the TUI, command and environment sections
- Note the port is Linux only

### <!-- 4 -->⚡ Performance

- Read only the headers needed for binary metadata

### <!-- 5 -->🎨 Styling

- Format the tree with dfmt

### <!-- 6 -->🧪 Testing

- Port asset, config, tag and version test coverage

### <!-- 7 -->⚙️ Miscellaneous Tasks

- Allow a build-only dry run without publishing
- Release static amd64 and arm64 binaries
- Replace the makefile and lockfiles with oslo recipes
- Remove Go sources and update docs for the D port

### Build

- Update deps hash for the mochafizz bump
- Pin mochafizz with the musl termios fix
- Keep the nix dependency lock in step with dub
- Strip dead code and symbols from release builds
- Replace Go toolchain with dub, ldc and nix packaging
- Scaffold dub project for D port

## [0.4.0] - 2026-08-07

### <!-- 3 -->📚 Documentation

- Rename to geto
- Better docs

## [0.3.0] - 2026-07-31

### <!-- 0 -->⛰️  Features

- Introduce asset-selection learning model

### <!-- 7 -->⚙️ Miscellaneous Tasks

- Improve binary static linking and verification
- Remove all support for macOS

## [0.2.3] - 2026-07-05

### <!-- 0 -->⛰️  Features

- System and user config path handling

### <!-- 7 -->⚙️ Miscellaneous Tasks

- Changes

## [0.2.2] - 2026-07-02

### <!-- 0 -->⛰️  Features

- Cache repository descriptions in state file

## [0.2.1] - 2026-07-02

### <!-- 0 -->⛰️  Features

- Changes

## [0.2.0] - 2026-07-02

### <!-- 0 -->⛰️  Features

- Changes

## [0.1.20] - 2026-06-28

### <!-- 0 -->⛰️  Features

- Improve asset filtering and add ability to forget selections
- Automatically patch ELF binaries for host compatibility

## [0.1.19] - 2026-06-19

### <!-- 0 -->⛰️  Features

- Add overlay system for TUI modals

## [0.1.18] - 2026-06-19

### <!-- 0 -->⛰️  Features

- Add interactive binary naming during install

## [0.1.17] - 2026-06-19

### <!-- 0 -->⛰️  Features

- Prefer binaries over AppImages in asset filtering

## [0.1.16] - 2026-06-17

### <!-- 0 -->⛰️  Features

- Normalize empty providers from URL host

## [0.1.15] - 2026-06-17

### <!-- 0 -->⛰️  Features

- Migrate RemoteName field to state file

## [0.1.14] - 2026-06-17

### <!-- 0 -->⛰️  Features

- Improve install logic and asset filtering

### <!-- 1 -->🐛 Bug Fixes

- Fix the `preferMusl` function

## [0.1.13] - 2026-06-17

### <!-- 0 -->⛰️  Features

- Add asset auto-selection based on libc preference

## [0.1.12] - 2026-06-17

### <!-- 0 -->⛰️  Features

- Prioritize archive types based on OS

## [0.1.10] - 2026-06-17

### <!-- 0 -->⛰️  Features

- Improve logic for selecting files within archives

## [0.1.9] - 2026-06-17

### <!-- 0 -->⛰️  Features

- Improve asset selection and UI

## [0.1.8] - 2026-06-17

### <!-- 0 -->⛰️  Features

- Improve progress bar alignment and readability

### <!-- 7 -->⚙️ Miscellaneous Tasks

- Add license, acknowledgments, and README updates

## [0.1.7] - 2026-06-17

### <!-- 0 -->⛰️  Features

- Introduce pretty and uniform terminal output

## [0.1.6] - 2026-06-17

### <!-- 0 -->⛰️  Features

- Implement interactive UI for prompts and selections

## [0.1.5] - 2026-06-17

### <!-- 0 -->⛰️  Features

- Add download progress bar to asset processing

## [0.1.4] - 2026-06-17

### <!-- 0 -->⛰️  Features

- Rework naming of config files

## [0.1.2] - 2026-06-17

### <!-- 0 -->⛰️  Features

- Rewrite
- Rewrite

