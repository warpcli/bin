package ai

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestSeedModelIsEmbeddedAndUsable(t *testing.T) {
	e := NewEngine()
	if !e.Seeded() {
		t.Fatal("NewEngine() did not load the embedded seed model")
	}
	if !e.Trained() {
		t.Fatal("the seed model reports itself untrained, so it will never decide")
	}
	if got := e.Selections(); got != 0 {
		t.Errorf("Selections() = %d on a seeded engine; the seed must not claim user choices", got)
	}
}

func TestSeedModelIsDeterministic(t *testing.T) {
	names := []string{
		"atuin-x86_64-unknown-linux-musl.tar.gz",
		"atuin-server-x86_64-unknown-linux-musl.tar.gz",
		"ollama-linux-amd64-rocm.tar.zst",
	}
	want := make([]float64, len(names))
	for i, n := range names {
		want[i] = NewEngine().Score(n, "atuin")
	}
	for run := 0; run < 5; run++ {
		e := NewEngine()
		for i, n := range names {
			if got := e.Score(n, "atuin"); got != want[i] {
				t.Fatalf("run %d: Score(%q) = %v, want %v", run, n, got, want[i])
			}
		}
	}
}

// Every repo below is deliberately absent from seed/corpus.json, so these
// measure generalisation rather than recall. Each case is one the seed should
// either get right or abstain on — never get wrong.
var seedExpectations = []struct {
	repo    string
	want    string
	against []string
	why     string
}{
	{
		repo: "ripgrep", want: "ripgrep-14.1.0-x86_64-unknown-linux-musl.tar.gz",
		against: []string{"ripgrep-14.1.0-x86_64-unknown-linux-musl.tar.gz.sha256.txt"},
		why:     "the binary, not a checksum sidecar",
	},
	{
		repo: "helix", want: "helix-24.07-x86_64-linux.tar.xz",
		against: []string{"helix-24.07-source.tar.xz"},
		why:     "the build, not the source tarball",
	},
	{
		repo: "lazygit", want: "lazygit_0.44.1_Linux_x86_64.tar.gz",
		against: []string{"lazygit_0.44.1_Linux_x86_64.tar.gz.sbom"},
		why:     "the archive, not its SBOM",
	},
	{
		repo: "fd", want: "fd-v10.2.0-x86_64-unknown-linux-musl.tar.gz",
		against: []string{"fd-completions-v10.2.0.tar.gz"},
		why:     "the tool, not a companion artifact",
	},
	{
		repo: "wezterm", want: "wezterm-20240203-linux-x86_64.tar.gz",
		against: []string{"wezterm-debug-20240203-linux-x86_64.tar.gz"},
		why:     "the release build, not the debug build",
	},
	{
		repo: "zellij", want: "zellij-x86_64-unknown-linux-musl.tar.gz",
		against: []string{"zellij-plugins-x86_64-unknown-linux-musl.tar.gz"},
		why:     "the tool, not its plugin bundle",
	},
	{
		repo: "duckdb", want: "duckdb_cli-linux-amd64.zip",
		against: []string{"duckdb_cli-linux-amd64-debug-symbols.zip"},
		why:     "the CLI, not its debug symbols",
	},
}

// The seed exists so a fresh install is useful immediately. It must get a decent
// share of these right, and — more importantly — get none of them wrong.
func TestSeedModelGeneralisesToUnseenRepos(t *testing.T) {
	e := NewEngine()

	right, abstained, wrong := 0, 0, 0
	for _, tc := range seedExpectations {
		names := append([]string{tc.want}, tc.against...)
		best, ok := e.Decide(names, tc.repo)
		switch {
		case !ok:
			abstained++
			t.Logf("abstain  %-9s %s (%s)", tc.repo, tc.want, tc.why)
		case best == tc.want:
			right++
			t.Logf("correct  %-9s %s (%s)", tc.repo, tc.want, tc.why)
		default:
			wrong++
			t.Errorf("WRONG    %-9s chose %q, want %q (%s)", tc.repo, best, tc.want, tc.why)
		}
	}
	t.Logf("unseen repos: %d correct, %d abstained, %d wrong (of %d)",
		right, abstained, wrong, len(seedExpectations))

	if wrong > 0 {
		t.Errorf("the seed model actively chose the wrong asset %d time(s)", wrong)
	}
	if right == 0 {
		t.Error("the seed model got none of the unseen cases right; it is not earning its place")
	}
}

// Holdout: train on most of the labelled groups and evaluate on the rest, to
// separate "learned the corpus" from "learned something transferable".
func TestSeedModelHoldout(t *testing.T) {
	groups := loadSeedGroups(t)

	var train, holdout []seedGroup
	for i, g := range groups {
		if g.Chosen == "" {
			continue // nothing to score against
		}
		if i%4 == 3 {
			holdout = append(holdout, g)
		} else {
			train = append(train, g)
		}
	}
	if len(holdout) < 5 {
		t.Skipf("holdout too small (%d)", len(holdout))
	}

	e := newEngine()
	for pass := 0; pass < seedPasses; pass++ {
		for _, g := range train {
			e.Observe(g.Chosen, g.Rejected, g.Repo)
		}
	}
	// Mark it seeded so the gate lets it decide, matching how the real seed runs.
	e.mu.Lock()
	e.seeded = true
	e.mu.Unlock()

	right, total, gated := scoreGroups(e, holdout)
	wrong := total - right - gated
	t.Logf("trained on %d groups, held out %d: %d correct, %d abstained, %d wrong",
		len(train), total, right, gated, wrong)

	// A model that abstains is harmless; one that confidently picks the wrong
	// asset is not. Hold the line there rather than on raw accuracy.
	if wrong > total/4 {
		t.Errorf("wrong on %d of %d held-out groups (>25%%)", wrong, total)
	}
	if right == 0 {
		t.Error("no held-out group answered correctly; the model has not generalised")
	}
}

// A user disagreeing with the seed must be able to train it back out. The seed
// prefers musl; teach it gnu and check it actually flips.
func TestUserSelectionsOverrideSeed(t *testing.T) {
	e := NewEngine()
	musl := "someapp-x86_64-unknown-linux-musl.tar.gz"
	gnu := "someapp-x86_64-unknown-linux-gnu.tar.gz"

	gnuSelections := []selection{
		{"fd", "fd-x86_64-unknown-linux-gnu.tar.gz", []string{"fd-x86_64-unknown-linux-musl.tar.gz"}},
		{"bat", "bat-x86_64-unknown-linux-gnu.tar.gz", []string{"bat-x86_64-unknown-linux-musl.tar.gz"}},
		{"ripgrep", "ripgrep-x86_64-unknown-linux-gnu.tar.gz", []string{"ripgrep-x86_64-unknown-linux-musl.tar.gz"}},
		{"hyperfine", "hyperfine-x86_64-unknown-linux-gnu.tar.gz", []string{"hyperfine-x86_64-unknown-linux-musl.tar.gz"}},
	}
	for round := 0; round < 40; round++ {
		train(e, gnuSelections)
	}

	if got, want := e.Score(gnu, "someapp"), e.Score(musl, "someapp"); got <= want {
		t.Fatalf("after 160 gnu selections, gnu scores %.3f vs musl %.3f; the seed cannot be overridden", got, want)
	}
}

// Regenerating the seed must not silently change the feature layout out from
// under the shipped weights.
func TestSeedModelMatchesCurrentShape(t *testing.T) {
	raw, err := seedFS.ReadFile("seed/model.json")
	if err != nil {
		t.Fatal(err)
	}
	var m modelState
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	if m.Version != modelVersion {
		t.Errorf("embedded seed is version %d, code is version %d; regenerate it", m.Version, modelVersion)
	}
	if want := numHidden * (numFeatures + 1); len(m.Weights1) != want {
		t.Errorf("embedded seed hidden layer has %d weights, current shape needs %d", len(m.Weights1), want)
	}
	if want := 1 * (numHidden + 1); len(m.Weights2) != want {
		t.Errorf("embedded seed output layer has %d weights, current shape needs %d", len(m.Weights2), want)
	}
	if !m.Seeded {
		t.Error("embedded seed is not flagged Seeded, so Trained() will refuse to use it")
	}
}

// The committed labels back the shipped model, so keep them honest.
func TestSeedGroupsAreWellFormed(t *testing.T) {
	groups := loadSeedGroups(t)
	if len(groups) < 20 {
		t.Fatalf("only %d labelled groups; the seed has too little to learn from", len(groups))
	}
	for _, g := range groups {
		if g.Repo == "" || g.Platform == "" {
			t.Errorf("group with no repo/platform: %+v", g)
		}
		if len(g.Rejected) == 0 {
			t.Errorf("%s/%s has no rejected candidates, so it teaches nothing", g.Repo, g.Platform)
		}
		for _, r := range g.Rejected {
			if r == g.Chosen {
				t.Errorf("%s/%s lists %q as both chosen and rejected", g.Repo, g.Platform, r)
			}
		}
		if g.Chosen == "" && g.Note == "" {
			t.Errorf("%s/%s has no winner and no explanation", g.Repo, g.Platform)
		}
	}
}

func loadSeedGroups(t *testing.T) []seedGroup {
	t.Helper()
	raw, err := os.ReadFile(seedGroupsPath)
	if err != nil {
		t.Fatalf("reading %s: %v", seedGroupsPath, err)
	}
	var groups []seedGroup
	if err := json.Unmarshal(raw, &groups); err != nil {
		t.Fatalf("parsing %s: %v", seedGroupsPath, err)
	}
	return groups
}

// The corpus is committed as the provenance of the model; make sure it stays
// readable and free of the junk that would poison training.
func TestSeedCorpusIsWellFormed(t *testing.T) {
	raw, err := os.ReadFile("seed/corpus.json")
	if err != nil {
		t.Fatal(err)
	}
	var corpus []struct {
		Owner  string   `json:"owner"`
		Repo   string   `json:"repo"`
		Assets []string `json:"assets"`
	}
	if err := json.Unmarshal(raw, &corpus); err != nil {
		t.Fatal(err)
	}
	if len(corpus) < 20 {
		t.Fatalf("corpus has only %d repos", len(corpus))
	}
	total := 0
	for _, r := range corpus {
		if r.Repo == "" || r.Owner == "" {
			t.Errorf("corpus entry missing owner/repo: %+v", r)
		}
		for _, a := range r.Assets {
			if a == "" || strings.TrimSpace(a) != a {
				t.Errorf("%s has a malformed asset name %q", r.Repo, a)
			}
		}
		total += len(r.Assets)
	}
	t.Logf("corpus: %d repos, %d asset names", len(corpus), total)
}
