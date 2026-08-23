# geto

<p align="center">
  <img src="./misc/screenshot.png" alt="geto TUI screenshot" width="100%">
</p>

Effortless binary manager. Install, update, and organize standalone binaries pulled straight from release pages — no package manager, no build step.

`geto` downloads release assets from GitHub, GitLab, Codeberg, HashiCorp releases, or `go install`, picks the right artifact for your OS/arch, unpacks it if needed, and keeps track of what's installed so you can update everything in one command.

> A hard fork of [marcosnils/bin](https://github.com/marcosnils/bin) with a single tagged config, repo descriptions, and a full TUI.

---

## Install

Grab a binary from the [releases page](https://github.com/bresilla/geto/releases),
or build from source:

```sh
git clone https://github.com/bresilla/geto
cd geto
make build      # produces ./geto
```

Building needs [LDC](https://github.com/ldc-developers/ldc) and
[dub](https://dub.pm), plus the OpenSSL, xz, bzip2, zstd and zlib development
headers. The flake's dev shell (`nix develop`) provides all of them.

> **Linux only.** The D rewrite builds on
> [mochafizz](https://github.com/bresilla/mochafizz), which targets Linux, so
> the Windows binaries the Go releases used to ship are no longer produced.

On first run, `geto` picks a download directory from your `PATH` (e.g. `~/.local/bin`) and creates its config.

---

## Quick start

```sh
geto install github.com/sharkdp/bat     # install (alias: add, i)
geto                                     # launch the interactive TUI
geto list                                # plain table of everything
geto update                              # update the "default" tier
geto update bat                          # update a single binary
geto remove bat                          # uninstall (alias: rm, uninstall, delete)
```

Running `geto` with no arguments opens the **TUI** on a real terminal, and falls back to `list` when piped.

---

## Commands

| Command | Aliases | What it does |
| --- | --- | --- |
| `install <url> [name\|path]` | `add`, `i` | Install a binary from a repo/URL |
| `update [name…]` | `u` | Update binaries (default tier, or named ones) |
| `ensure [name…]` | `e` | Reinstall anything missing or hash-mismatched |
| `list` | `ls` | Print a table of managed binaries |
| `remove <name…>` | `rm`, `uninstall`, `delete` | Delete the binary and forget it |
| `prune` | | Forget entries whose files no longer exist |
| `pin` / `unpin` <name…> | | Freeze / unfreeze a binary's version |
| `tag …` | | Manage tags/tiers (see below) |
| `describe [name…]` | | Fetch & store repository descriptions |

Useful flags on `update`:

- `--dry-run` — report what would update, change nothing
- `-y, --yes` — skip the confirmation prompt
- `-r, --recheck` — re-prompt for asset selection instead of reusing the remembered choice
- `-c, --continue-on-error` — keep going if one binary fails

---

## Tags / tiers

Every binary has one or more **tags**. Untagged binaries belong to `default`. A persistent `--tag/-t` flag sets the tag context for any command:

```sh
geto install -t essential github.com/junegunn/fzf   # install tagged "essential"
geto -t essential update                             # update only the "essential" tier
geto -t all list                                     # everything, regardless of tag
geto update                                          # == geto -t default update
```

- No `--tag` → acts on the **`default`** tier.
- `--tag all` → acts on **every** binary.

Change tags after the fact:

```sh
geto tag ls                          # list tags and counts
geto tag show bat                    # show a binary's tags
geto tag add essential bat fzf       # add a tag
geto tag rm  essential bat           # remove a tag (falls back to "default")
```

---

## Repository descriptions

`geto` stores each repo's one-line description in the manifest so the TUI can show it offline. New installs fetch it automatically; backfill existing entries with:

```sh
geto -t all describe          # fetch descriptions for everything missing one
geto describe --force bat     # refetch even if already present
```

For private/rate-limited repos, export a token first (see [Authentication](#authentication)).

---

## TUI

Run `geto` (no args) to open the interactive UI: a full-width list with two-line entries showing name, version + update status, repo, architecture, libc (musl/glibc/static), size, tags, and the repo description.

| Key | Action |
| --- | --- |
| `↑`/`↓`, `j`/`k`, `g`/`G` | navigate |
| `/` | fuzzy filter |
| `u` | update selected |
| `r` | check all for updates |
| `p` | pin / unpin |
| `e` | edit entry (URL, provider, tags, description) in a popup |
| `m` | forget the saved asset/archive choice for the selected binary |
| `o` | open the repository in your browser (`xdg-open`) |
| `d` / `x` | remove (with confirmation) |
| `t` | cycle the tag scope |
| `?` | toggle full help |
| `q` | quit |

### Theming (`config`)

On first run `geto` writes a `config` file. Colors are **terminal palette indexes (0–255) or hex** — so pywal-style tools recolor `geto` automatically, and the `232..255` grayscale ramp gives subtle row shading:

```ini
# foreground colors
accent = 1     text = 15    muted = 8
ok = 2         warn = 3     err = 9     tag = 6

# TUI row backgrounds (alternating + selected)
row_bg          = 232
row_bg_alt      = 235
row_bg_selected = 237
```

---

## Files

| File | Purpose |
| --- | --- |
| `$XDG_CONFIG_HOME/geto/list.json` | **Manifest** — portable: path, url, provider, tags, description |
| `$XDG_STATE_HOME/geto/config.state.json` | **State** — per-machine: version, hash, package path, pinned, selected asset, cached description |
| `$XDG_CONFIG_HOME/geto/config` | TUI colors |

The manifest and per-machine state are kept separate so the manifest is safe to share or check into dotfiles. Config resolution honors `$XDG_CONFIG_HOME`, falling back to `~/.config/geto` (or a legacy `~/.geto`).
When run as root without explicit overrides, `geto` reads `/etc/geto/list.json`,
writes `/var/lib/geto/config.state.json`, and installs into `/usr/local/bin`.

---

## Providers

| Provider | Example |
| --- | --- |
| GitHub | `geto install github.com/cli/cli` |
| GitLab | `geto install gitlab.com/gitlab-org/cli` |
| Codeberg | `geto install codeberg.org/lukeflo/bibiman` |
| HashiCorp | `geto install releases.hashicorp.com/terraform` |
| `go install` | `geto install goinstall://github.com/x/y` |

Asset selection scores candidates by OS/arch and filters out non-installable files (`.sig`, `.sha256`, `.sbom`, `.deb`, …). Your pick is remembered, so updates don't re-prompt unless the release's file layout changes (use `update -r` to force a re-pick).

---

## NixOS / Home Manager

`geto` ships a flake package plus NixOS and Home Manager modules. In Nix you
write a normal list of repositories; the module generates `list.json`, then runs
`geto --tag all ensure`. `ensure` downloads missing binaries and fills the
mutable state file with versions, hashes, remembered asset choices, and cached
repository descriptions.

```nix
{
  inputs.geto.url = "github:bresilla/geto";

  outputs = { nixpkgs, geto, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        geto.nixosModules.default
        {
          programs.geto = {
            enable = true;

            entries = [
              "github.com/rust-lang/mdBook"
              { repo = "github.com/git-town/git-town"; tag = "essential"; }
              { repo = "github.com/atuinsh/atuin"; name = "atuin"; tag = "shell"; }
            ];
          };
        }
      ];
    };
  };
}
```

For Home Manager:

```nix
{
  imports = [ inputs.geto.homeManagerModules.default ];

  programs.geto = {
    enable = true;
    entries = [
      "github.com/rust-lang/mdBook"
      { repo = "github.com/git-town/git-town"; tag = "essential"; }
    ];
  };
}
```

The generated manifest is just regular `geto` config:

```json
{
  "default_path": "/usr/local/bin",
  "bins": {
    "/usr/local/bin/git-town": {
      "path": "/usr/local/bin/git-town",
      "url": "github.com/git-town/git-town",
      "tags": ["essential"],
      "patch": true
    }
  }
}
```

For the default root/system paths, create `/etc/geto/list.json` and run:

```sh
sudo geto --tag all ensure
```

You can also point `geto` at an explicit manifest/state/install directory:

```sh
GETO_CONFIG_FILE=/tmp/geto/list.json \
GETO_STATE_FILE=/tmp/geto/state.json \
GETO_DEFAULT_PATH=/tmp/geto/bin \
GETO_NONINTERACTIVE=1 \
geto --tag all ensure
```

---

## Authentication

Set as needed in your environment:

- `GITHUB_AUTH_TOKEN` or `GITHUB_TOKEN` — GitHub API (avoids the 60 req/hr unauthenticated limit)
- `CODEBERG_TOKEN` — Codeberg
- `GHES_BASE_URL`, `GHES_UPLOAD_URL`, `GHES_AUTH_TOKEN` — GitHub Enterprise

---

## Development

`geto` is written in [D](https://dlang.org) and built with dub.

```sh
make build      # build ./geto
make install    # install to $PREFIX/bin (default ~/.local/bin)
make run ARGS='list -t all'
make test       # dub test
make verify     # fmt-check + test
make static     # fully static build (needs musl static libs — see below)
make release TYPE=minor   # cut a release via git-rel
make help       # list all targets
```

### Layout

| Path | What lives there |
| --- | --- |
| `source/geto/config.d` | manifest + state files, migrations, tag handling |
| `source/geto/assets.d` | release-asset scoring, filtering and unpacking |
| `source/geto/providers/` | GitHub, GitLab, Codeberg, HashiCorp, `go install` |
| `source/geto/ai/` | naive Bayes + neural net used to break selection ties |
| `source/geto/elf.d` | ELF parsing and interpreter/RUNPATH patching |
| `source/geto/ui/` | palette, table, progress bar and prompts |
| `source/geto/cmd/` | CLI commands and the interactive TUI |

The TUI is built on [mochafizz](https://github.com/bresilla/mochafizz).

### Static builds

Release binaries are linked fully static against musl, which needs static
archives for OpenSSL and the compression libraries. Those are only packaged for
musl, so `make static` and the release workflow run inside Alpine. See
`scripts/patch-requests-static.sh` for the one upstream gap that has to be
patched first.

## License & credits

MIT — see [LICENSE](./LICENSE). `geto` is a hard fork of
[marcosnils/bin](https://github.com/marcosnils/bin); see
[ACKNOWLEDGMENTS.md](./ACKNOWLEDGMENTS.md).
