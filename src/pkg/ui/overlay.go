package ui

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// Dialog renders a modal dialog box.
func Dialog(title, body, footer string) string {
	bar := lipgloss.NewStyle().
		Bold(true).Foreground(ColorText).Background(ColorPrimary).
		Padding(0, 1).Render(title)

	var b strings.Builder
	b.WriteString(bar + "\n\n")
	b.WriteString(body)
	if footer != "" {
		b.WriteString("\n\n" + MutedStyle.Render(footer))
	}

	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(ColorPrimary).
		Padding(1, 2).
		Render(b.String())
}

// Button renders a dialog button.
func Button(label string, focused bool) string {
	if focused {
		return lipgloss.NewStyle().
			Bold(true).Foreground(ColorText).Background(ColorPrimary).
			Padding(0, 3).Render(label)
	}
	return lipgloss.NewStyle().
		Foreground(ColorMuted).
		Padding(0, 3).Render(label)
}

// Dim renders s with muted colors.
func Dim(s string) string {
	return lipgloss.NewStyle().Foreground(ColorMuted).Render(ansi.Strip(s))
}

// Overlay places fg centered over bg.
func Overlay(bg, fg string) string {
	bgLines := strings.Split(bg, "\n")
	fgLines := strings.Split(fg, "\n")

	bgW := 0
	for _, l := range bgLines {
		if w := ansi.StringWidth(l); w > bgW {
			bgW = w
		}
	}
	fgW := 0
	for _, l := range fgLines {
		if w := ansi.StringWidth(l); w > fgW {
			fgW = w
		}
	}

	startRow := (len(bgLines) - len(fgLines)) / 2
	if startRow < 0 {
		startRow = 0
	}
	startCol := (bgW - fgW) / 2
	if startCol < 0 {
		startCol = 0
	}

	for i, fl := range fgLines {
		row := startRow + i
		if row < 0 || row >= len(bgLines) {
			continue
		}
		bl := bgLines[row]
		left := ansi.Truncate(bl, startCol, "")
		if w := ansi.StringWidth(left); w < startCol {
			left += strings.Repeat(" ", startCol-w)
		}
		right := ansi.TruncateLeft(bl, startCol+fgW, "")
		bgLines[row] = left + "\x1b[0m" + fl + "\x1b[0m" + right
	}
	return strings.Join(bgLines, "\n")
}
