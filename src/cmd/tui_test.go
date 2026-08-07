package cmd

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// TestTUIViewSmoke verifies model rendering.
func TestTUIViewSmoke(t *testing.T) {
	m := newTUIModel()
	next, _ := m.Update(tea.WindowSizeMsg{Width: 120, Height: 40})
	out := next.(tuiModel).View()
	if !strings.Contains(out, "geto") {
		t.Fatalf("expected header in view, got:\n%s", out)
	}
}

func TestIsNewer(t *testing.T) {
	cases := []struct {
		cur, latest string
		want        bool
	}{
		{"v1.2.3", "v1.2.4", true},
		{"v1.2.3", "v1.2.3", false},
		{"v2.0.0", "v1.9.9", false},
		{"1.0.0", "1.0.1", true},
		{"weird", "weirder", true},
	}
	for _, c := range cases {
		if got := isNewer(c.cur, c.latest); got != c.want {
			t.Fatalf("isNewer(%q,%q)=%v want %v", c.cur, c.latest, got, c.want)
		}
	}
}
