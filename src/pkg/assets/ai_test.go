package assets

import (
	"os"
	"strings"
	"testing"

	"github.com/bresilla/bin/src/pkg/ai"
)

// TestMain keeps the whole suite away from the user's real learned model: the
// default aiEngineFor reads (and aiLearn would write) the state directory.
func TestMain(m *testing.M) {
	aiEngineFor = func() *ai.Engine { return nil }
	os.Exit(m.Run())
}

// withEngine installs e as the tie-breaking engine for one test.
func withEngine(t *testing.T, e *ai.Engine) {
	t.Helper()
	prev := aiEngineFor
	aiEngineFor = func() *ai.Engine { return e }
	t.Cleanup(func() { aiEngineFor = prev })
}

// muslPreferringEngine is an engine trained to prefer musl over gnu, using
// repos that appear in none of the assertions below.
func muslPreferringEngine() *ai.Engine {
	e := ai.NewEngine()
	pairs := [][2]string{
		{"fd-v10.2.0-x86_64-unknown-linux-musl.tar.gz", "fd-v10.2.0-x86_64-unknown-linux-gnu.tar.gz"},
		{"bat-v0.24.0-x86_64-unknown-linux-musl.tar.gz", "bat-v0.24.0-x86_64-unknown-linux-gnu.tar.gz"},
		{"eza_x86_64-unknown-linux-musl.tar.gz", "eza_x86_64-unknown-linux-gnu.tar.gz"},
		{"delta-x86_64-unknown-linux-musl.tar.gz", "delta-x86_64-unknown-linux-gnu.tar.gz"},
		{"hyperfine-x86_64-unknown-linux-musl.tar.gz", "hyperfine-x86_64-unknown-linux-gnu.tar.gz"},
		{"just-x86_64-unknown-linux-musl.tar.gz", "just-x86_64-unknown-linux-gnu.tar.gz"},
	}
	for round := 0; round < 20; round++ {
		for _, p := range pairs {
			e.Observe(p[0], []string{p[1]}, "")
		}
	}
	return e
}

var tiedRipgrepAssets = []*Asset{
	{Name: "ripgrep-14.1.0-x86_64-unknown-linux-musl.tar.gz", URL: "https://example/musl"},
	{Name: "ripgrep-14.1.0-x86_64-unknown-linux-gnu.tar.gz", URL: "https://example/gnu"},
}

// The learned model must stay out of the score itself. Folding it in made exact
// ties impossible, which silently removed the "Multiple matches found" prompt —
// and the prompt is the only source of training data.
func TestScoredMatchesKeepsTiesRegardlessOfModel(t *testing.T) {
	resolver = testLinuxAMDResolver
	f := NewFilter(&FilterOpts{})

	for _, tc := range []struct {
		name   string
		engine *ai.Engine
	}{
		{"no engine", nil},
		{"seeded engine", ai.NewEngine()},
		{"user-trained engine", muslPreferringEngine()},
	} {
		t.Run(tc.name, func(t *testing.T) {
			withEngine(t, tc.engine)
			matches := f.scoredMatches("ripgrep", tiedRipgrepAssets)
			if len(matches) != 2 {
				names := make([]string, 0, len(matches))
				for _, m := range matches {
					names = append(names, m.Name)
				}
				t.Fatalf("scoredMatches kept %d of 2 tied candidates (%v); the tie must survive to FilterAssets",
					len(matches), names)
			}
			if matches[0].score != matches[1].score {
				t.Errorf("tied candidates scored %d and %d", matches[0].score, matches[1].score)
			}
		})
	}
}

// Repeated calls must produce the same scores: an unseeded net made these differ
// per process.
func TestScoredMatchesIsDeterministic(t *testing.T) {
	resolver = testLinuxAMDResolver
	withEngine(t, muslPreferringEngine())
	f := NewFilter(&FilterOpts{})

	first := f.scoredMatches("ripgrep", tiedRipgrepAssets)
	for run := 0; run < 5; run++ {
		got := f.scoredMatches("ripgrep", tiedRipgrepAssets)
		if len(got) != len(first) {
			t.Fatalf("run %d returned %d matches, want %d", run, len(got), len(first))
		}
		for i := range got {
			if got[i].Name != first[i].Name || got[i].score != first[i].score {
				t.Fatalf("run %d differs at %d: %s/%d vs %s/%d",
					run, i, got[i].Name, got[i].score, first[i].Name, first[i].score)
			}
		}
	}
}

// With learning switched off entirely, non-interactive callers keep getting the
// explicit error rather than a silent guess.
func TestFilterAssetsPromptsWithoutAModel(t *testing.T) {
	resolver = testLinuxAMDResolver
	withEngine(t, nil)

	f := NewFilter(&FilterOpts{NonInteractive: true})
	gf, err := f.FilterAssets("ripgrep", tiedRipgrepAssets)
	if err == nil {
		t.Fatalf("auto-picked %q with no model; want the non-interactive error", gf.Name)
	}
	if !strings.Contains(err.Error(), "multiple matching assets") {
		t.Fatalf("unexpected error: %v", err)
	}
}

// The embedded seed is meant to be useful from the first install, without the
// user having selected anything yet.
func TestFilterAssetsUsesSeedOnAFreshInstall(t *testing.T) {
	resolver = testLinuxAMDResolver
	engine := ai.NewEngine()
	if !engine.Seeded() {
		t.Skip("no embedded seed model")
	}
	withEngine(t, engine)

	f := NewFilter(&FilterOpts{NonInteractive: true})
	gf, err := f.FilterAssets("ripgrep", tiedRipgrepAssets)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(gf.Name, "musl") {
		t.Fatalf("seed chose %q, want the musl build", gf.Name)
	}
}

// The message must not credit the user for a choice the built-in defaults made.
func TestAIBasisDistinguishesSeedFromUser(t *testing.T) {
	withEngine(t, nil)
	if got := aiBasis(); got != "" {
		t.Errorf("aiBasis() = %q with no engine, want empty", got)
	}

	withEngine(t, ai.NewEngine())
	if got := aiBasis(); !strings.Contains(got, "built-in") {
		t.Errorf("aiBasis() = %q for a fresh seeded engine, want it to credit the built-in defaults", got)
	}

	withEngine(t, muslPreferringEngine())
	if got := aiBasis(); !strings.Contains(got, "past choice") {
		t.Errorf("aiBasis() = %q after user selections, want it to mention them", got)
	}
}

// A model with enough consistent history resolves the tie, including for the
// non-interactive TUI, which would otherwise have to fail on this release.
func TestFilterAssetsAutoPicksWhenUserTrained(t *testing.T) {
	resolver = testLinuxAMDResolver
	withEngine(t, muslPreferringEngine())

	f := NewFilter(&FilterOpts{NonInteractive: true})
	gf, err := f.FilterAssets("ripgrep", tiedRipgrepAssets)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(gf.Name, "musl") {
		t.Fatalf("chose %q, want the musl build", gf.Name)
	}
	if gf.URL == "" {
		t.Error("chosen asset lost its URL")
	}
}

// The model only ever breaks ties. It must never promote a lower-scoring
// candidate, however confident it is.
func TestModelNeverOverridesTheDeterministicScore(t *testing.T) {
	resolver = testLinuxAMDResolver
	withEngine(t, muslPreferringEngine())

	// The musl build here is for the wrong architecture, so the scorer ranks it
	// strictly below the correct one and no tie exists to break.
	as := []*Asset{
		{Name: "ripgrep-14.1.0-x86_64-unknown-linux-gnu.tar.gz", URL: "https://example/right"},
		{Name: "ripgrep-14.1.0-aarch64-unknown-linux-musl.tar.gz", URL: "https://example/wrong-arch"},
	}
	f := NewFilter(&FilterOpts{NonInteractive: true})
	gf, err := f.FilterAssets("ripgrep", as)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(gf.Name, "x86_64") {
		t.Fatalf("chose %q; the model overrode the architecture match", gf.Name)
	}
}

func TestAIDisabledByEnv(t *testing.T) {
	for _, v := range []string{"1", "true", "TRUE", "yes", "on", " on "} {
		t.Setenv("BIN_NO_AI", v)
		if !aiDisabled() {
			t.Errorf("BIN_NO_AI=%q did not disable asset learning", v)
		}
		if dir := AIModelDir(); dir != "" {
			t.Errorf("BIN_NO_AI=%q still resolved a model dir %q", v, dir)
		}
	}
	for _, v := range []string{"", "0", "false", "no", "off", "maybe"} {
		t.Setenv("BIN_NO_AI", v)
		if aiDisabled() {
			t.Errorf("BIN_NO_AI=%q unexpectedly disabled asset learning", v)
		}
	}
}

// The model is learned state, not user-editable config, so it must not land in
// the config directory (which is /etc/bin when running as root).
func TestAIModelDirLivesInStateDir(t *testing.T) {
	t.Setenv("BIN_NO_AI", "")
	t.Setenv("BIN_STATE_HOME", t.TempDir())

	dir := AIModelDir()
	if dir == "" {
		t.Fatal("AIModelDir() is empty with BIN_STATE_HOME set")
	}
	if !strings.HasPrefix(dir, os.Getenv("BIN_STATE_HOME")) {
		t.Fatalf("AIModelDir() = %q, want it under %q", dir, os.Getenv("BIN_STATE_HOME"))
	}
}
