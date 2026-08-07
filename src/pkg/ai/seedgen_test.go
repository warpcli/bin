package ai

import (
	"encoding/json"
	"os"
	"testing"
)

const (
	seedGroupsPath = "seed/groups.json"
	seedDir        = "seed"

	seedPasses = 5
)

type seedGroup struct {
	Repo     string   `json:"repo"`
	Platform string   `json:"platform"`
	Chosen   string   `json:"chosen,omitempty"`
	Rejected []string `json:"rejected"`
	Note     string   `json:"note,omitempty"`
}

func TestGenerateSeedModel(t *testing.T) {
	if os.Getenv("BIN_GENERATE_SEED") == "" {
		t.Skip("set BIN_GENERATE_SEED=1 to regenerate " + seedDir)
	}

	raw, err := os.ReadFile(seedGroupsPath)
	if err != nil {
		t.Fatalf("reading groups (run the assets generator first): %v", err)
	}
	var groups []seedGroup
	if err := json.Unmarshal(raw, &groups); err != nil {
		t.Fatal(err)
	}
	if len(groups) == 0 {
		t.Fatal("no labelled groups")
	}

	e := newEngine()
	for pass := 0; pass < seedPasses; pass++ {
		for _, g := range groups {
			if g.Chosen == "" {
				e.ObserveRejections(g.Rejected, g.Repo)
				continue
			}
			e.Observe(g.Chosen, g.Rejected, g.Repo)
		}
	}

	e.mu.Lock()
	e.selections = 0
	e.seeded = true
	e.mu.Unlock()

	if err := e.Save(seedDir); err != nil {
		t.Fatal(err)
	}

	fresh := NewEngine()
	if !fresh.Seeded() {
		t.Fatal("regenerated seed did not load back through the embedded FS; re-run the test to pick it up")
	}
	right, total, gated := scoreGroups(fresh, groups)
	t.Logf("wrote %s/{model.json,bayesian.gob} from %d groups (%d passes)", seedDir, len(groups), seedPasses)
	t.Logf("training accuracy: %d/%d correct, %d groups the gate declines", right, total, gated)
}

// scoreGroups evaluates model decisions against labelled seed groups.
func scoreGroups(e *Engine, groups []seedGroup) (right, total, gated int) {
	for _, g := range groups {
		if g.Chosen == "" {
			continue
		}
		total++
		names := append([]string{g.Chosen}, g.Rejected...)
		best, ok := e.Decide(names, g.Repo)
		switch {
		case !ok:
			gated++
		case best == g.Chosen:
			right++
		}
	}
	return right, total, gated
}
