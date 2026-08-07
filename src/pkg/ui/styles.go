// Package ui provides styling and terminal rendering utilities.
package ui

import (
	"bufio"
	"os"
	"strconv"
	"strings"

	"github.com/charmbracelet/lipgloss"
	ltable "github.com/charmbracelet/lipgloss/table"
	"golang.org/x/term"
)

// Palette defines terminal colors for CLI and TUI components.
var (
	ColorPrimary = lipgloss.Color("1")
	ColorOK      = lipgloss.Color("2")
	ColorWarn    = lipgloss.Color("3")
	ColorErr     = lipgloss.Color("9")
	ColorTag     = lipgloss.Color("6")
	ColorMuted   = lipgloss.Color("8")
	ColorText    = lipgloss.Color("15")

	RowBg         = lipgloss.Color("232")
	RowBgAlt      = lipgloss.Color("235")
	RowBgSelected = lipgloss.Color("237")
)

// Reusable lipgloss styles built from palette colors.
var (
	TitleStyle  lipgloss.Style
	AccentStyle lipgloss.Style
	MutedStyle  lipgloss.Style
	OKStyle     lipgloss.Style
	WarnStyle   lipgloss.Style
	ErrStyle    lipgloss.Style
	TagStyle    lipgloss.Style
	PinStyle    lipgloss.Style
	BorderStyle lipgloss.Style
)

func init() { applyStyles() }

func applyStyles() {
	TitleStyle = lipgloss.NewStyle().Bold(true).Foreground(ColorText).Background(ColorPrimary).Padding(0, 1)
	AccentStyle = lipgloss.NewStyle().Foreground(ColorPrimary).Bold(true)
	MutedStyle = lipgloss.NewStyle().Foreground(ColorMuted)
	OKStyle = lipgloss.NewStyle().Foreground(ColorOK)
	WarnStyle = lipgloss.NewStyle().Foreground(ColorWarn)
	ErrStyle = lipgloss.NewStyle().Foreground(ColorErr)
	TagStyle = lipgloss.NewStyle().Foreground(ColorTag)
	PinStyle = lipgloss.NewStyle().Foreground(ColorWarn)
	BorderStyle = lipgloss.NewStyle().Foreground(ColorMuted)
}

// DefaultThemeConf defines default theme settings.
const DefaultThemeConf = `# bin TUI theme — colors are terminal palette indexes (0-255) or hex (#aabbcc).
# Palette names recolor automatically with pywal-style tools. The 232..255
# grayscale ramp is handy for subtle row shading.

# foreground colors
accent = 1     # highlights, selection, title background
text   = 15    # primary text
muted  = 8     # secondary text / separators
ok     = 2     # up to date / present
warn   = 3     # update available / pinned
err    = 9     # missing / errors
tag    = 6     # tag chips & repo

# TUI row backgrounds (alternating + selected)
row_bg          = 232  # even rows
row_bg_alt      = 235  # odd rows
row_bg_selected = 237  # selected row
`

// EnsureTheme writes and loads theme configuration at path.
func EnsureTheme(path string) {
	if path == "" {
		return
	}
	if _, err := os.Stat(path); os.IsNotExist(err) {
		_ = os.WriteFile(path, []byte(DefaultThemeConf), 0o644)
	}
	_ = LoadTheme(path)
}

// LoadTheme loads theme color overrides from path.
func LoadTheme(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()

	set := func(c *lipgloss.Color, v string) {
		if v != "" {
			*c = lipgloss.Color(v)
		}
	}

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, val, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		val = strings.TrimSpace(val)
		if i := strings.IndexByte(val, '#'); i >= 0 {
			val = strings.TrimSpace(val[:i])
		}
		switch key {
		case "accent":
			set(&ColorPrimary, val)
		case "text":
			set(&ColorText, val)
		case "muted":
			set(&ColorMuted, val)
		case "ok":
			set(&ColorOK, val)
		case "warn":
			set(&ColorWarn, val)
		case "err":
			set(&ColorErr, val)
		case "tag":
			set(&ColorTag, val)
		case "row_bg":
			set(&RowBg, val)
		case "row_bg_alt":
			set(&RowBgAlt, val)
		case "row_bg_selected":
			set(&RowBgSelected, val)
		}
	}
	applyStyles()
	return sc.Err()
}

// Banner renders a title chip.
func Banner(s string) string { return TitleStyle.Render(s) }

// Rule renders a horizontal line.
func Rule() string {
	return MutedStyle.Render(strings.Repeat("─", TerminalWidth()))
}

// RepoShort strips the scheme from a repo URL.
func RepoShort(u string) string { return repoShortURL(u) }

// Tags renders tags as styled text.
func Tags(tags []string) string {
	out := make([]string, 0, len(tags))
	for _, t := range tags {
		out = append(out, TagStyle.Render(t))
	}
	return strings.Join(out, " ")
}

// StatusDot renders a status indicator.
func StatusDot(ok bool) string {
	if ok {
		return OKStyle.Render("● ok")
	}
	return ErrStyle.Render("● missing")
}

// ListRow holds rendered list data.
type ListRow struct {
	Path    string
	Version string
	Tags    []string
	URL     string
	OK      bool
	Pinned  bool
}

// ListTable renders a binary list table.
func ListTable(rows []ListRow, width int) string {
	if width < 40 {
		width = 40
	}
	budget := width - 16
	if budget < 40 {
		budget = 40
	}
	verW, tagW, stW := 12, 16, 9
	flex := budget - verW - tagW - stW
	if flex < 24 {
		flex = 24
	}
	nameW := flex * 11 / 20
	repoW := flex - nameW

	t := ltable.New().
		Border(lipgloss.RoundedBorder()).
		BorderStyle(BorderStyle).
		Width(width).
		Headers("BINARY", "VERSION", "TAGS", "STATUS", "REPO").
		StyleFunc(func(row, col int) lipgloss.Style {
			st := lipgloss.NewStyle().Padding(0, 1)
			if row == ltable.HeaderRow {
				return st.Bold(true).Foreground(ColorPrimary)
			}
			switch col {
			case 1:
				if row >= 0 && row < len(rows) && rows[row].Pinned {
					return st.Foreground(ColorWarn)
				}
			case 2:
				return st.Foreground(ColorTag)
			case 3:
				if row >= 0 && row < len(rows) && !rows[row].OK {
					return st.Foreground(ColorErr)
				}
				return st.Foreground(ColorOK)
			case 4:
				return st.Foreground(ColorMuted)
			}
			return st
		})

	for _, r := range rows {
		ver := r.Version
		if r.Pinned {
			ver = "★ " + ver
		}
		status := "● ok"
		if !r.OK {
			status = "● missing"
		}
		t.Row(
			clip(r.Path, nameW),
			clip(ver, verW),
			clip(strings.Join(r.Tags, ","), tagW),
			status,
			clip(repoShortURL(r.URL), repoW),
		)
	}
	return t.String()
}

// clip truncates s to w columns.
func clip(s string, w int) string {
	if w <= 0 {
		return ""
	}
	r := []rune(s)
	if len(r) <= w {
		return s
	}
	if w == 1 {
		return "…"
	}
	return string(r[:w-1]) + "…"
}

// repoShortURL strips the scheme from a repo URL.
func repoShortURL(u string) string {
	u = strings.TrimPrefix(u, "https://")
	u = strings.TrimPrefix(u, "http://")
	return strings.TrimSuffix(u, "/")
}

// TerminalWidth returns the current terminal width.
func TerminalWidth() int {
	if w, _, err := term.GetSize(int(os.Stdout.Fd())); err == nil && w > 0 {
		return w
	}
	if c := os.Getenv("COLUMNS"); c != "" {
		if n, err := strconv.Atoi(c); err == nil && n > 0 {
			return n
		}
	}
	return 100
}
