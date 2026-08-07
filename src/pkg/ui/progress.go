package ui

import (
	"fmt"
	"io"
	"os"
	"strings"
	"time"
)

// ProgressReader wraps an io.Reader to render a progress bar.
type ProgressReader struct {
	r       io.Reader
	total   int64
	read    int64
	label   string
	start   time.Time
	lastOut time.Time
	done    bool
	w       io.Writer
}

// NewProgressReader returns a new ProgressReader for r.
func NewProgressReader(r io.Reader, total int64, label string) *ProgressReader {
	now := time.Now()
	return &ProgressReader{r: r, total: total, label: label, start: now, lastOut: now, w: os.Stderr}
}

func (p *ProgressReader) Read(b []byte) (int, error) {
	n, err := p.r.Read(b)
	p.read += int64(n)
	now := time.Now()
	if err != nil || now.Sub(p.lastOut) >= 70*time.Millisecond {
		p.lastOut = now
		p.render()
	}
	return n, err
}

// Finish completes progress rendering.
func (p *ProgressReader) Finish() {
	if p.done {
		return
	}
	p.done = true
	p.render()
	fmt.Fprint(p.w, "\n")
}

func (p *ProgressReader) render() {
	// Fixed-width columns so every row lines up regardless of label length:
	//   "  ⤓ " + label(labelW) + "  " + bar(barW) + "  " + pct(4) + "  " + size(20)
	const labelW = 26
	barW := TerminalWidth() - labelW - 38
	if barW < 10 {
		barW = 10
	}
	if barW > 50 {
		barW = 50
	}

	frac := 0.0
	if p.total > 0 {
		frac = float64(p.read) / float64(p.total)
		if frac > 1 {
			frac = 1
		}
	}
	filled := int(frac * float64(barW))
	if filled > barW {
		filled = barW
	}
	bar := AccentStyle.Render(strings.Repeat("█", filled)) +
		MutedStyle.Render(strings.Repeat("░", barW-filled))

	elapsed := time.Since(p.start).Seconds()
	var speed int64
	if elapsed > 0 {
		speed = int64(float64(p.read) / elapsed)
	}

	sizeText := humanBytes(p.read)
	if p.total > 0 {
		sizeText = fmt.Sprintf("%s/%s", humanBytes(p.read), humanBytes(p.total))
	}
	stats := fmt.Sprintf("%-20s %9s/s", sizeText, humanBytes(speed))

	line := fmt.Sprintf("  %s %s  %s  %s  %s",
		AccentStyle.Render("⤓"),
		TagStyle.Render(padRight(p.label, labelW)),
		bar,
		WarnStyle.Render(fmt.Sprintf("%3.0f%%", frac*100)),
		MutedStyle.Render(stats),
	)
	// \r to the line start, draw, then clear to end-of-line.
	fmt.Fprintf(p.w, "\r%s\033[K", line)
}

// padRight truncates s to w columns (with an ellipsis) and right-pads to w.
func padRight(s string, w int) string {
	s = clip(s, w)
	if n := w - len([]rune(s)); n > 0 {
		s += strings.Repeat(" ", n)
	}
	return s
}

func humanBytes(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%dB", n)
	}
	div, exp := int64(unit), 0
	for x := n / unit; x >= unit; x /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f%ciB", float64(n)/float64(div), "KMGT"[exp])
}
