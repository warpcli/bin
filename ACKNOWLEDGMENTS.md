# Acknowledgments

`geto` is a hard fork of [**marcosnils/bin**](https://github.com/marcosnils/bin) by
**Marcos Lilljedahl** and its contributors.

Marcos built the original, elegant foundation this project stands on — the
provider abstraction (GitHub, GitLab, Codeberg, HashiCorp, `go install`),
the asset scoring/extraction logic, and the whole idea of managing standalone
release binaries without a package manager. Enormous thanks for the years of
work that made this possible. 🙏

This fork builds on that base with a single tagged config, repository
descriptions, a Bubble Tea TUI, and a reworked CLI. It would not exist without
the upstream project.

- Upstream: https://github.com/marcosnils/bin
- This fork: https://github.com/termworks/geto

The original code is MIT licensed; this fork keeps the MIT license and preserves
the original copyright alongside the fork's — see [LICENSE](./LICENSE).

## Standing on the shoulders of giants

`geto` also leans heavily on the wonderful [Charm](https://github.com/charmbracelet)
ecosystem — [Bubble Tea](https://github.com/charmbracelet/bubbletea),
[Bubbles](https://github.com/charmbracelet/bubbles), and
[Lip Gloss](https://github.com/charmbracelet/lipgloss) — for the TUI and the
pretty CLI output, plus [Cobra](https://github.com/spf13/cobra) for the command
layer and the many provider SDKs it talks to.
