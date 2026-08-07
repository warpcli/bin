package ui

import (
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"golang.org/x/term"
)

func interactive() bool {
	return term.IsTerminal(int(os.Stdin.Fd())) && term.IsTerminal(int(os.Stdout.Fd()))
}

const selectWindow = 6

type selectModel struct {
	title  string
	items  []string
	cursor int
	top    int
	chosen int
}

func (m selectModel) Init() tea.Cmd { return nil }

func (m *selectModel) clampWindow() {
	if m.cursor < m.top {
		m.top = m.cursor
	}
	if m.cursor >= m.top+selectWindow {
		m.top = m.cursor - selectWindow + 1
	}
	if m.top < 0 {
		m.top = 0
	}
}

func (m selectModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	k, ok := msg.(tea.KeyMsg)
	if !ok {
		return m, nil
	}
	switch s := k.String(); s {
	case "ctrl+c", "esc", "q":
		return m, tea.Quit
	case "up", "k":
		if m.cursor > 0 {
			m.cursor--
		}
	case "down", "j":
		if m.cursor < len(m.items)-1 {
			m.cursor++
		}
	case "pgup", "ctrl+u":
		m.cursor -= selectWindow
		if m.cursor < 0 {
			m.cursor = 0
		}
	case "pgdown", "ctrl+d":
		m.cursor += selectWindow
		if m.cursor > len(m.items)-1 {
			m.cursor = len(m.items) - 1
		}
	case "home", "g":
		m.cursor = 0
	case "end", "G":
		m.cursor = len(m.items) - 1
	case "enter", " ":
		m.chosen = m.cursor
		return m, tea.Quit
	default:
		if len(s) == 1 && s[0] >= '1' && s[0] <= '9' {
			if n := int(s[0] - '1'); n < len(m.items) {
				m.chosen = n
				return m, tea.Quit
			}
		}
	}
	m.clampWindow()
	return m, nil
}

func (m selectModel) View() string {
	if m.chosen >= 0 {
		return "  " + OKStyle.Render("✓ ") + m.items[m.chosen] + "\n"
	}
	var b strings.Builder
	b.WriteString(AccentStyle.Render(m.title) + "\n")

	end := m.top + selectWindow
	if end > len(m.items) {
		end = len(m.items)
	}
	if m.top > 0 {
		b.WriteString(MutedStyle.Render(fmt.Sprintf("  ↑ %d more", m.top)) + "\n")
	}
	for i := m.top; i < end; i++ {
		if i == m.cursor {
			b.WriteString(AccentStyle.Render("▸ ") + lipgloss.NewStyle().Foreground(ColorText).Bold(true).Render(m.items[i]) + "\n")
		} else {
			b.WriteString("  " + MutedStyle.Render(m.items[i]) + "\n")
		}
	}
	if end < len(m.items) {
		b.WriteString(MutedStyle.Render(fmt.Sprintf("  ↓ %d more", len(m.items)-end)) + "\n")
	}
	b.WriteString(MutedStyle.Render(fmt.Sprintf("[%d/%d] ↑/↓ move · enter select · esc cancel", m.cursor+1, len(m.items))))
	return b.String()
}

// SelectOne shows a single-choice picker and returns the chosen index.
func SelectOne(title string, items []string) (int, error) {
	if len(items) == 0 {
		return -1, io.EOF
	}
	if !interactive() {
		return selectFallback(title, items)
	}
	res, err := tea.NewProgram(selectModel{title: title, items: items, chosen: -1}).Run()
	if err != nil {
		return -1, err
	}
	fm := res.(selectModel)
	if fm.chosen < 0 {
		return -1, fmt.Errorf("selection cancelled")
	}
	return fm.chosen, nil
}

func selectFallback(title string, items []string) (int, error) {
	fmt.Printf("\n%s\n", title)
	for i, it := range items {
		fmt.Printf("  [%d] %s\n", i+1, it)
	}
	fmt.Print("Select an option: ")
	var n int
	if _, err := fmt.Scanln(&n); err != nil {
		return -1, err
	}
	if n < 1 || n > len(items) {
		return -1, fmt.Errorf("invalid option")
	}
	return n - 1, nil
}

// ---- select-or-type ----

type pickModel struct {
	title  string
	items  []string
	cursor int
	ti     textinput.Model
	result string
	done   bool
}

func (m pickModel) Init() tea.Cmd { return textinput.Blink }

func (m pickModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	k, ok := msg.(tea.KeyMsg)
	if !ok {
		var c tea.Cmd
		m.ti, c = m.ti.Update(msg)
		return m, c
	}
	switch k.String() {
	case "ctrl+c", "esc":
		return m, tea.Quit
	case "up":
		if m.cursor > 0 {
			m.cursor--
		}
		return m, nil
	case "down":
		if m.cursor < len(m.items)-1 {
			m.cursor++
		}
		return m, nil
	case "enter":
		if v := strings.TrimSpace(m.ti.Value()); v != "" {
			m.result = v
		} else if len(m.items) > 0 {
			m.result = m.items[m.cursor]
		}
		m.done = true
		return m, tea.Quit
	}
	var c tea.Cmd
	m.ti, c = m.ti.Update(msg)
	return m, c
}

func (m pickModel) View() string {
	if m.done {
		return "  " + OKStyle.Render("✓ ") + m.result + "\n"
	}
	var b strings.Builder
	b.WriteString(AccentStyle.Render(m.title) + "\n")
	typing := strings.TrimSpace(m.ti.Value()) != ""
	for i, it := range m.items {
		if i == m.cursor && !typing {
			b.WriteString(AccentStyle.Render("▸ ") + lipgloss.NewStyle().Foreground(ColorText).Bold(true).Render(it) + "\n")
		} else {
			b.WriteString("  " + MutedStyle.Render(it) + "\n")
		}
	}
	b.WriteString(TagStyle.Render("› ") + m.ti.View() + "\n")
	b.WriteString(MutedStyle.Render("↑/↓ pick · type a custom value · enter confirm · esc cancel"))
	return b.String()
}

// SelectOrInput prompts for a selection or custom text value.
func SelectOrInput(title string, items []string) (string, error) {
	if !interactive() {
		i, err := selectFallback(title, items)
		if err != nil {
			return "", err
		}
		return items[i], nil
	}
	ti := textinput.New()
	ti.Prompt = ""
	ti.Placeholder = "custom value…"
	ti.Cursor.SetMode(0)
	ti.Focus()
	res, err := tea.NewProgram(pickModel{title: title, items: items, ti: ti}).Run()
	if err != nil {
		return "", err
	}
	fm := res.(pickModel)
	if !fm.done || fm.result == "" {
		return "", fmt.Errorf("selection cancelled")
	}
	return fm.result, nil
}

type askModel struct {
	prompt string
	ti     textinput.Model
	done   bool
	cancel bool
}

func (m askModel) Init() tea.Cmd { return textinput.Blink }

func (m askModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if k, ok := msg.(tea.KeyMsg); ok {
		switch k.String() {
		case "enter":
			m.done = true
			return m, tea.Quit
		case "ctrl+c", "esc":
			m.cancel = true
			return m, tea.Quit
		}
	}
	var c tea.Cmd
	m.ti, c = m.ti.Update(msg)
	return m, c
}

func (m askModel) View() string {
	if m.done {
		return "  " + OKStyle.Render("✓ ") + m.ti.Value() + "\n"
	}
	return AccentStyle.Render(m.prompt) + " " + m.ti.View() + "\n" +
		MutedStyle.Render("enter to confirm · esc to cancel")
}

// AskString prompts for a text line pre-filled with def.
func AskString(prompt, def string) (string, error) {
	if !interactive() {
		return def, nil
	}
	ti := textinput.New()
	ti.Prompt = ""
	ti.SetValue(def)
	ti.CursorEnd()
	ti.Focus()
	res, err := tea.NewProgram(askModel{prompt: prompt, ti: ti}).Run()
	if err != nil {
		return "", err
	}
	m := res.(askModel)
	if m.cancel {
		return "", fmt.Errorf("cancelled")
	}
	v := strings.TrimSpace(m.ti.Value())
	if v == "" {
		v = def
	}
	return v, nil
}

type confirmModel struct {
	question string
	yes      bool
	answered bool
	result   bool
}

func (m confirmModel) Init() tea.Cmd { return nil }

func (m confirmModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	k, ok := msg.(tea.KeyMsg)
	if !ok {
		return m, nil
	}
	switch k.String() {
	case "ctrl+c", "esc":
		m.answered, m.result = true, false
		return m, tea.Quit
	case "left", "h", "right", "l", "tab":
		m.yes = !m.yes
	case "y", "Y":
		m.answered, m.result = true, true
		return m, tea.Quit
	case "n", "N":
		m.answered, m.result = true, false
		return m, tea.Quit
	case "enter":
		m.answered, m.result = true, m.yes
		return m, tea.Quit
	}
	return m, nil
}

func (m confirmModel) View() string {
	if m.answered {
		if m.result {
			return "  " + OKStyle.Render("✓ yes") + "\n"
		}
		return "  " + ErrStyle.Render("✗ no") + "\n"
	}
	sel := lipgloss.NewStyle().Foreground(ColorText).Background(ColorPrimary).Bold(true).Padding(0, 2)
	un := lipgloss.NewStyle().Foreground(ColorMuted).Padding(0, 2)
	yb, nb := un.Render("Yes"), un.Render("No")
	if m.yes {
		yb = sel.Render("Yes")
	} else {
		nb = sel.Render("No")
	}
	return AccentStyle.Render(m.question) + "\n" +
		yb + "  " + nb + "\n" +
		MutedStyle.Render("←/→ toggle · y/n · enter")
}

// Confirm prompts for a boolean decision.
func Confirm(question string, def bool) (bool, error) {
	if !interactive() {
		fmt.Printf("\n%s [%s] ", question, map[bool]string{true: "Y/n", false: "y/N"}[def])
		var resp string
		_, _ = fmt.Scanln(&resp)
		switch strings.ToLower(strings.TrimSpace(resp)) {
		case "y", "yes":
			return true, nil
		case "n", "no":
			return false, nil
		default:
			return def, nil
		}
	}
	res, err := tea.NewProgram(confirmModel{question: question, yes: def}).Run()
	if err != nil {
		return false, err
	}
	return res.(confirmModel).result, nil
}
