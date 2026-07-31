package ai

import (
	"encoding/json"
	"os"
	"testing"
)

// This file is the second half of the seed-model generator:
//
//	seed/corpus.json --(assets/seedgroups_test.go)--> seed/groups.json --(here)--> seed/model.json
//	                                                                              seed/bayesian.gob
//
// Regenerate with:
//
//	BIN_GENERATE_SEED=1 go test ./src/pkg/assets -run TestGenerateSeedGroups
//	BIN_GENERATE_SEED=1 go test ./src/pkg/ai     -run TestGenerateSeedModel
//
// It trains a pristine engine (newEngine, never NewEngine) so a regenerated seed
// is a function of the corpus alone and not of whatever seed shipped before it.

const (
	seedGroupsPath = "seed/groups.json"
	seedDir        = "seed"

	// seedPasses is how many times the whole labelled set is replayed. Chosen by
	// sweeping it: fewer passes leave the model abstaining on cases it should
	// call, and more drive the sigmoid outputs to 0.99/0.01, where the gradient
	// vanishes and a user can no longer train their own preference back in. At 5
	// the seed is decisive, makes no confident mistakes on held-out groups, and
	// stays correctable — see TestSeedModelHoldout and TestUserSelectionsOverrideSeed.
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
	// groups.json is sorted, so replaying it in order is deterministic.
	for pass := 0; pass < seedPasses; pass++ {
		for _, g := range groups {
			if g.Chosen == "" {
				e.ObserveRejections(g.Rejected, g.Repo)
				continue
			}
			e.Observe(g.Chosen, g.Rejected, g.Repo)
		}
	}

	// The seed's authority comes from the corpus, not from a selection count. Zero
	// it so `bin ai` never claims the user made choices they didn't, and mark the
	// model as a seed so Trained() still lets it decide.
	e.mu.Lock()
	e.selections = 0
	e.seeded = true
	e.mu.Unlock()

	if err := e.Save(seedDir); err != nil {
		t.Fatal(err)
	}

	// Report how the freshly built seed does on its own labels. This is training
	// accuracy, not a generalisation estimate — TestSeedModelHoldout is the real
	// check — but a low number here means something is broken.
	fresh := NewEngine()
	if !fresh.Seeded() {
		t.Fatal("regenerated seed did not load back through the embedded FS; re-run the test to pick it up")
	}
	right, total, gated := scoreGroups(fresh, groups)
	t.Logf("wrote %s/{model.json,bayesian.gob} from %d groups (%d passes)", seedDir, len(groups), seedPasses)
	t.Logf("training accuracy: %d/%d correct, %d groups the gate declines", right, total, gated)
}

// scoreGroups replays labelled groups through Decide, counting how often the
// model picks the labelled winner and how often the confidence gate abstains.
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
