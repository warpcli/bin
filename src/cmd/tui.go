package cmd

import (
	"debug/elf"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/bresilla/geto/src/pkg/assets"
	"github.com/bresilla/geto/src/pkg/config"
	"github.com/bresilla/geto/src/pkg/providers"
	"github.com/bresilla/geto/src/pkg/ui"
	"github.com/caarlos0/log"
	"github.com/charmbracelet/bubbles/cursor"
	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/list"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	hcversion "github.com/hashicorp/go-version"
	"github.com/spf13/cobra"
)

type tuiCmd struct {
	cmd *cobra.Command
}

func newTuiCmd() *tuiCmd {
	root := &tuiCmd{}
	cmd := &cobra.Command{
		Use:   "tui",
		Short: "Launch the interactive terminal UI",
		// Hidden: bare `bin` launches this; there's no need to advertise it.
		Hidden:        true,
		SilenceUsage:  true,
		SilenceErrors: true,
		Args:          cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runTUI()
		},
	}
	root.cmd = cmd
	return root
}

// runTUI silences the package logger and download progress bar (they'd corrupt
// the full-screen UI) and runs the Bubble Tea program.
func runTUI() error {
	origLog := log.Log
	log.Log = log.New(io.Discard)
	assets.Quiet = true
	defer func() {
		log.Log = origLog
		assets.Quiet = false
	}()

	if _, err := tea.NewProgram(newTUIModel(), tea.WithAltScreen()).Run(); err != nil {
		return err
	}
	return nil
}

// ---- messages ----

type checkResultMsg struct {
	path   string
	latest string
	err    error
}

type updateResultMsg struct {
	path    string
	bin     *config.Binary // non-nil when a new version was installed
	version string
	updated bool
	err     error
}

// ---- list item ----

type binRow struct {
	b    *config.Binary
	path string // expanded

	// local metadata (computed from the file on disk)
	size int64
	arch string
	libc string

	// network metadata
	latest string

	checking bool
	note     string // transient per-row status note
}

type binItem struct{ r *binRow }

func (i binItem) FilterValue() string { return filepath.Base(i.r.path) }

// ---- custom delegate: full-width, multi-line rows with a separator ----

type binDelegate struct{}

func (binDelegate) Height() int                         { return 3 } // name / meta / description
func (binDelegate) Spacing() int                        { return 0 }
func (binDelegate) Update(tea.Msg, *list.Model) tea.Cmd { return nil }

func (d binDelegate) Render(w io.Writer, m list.Model, index int, item list.Item) {
	it, ok := item.(binItem)
	if !ok {
		return
	}
	r := it.r

	width := m.Width()
	if width <= 0 {
		width = 80
	}
	selected := index == m.Index()

	// Alternating row shades; selected row is brighter (closer to the accent).
	bg := ui.RowBg
	switch {
	case selected:
		bg = ui.RowBgSelected
	case index%2 == 1:
		bg = ui.RowBgAlt
	}
	base := lipgloss.NewStyle().Background(bg)

	// cell renders text in a fixed-width column carrying the row background, so
	// the whole row keeps a solid background and columns line up across rows.
	cell := func(fg lipgloss.Color, wdt int, s string, right, bold bool) string {
		if wdt < 1 {
			wdt = 1
		}
		st := base.Foreground(fg).Width(wdt).Bold(bold)
		if right {
			st = st.Align(lipgloss.Right)
		}
		return st.Render(truncate(s, wdt))
	}
	line := func(s string) string { return base.Width(width).Render(s) }

	barTxt := "  "
	if selected {
		barTxt = "┃ "
	}
	bar := base.Foreground(ui.ColorPrimary).Render(barTxt)
	inner := width - 2 // minus the 2-col bar/indent

	// ---- line 1: ● name .................................. version ----
	statusFg := ui.ColorOK
	if _, err := os.Stat(r.path); err != nil {
		statusFg = ui.ColorErr
	}
	nameFg := ui.ColorText
	if selected {
		nameFg = ui.ColorPrimary
	}
	name := filepath.Base(r.path)
	if r.b.Pinned {
		name += " ★"
	}

	verTxt, verFg := dash(r.b.Version), ui.ColorMuted
	switch {
	case r.checking:
		verTxt = "working…"
	case r.note != "":
		verTxt = r.note
	case r.latest != "" && isNewer(r.b.Version, r.latest):
		verTxt, verFg = r.b.Version+" ↑ "+r.latest, ui.ColorWarn
	case r.latest != "":
		verTxt, verFg = r.b.Version+" ✓", ui.ColorOK
	}
	verCol := 28
	nameCol := inner - 2 - verCol
	line1 := line(bar +
		cell(statusFg, 2, "●", false, false) +
		cell(nameFg, nameCol, name, false, true) +
		cell(verFg, verCol, verTxt, true, false))

	// ---- line 2: repo  arch  libc  size  tags (aligned columns) ----
	archCol, libcCol, sizeCol, tagsCol := 8, 8, 9, 18
	repoCol := inner - archCol - libcCol - sizeCol - tagsCol
	line2 := line(bar +
		cell(ui.ColorTag, repoCol, repoShort(r.b.URL), false, false) +
		cell(ui.ColorMuted, archCol, dash(r.arch), false, false) +
		cell(ui.ColorMuted, libcCol, dash(r.libc), false, false) +
		cell(ui.ColorMuted, sizeCol, sizeStr(r.size), false, false) +
		cell(ui.ColorTag, tagsCol, strings.Join(binTags(r.b), ","), false, false))

	// ---- line 3: repo description (falls back to the local path) ----
	info := r.b.Description
	if info == "" {
		info = r.path
	}
	line3 := line(bar + base.Foreground(ui.ColorMuted).Italic(true).Width(inner).Render(truncate(info, inner)))

	fmt.Fprint(w, line1+"\n"+line2+"\n"+line3)
}

// ---- keymap ----

type listKeyMap struct {
	Update key.Binding
	Check  key.Binding
	Pin    key.Binding
	Edit   key.Binding
	Forget key.Binding
	Open   key.Binding
	Remove key.Binding
	Tag    key.Binding
}

func newListKeys() listKeyMap {
	return listKeyMap{
		Update: key.NewBinding(key.WithKeys("u"), key.WithHelp("u", "update")),
		Check:  key.NewBinding(key.WithKeys("r"), key.WithHelp("r", "check all")),
		Pin:    key.NewBinding(key.WithKeys("p"), key.WithHelp("p", "pin")),
		Edit:   key.NewBinding(key.WithKeys("e"), key.WithHelp("e", "edit")),
		Forget: key.NewBinding(key.WithKeys("m"), key.WithHelp("m", "forget choice")),
		Open:   key.NewBinding(key.WithKeys("o"), key.WithHelp("o", "open repo")),
		Remove: key.NewBinding(key.WithKeys("d", "x"), key.WithHelp("d", "remove")),
		Tag:    key.NewBinding(key.WithKeys("t"), key.WithHelp("t", "tag")),
	}
}

// ---- model ----

type tuiModel struct {
	tags       []string // selectable tag scopes, "all" first
	tagIdx     int
	rows       []*binRow
	list       list.Model
	keys       listKeyMap
	app        lipgloss.Style
	busy       int
	confirm    bool
	confirmTo  string
	confirmYes bool

	width, height int

	// edit popup state
	editing    bool
	editRow    *binRow
	inputs     []textinput.Model
	editLabels []string
	editFocus  int
}

func newTUIModel() tuiModel {
	keys := newListKeys()

	l := list.New(nil, binDelegate{}, 0, 0)
	l.Styles.Title = lipgloss.NewStyle().
		Foreground(ui.ColorText).Background(ui.ColorPrimary).Bold(true).Padding(0, 1)
	l.SetShowStatusBar(true)
	l.SetStatusBarItemName("binary", "binaries")
	l.SetFilteringEnabled(true)
	l.StatusMessageLifetime = 4 * time.Second
	l.AdditionalShortHelpKeys = func() []key.Binding {
		return []key.Binding{keys.Update, keys.Check, keys.Pin, keys.Edit, keys.Forget, keys.Open, keys.Remove, keys.Tag}
	}
	l.AdditionalFullHelpKeys = func() []key.Binding {
		return []key.Binding{keys.Update, keys.Check, keys.Pin, keys.Edit, keys.Forget, keys.Open, keys.Remove, keys.Tag}
	}
	// Sensible initial size so there's content before the first WindowSizeMsg
	// (and on terminals that don't report a size).
	l.SetSize(80, 20)

	m := tuiModel{
		list: l,
		keys: keys,
		app:  lipgloss.NewStyle().Padding(1, 2),
	}
	m.tags = collectTagScopes()
	m.rebuildRows()
	return m
}

// collectTagScopes returns "all" followed by the sorted distinct tags.
func collectTagScopes() []string {
	set := map[string]struct{}{}
	for _, b := range config.Get().Bins {
		if b == nil {
			continue
		}
		for _, t := range binTags(b) {
			set[t] = struct{}{}
		}
	}
	tags := make([]string, 0, len(set))
	for t := range set {
		tags = append(tags, t)
	}
	sort.Strings(tags)
	return append([]string{"all"}, tags...)
}

func (m tuiModel) currentScope() string { return m.tags[m.tagIdx] }

// rebuildRows recomputes the visible rows for the active tag scope, preserving
// per-row notes/latest already gathered, and refreshes the list items.
func (m *tuiModel) rebuildRows() {
	prev := map[string]*binRow{}
	for _, r := range m.rows {
		prev[r.path] = r
	}

	scope := m.currentScope()
	keys := make([]string, 0, len(config.Get().Bins))
	for k := range config.Get().Bins {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	rows := make([]*binRow, 0, len(keys))
	items := make([]list.Item, 0, len(keys))
	for _, k := range keys {
		b := config.Get().Bins[k]
		if b == nil {
			continue
		}
		if scope != "all" && !binHasAnyTag(b, []string{scope}) {
			continue
		}
		p := os.ExpandEnv(b.Path)
		r := &binRow{b: b, path: p}
		r.size, r.arch, r.libc = localMeta(p)
		if old, ok := prev[p]; ok {
			r.latest, r.checking, r.note = old.latest, old.checking, old.note
		}
		rows = append(rows, r)
		items = append(items, binItem{r})
	}
	m.rows = rows
	m.list.Title = "geto · " + scope
	idx := m.list.Index()
	m.list.SetItems(items)
	if idx >= 0 && idx < len(items) {
		m.list.Select(idx)
	}
}

func (m tuiModel) selectedRow() *binRow {
	if it, ok := m.list.SelectedItem().(binItem); ok {
		return it.r
	}
	return nil
}

func (m tuiModel) rowByPath(p string) *binRow {
	for _, r := range m.rows {
		if r.path == p {
			return r
		}
	}
	return nil
}

func (m tuiModel) Init() tea.Cmd { return nil }

func (m tuiModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		if msg.Width <= 0 || msg.Height <= 0 {
			return m, nil
		}
		m.width, m.height = msg.Width, msg.Height
		h, v := m.app.GetFrameSize()
		m.list.SetSize(msg.Width-h, msg.Height-v)
		return m, nil

	case checkResultMsg:
		m.busy--
		if r := m.rowByPath(msg.path); r != nil {
			r.checking = false
			if msg.err != nil {
				r.note = ui.ErrStyle.Render("error")
			} else {
				r.latest = msg.latest
				r.note = ""
			}
		}
		if m.busy <= 0 {
			m.busy = 0
			m.list.StopSpinner()
			return m, m.list.NewStatusMessage(ui.OKStyle.Render("check complete"))
		}
		return m, nil

	case updateResultMsg:
		m.busy--
		if m.busy < 0 {
			m.busy = 0
		}
		var status string
		if r := m.rowByPath(msg.path); r != nil {
			r.checking = false
			switch {
			case msg.err != nil:
				r.note = ui.ErrStyle.Render("failed")
				status = ui.ErrStyle.Render("update failed: " + msg.err.Error())
			case msg.updated:
				if msg.bin != nil {
					_ = config.UpsertBinary(msg.bin)
					r.b = config.Get().Bins[msg.bin.Path]
				}
				r.latest = ""
				r.note = ui.OKStyle.Render("updated")
				status = ui.OKStyle.Render(fmt.Sprintf("updated %s → %s", filepath.Base(msg.path), msg.version))
			default:
				r.note = ui.OKStyle.Render("up to date")
				status = filepath.Base(msg.path) + " already up to date"
			}
		}
		if m.busy == 0 {
			m.list.StopSpinner()
		}
		return m, m.list.NewStatusMessage(status)

	case tea.KeyMsg:
		return m.handleKey(msg)
	}

	// While editing, forward non-key messages (e.g. cursor blink) to inputs.
	if m.editing {
		var cmds []tea.Cmd
		for i := range m.inputs {
			var c tea.Cmd
			m.inputs[i], c = m.inputs[i].Update(msg)
			cmds = append(cmds, c)
		}
		return m, tea.Batch(cmds...)
	}

	var c tea.Cmd
	m.list, c = m.list.Update(msg)
	return m, c
}

func (m tuiModel) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	if msg.String() == "ctrl+c" {
		return m, tea.Quit
	}

	if m.editing {
		return m.handleEditKey(msg)
	}

	// Delete confirmation dialog captures input first.
	if m.confirm {
		switch msg.String() {
		case "left", "right", "h", "l", "tab":
			m.confirmYes = !m.confirmYes
			return m, nil
		case "y", "Y":
			m.confirmYes = true
			return m.doRemove()
		case "n", "N", "esc":
			m.confirm, m.confirmTo = false, ""
			return m, m.list.NewStatusMessage("remove cancelled")
		case "enter":
			if m.confirmYes {
				return m.doRemove()
			}
			m.confirm, m.confirmTo = false, ""
			return m, m.list.NewStatusMessage("remove cancelled")
		}
		return m, nil
	}

	// While typing a filter, the list owns all keys.
	if m.list.FilterState() == list.Filtering {
		var c tea.Cmd
		m.list, c = m.list.Update(msg)
		return m, c
	}

	switch {
	case msg.String() == "q":
		return m, tea.Quit

	case key.Matches(msg, m.keys.Tag):
		m.tagIdx = (m.tagIdx + 1) % len(m.tags)
		m.rebuildRows()
		return m, m.list.NewStatusMessage("tag: " + m.currentScope())

	case key.Matches(msg, m.keys.Pin):
		r := m.selectedRow()
		if r == nil {
			return m, nil
		}
		r.b.Pinned = !r.b.Pinned
		_ = config.UpsertBinary(r.b)
		verb := "unpinned"
		if r.b.Pinned {
			verb = "pinned"
		}
		return m, m.list.NewStatusMessage(verb + " " + filepath.Base(r.path))

	case key.Matches(msg, m.keys.Edit):
		if r := m.selectedRow(); r != nil {
			return m.startEdit(r)
		}
		return m, nil

	case key.Matches(msg, m.keys.Forget):
		r := m.selectedRow()
		if r == nil {
			return m, nil
		}
		if err := config.ForgetBinarySelection(r.b.Path); err != nil {
			return m, m.list.NewStatusMessage(ui.ErrStyle.Render("forget failed: " + err.Error()))
		}
		if b := config.Get().Bins[r.b.Path]; b != nil {
			r.b = b
		}
		r.note = ui.OKStyle.Render("forgot choice")
		return m, m.list.NewStatusMessage("forgot saved choice for " + filepath.Base(r.path))

	case key.Matches(msg, m.keys.Open):
		r := m.selectedRow()
		if r == nil || r.b.URL == "" {
			return m, nil
		}
		return m, tea.Batch(openURLCmd(r.b.URL), m.list.NewStatusMessage("opening "+repoShort(r.b.URL)))

	case key.Matches(msg, m.keys.Remove):
		if r := m.selectedRow(); r != nil {
			m.confirm = true
			m.confirmTo = r.path
			m.confirmYes = false
		}
		return m, nil

	case key.Matches(msg, m.keys.Check):
		var cmds []tea.Cmd
		for _, r := range m.rows {
			r.checking = true
			r.note = ""
			m.busy++
			cmds = append(cmds, checkCmd(r.b))
		}
		if len(cmds) == 0 {
			return m, nil
		}
		cmds = append(cmds, m.list.StartSpinner(), m.list.NewStatusMessage("checking "+fmt.Sprint(len(m.rows))+" binaries…"))
		return m, tea.Batch(cmds...)

	case key.Matches(msg, m.keys.Update):
		r := m.selectedRow()
		if r == nil {
			return m, nil
		}
		if r.b.Pinned {
			return m, m.list.NewStatusMessage(filepath.Base(r.path) + " is pinned (p to unpin)")
		}
		r.checking = true
		r.note = ui.MutedStyle.Render("updating…")
		m.busy++
		return m, tea.Batch(
			performUpdateCmd(r.b),
			m.list.StartSpinner(),
			m.list.NewStatusMessage("updating "+filepath.Base(r.path)+"…"),
		)
	}

	var c tea.Cmd
	m.list, c = m.list.Update(msg)
	return m, c
}

// doRemove deletes the binary currently pending confirmation.
func (m tuiModel) doRemove() (tea.Model, tea.Cmd) {
	path := m.confirmTo
	m.confirm, m.confirmTo = false, ""
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return m, m.list.NewStatusMessage(ui.ErrStyle.Render("remove failed: " + err.Error()))
	}
	for k, b := range config.Get().Bins {
		if b != nil && os.ExpandEnv(b.Path) == path {
			_ = config.RemoveBinaries([]string{k})
			break
		}
	}
	m.rebuildRows()
	return m, m.list.NewStatusMessage("removed " + filepath.Base(path))
}

func (m tuiModel) View() string {
	base := m.app.Render(m.list.View())
	switch {
	case m.editing:
		return ui.Overlay(ui.Dim(base), m.editDialog())
	case m.confirm:
		return ui.Overlay(ui.Dim(base), m.confirmDialog())
	}
	return base
}

func (m tuiModel) confirmDialog() string {
	name := filepath.Base(m.confirmTo)
	body := ui.MutedStyle.Render("Remove ") + ui.AccentStyle.Render(name) +
		ui.MutedStyle.Render(" and forget it?") + "\n\n" +
		"  " + ui.Button("Yes", m.confirmYes) + "   " + ui.Button("No", !m.confirmYes)
	return ui.Dialog("Remove binary", body, "←/→ choose · y/n · enter")
}

// ---- edit popup ----

var editFields = []string{"URL", "Provider", "Tags (comma-separated)", "Description"}

func (m tuiModel) startEdit(r *binRow) (tea.Model, tea.Cmd) {
	vals := []string{
		r.b.URL,
		r.b.Provider,
		strings.Join(binTags(r.b), ","),
		r.b.Description,
	}
	m.inputs = make([]textinput.Model, len(editFields))
	m.editLabels = editFields
	for i := range editFields {
		ti := textinput.New()
		ti.Prompt = ""
		ti.CharLimit = 1024
		ti.Width = 60
		ti.Cursor.SetMode(cursor.CursorStatic)
		ti.SetValue(vals[i])
		m.inputs[i] = ti
	}
	m.editing = true
	m.editRow = r
	m.editFocus = 0
	m.focusOnly()
	return m, nil
}

func (m *tuiModel) focusOnly() {
	for i := range m.inputs {
		if i == m.editFocus {
			m.inputs[i].Focus()
		} else {
			m.inputs[i].Blur()
		}
	}
}

func (m tuiModel) handleEditKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc":
		m.editing = false
		m.inputs = nil
		return m, m.list.NewStatusMessage("edit cancelled")

	case "enter", "ctrl+s":
		r := m.editRow
		r.b.URL = strings.TrimSpace(m.inputs[0].Value())
		r.b.Provider = strings.TrimSpace(m.inputs[1].Value())
		tags := []string{}
		for _, t := range strings.Split(m.inputs[2].Value(), ",") {
			if t = strings.TrimSpace(t); t != "" {
				tags = append(tags, t)
			}
		}
		if len(tags) == 0 {
			tags = []string{"default"}
		}
		r.b.Tags = tags
		r.b.Description = strings.TrimSpace(m.inputs[3].Value())
		_ = config.UpsertBinary(r.b)

		m.editing = false
		m.inputs = nil
		m.tags = collectTagScopes()
		if m.tagIdx >= len(m.tags) {
			m.tagIdx = 0
		}
		m.rebuildRows()
		return m, m.list.NewStatusMessage("saved " + filepath.Base(r.path))

	case "tab", "down":
		m.editFocus = (m.editFocus + 1) % len(m.inputs)
		m.focusOnly()
		return m, nil

	case "shift+tab", "up":
		m.editFocus = (m.editFocus - 1 + len(m.inputs)) % len(m.inputs)
		m.focusOnly()
		return m, nil
	}

	var c tea.Cmd
	m.inputs[m.editFocus], c = m.inputs[m.editFocus].Update(msg)
	return m, c
}

func (m tuiModel) editDialog() string {
	var b strings.Builder
	for i := range m.inputs {
		label := "  " + ui.MutedStyle.Render(m.editLabels[i])
		if i == m.editFocus {
			label = ui.AccentStyle.Render("▸ " + m.editLabels[i])
		}
		field := lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).
			BorderForeground(ui.ColorMuted).Padding(0, 1).Width(56)
		if i == m.editFocus {
			field = field.BorderForeground(ui.ColorPrimary)
		}
		b.WriteString(label + "\n" + field.Render(m.inputs[i].View()))
		if i < len(m.inputs)-1 {
			b.WriteString("\n")
		}
	}
	return ui.Dialog("Edit  "+filepath.Base(m.editRow.path), b.String(), "tab/↑↓ move · enter save · esc cancel")
}

func valOr(s string) string {
	if s == "" {
		return ui.MutedStyle.Render("—")
	}
	return s
}

// ---- commands / helpers ----

// localMeta reads on-disk metadata (size, and for ELF binaries the architecture
// and libc flavor) without any network access.
func localMeta(path string) (size int64, arch, libc string) {
	if fi, err := os.Stat(path); err == nil {
		size = fi.Size()
	}
	f, err := elf.Open(path)
	if err != nil {
		return // not an ELF (e.g. a Windows build) or missing — size only
	}
	defer f.Close()

	arch = elfArch(f.Machine)
	libc = "static"
	for _, p := range f.Progs {
		if p.Type != elf.PT_INTERP {
			continue
		}
		raw, _ := io.ReadAll(p.Open())
		interp := strings.Trim(string(raw), "\x00")
		switch {
		case strings.Contains(interp, "musl"):
			libc = "musl"
		case strings.Contains(interp, "ld-linux"), strings.Contains(interp, "/ld-"):
			libc = "glibc"
		default:
			libc = "dynamic"
		}
		break
	}
	return
}

func elfArch(m elf.Machine) string {
	switch m {
	case elf.EM_X86_64:
		return "amd64"
	case elf.EM_AARCH64:
		return "arm64"
	case elf.EM_386:
		return "386"
	case elf.EM_ARM:
		return "arm"
	case elf.EM_RISCV:
		return "riscv64"
	case elf.EM_PPC64:
		return "ppc64"
	case elf.EM_S390:
		return "s390x"
	default:
		return strings.TrimPrefix(m.String(), "EM_")
	}
}

// truncate shortens a plain string to w columns, adding an ellipsis.
func truncate(s string, w int) string {
	if w <= 1 {
		return ""
	}
	rs := []rune(s)
	if len(rs) <= w {
		return s
	}
	return string(rs[:w-1]) + "…"
}

func dash(s string) string {
	if s == "" {
		return "—"
	}
	return s
}

func sizeStr(n int64) string {
	if n <= 0 {
		return "—"
	}
	return humanSize(n)
}

func humanSize(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%dB", n)
	}
	div, exp := int64(unit), 0
	for x := n / unit; x >= unit; x /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f%cB", float64(n)/float64(div), "KMGT"[exp])
}

// repoShort strips the scheme from a repo URL, e.g. github.com/owner/repo.
func repoShort(u string) string {
	u = strings.TrimPrefix(u, "https://")
	u = strings.TrimPrefix(u, "http://")
	return strings.TrimSuffix(u, "/")
}

// padBetween left-aligns left and right-aligns right within width (ANSI-aware).
func padBetween(left, right string, width int) string {
	gap := width - lipgloss.Width(left) - lipgloss.Width(right)
	if gap < 1 {
		gap = 1
	}
	return left + strings.Repeat(" ", gap) + right
}

func checkCmd(b *config.Binary) tea.Cmd {
	return func() tea.Msg {
		p, err := providers.New(b.URL, b.Provider)
		if err != nil {
			return checkResultMsg{path: b.Path, err: err}
		}
		v, _, err := p.GetLatestVersion()
		return checkResultMsg{path: b.Path, latest: v, err: err}
	}
}

func performUpdateCmd(b *config.Binary) tea.Cmd {
	return func() tea.Msg {
		p, err := providers.New(b.URL, b.Provider)
		if err != nil {
			return updateResultMsg{path: b.Path, err: err}
		}
		v, u, err := p.GetLatestVersion()
		if err != nil {
			return updateResultMsg{path: b.Path, err: err}
		}
		if !isNewer(b.Version, v) {
			return updateResultMsg{path: b.Path, version: b.Version, updated: false}
		}
		np, err := providers.New(u, b.Provider)
		if err != nil {
			return updateResultMsg{path: b.Path, err: err}
		}
		res, err := np.Fetch(&providers.FetchOpts{
			PackagePath:      b.PackagePath,
			PackageName:      b.RemoteName,
			SelectedAsset:    b.SelectedAsset,
			AssetFingerprint: b.AssetFingerprint,
			NonInteractive:   true,
		})
		if err != nil {
			return updateResultMsg{path: b.Path, err: err}
		}
		hash, err := saveToDisk(res, b.Path, true)
		if err != nil {
			return updateResultMsg{path: b.Path, err: err}
		}
		nb := &config.Binary{
			RemoteName:       res.Name,
			Path:             b.Path,
			Version:          res.Version,
			Hash:             fmt.Sprintf("%x", hash),
			URL:              b.URL,
			Provider:         np.GetID(),
			PackagePath:      res.PackagePath,
			StateURL:         u,
			SelectedAsset:    res.SelectedAsset,
			AssetFingerprint: res.AssetFingerprint,
			Tags:             b.Tags,
		}
		return updateResultMsg{path: b.Path, bin: nb, version: res.Version, updated: true}
	}
}

// openURLCmd opens a URL in the user's default browser via xdg-open.
func openURLCmd(url string) tea.Cmd {
	return func() tea.Msg {
		_ = exec.Command("xdg-open", url).Start()
		return nil
	}
}

// isNewer reports whether latest is a strictly higher version than current.
func isNewer(current, latest string) bool {
	if current == latest {
		return false
	}
	c, e1 := hcversion.NewVersion(current)
	l, e2 := hcversion.NewVersion(latest)
	if e1 == nil && e2 == nil {
		return l.GreaterThan(c)
	}
	return current != latest
}
