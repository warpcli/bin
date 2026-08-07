package assets

import (
	"os"
	"strings"
	"testing"

	"github.com/bresilla/bin/src/pkg/ai"
)

func TestMain(m *testing.M) {
	aiEngineFor = func() *ai.Engine { return nil }
	os.Exit(m.Run())
}

func withEngine(t *testing.T, e *ai.Engine) {
	t.Helper()
	prev := aiEngineFor
	aiEngineFor = func() *ai.Engine { return e }
	t.Cleanup(func() { aiEngineFor = prev })
}

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

func TestAIBasisDistinguishesSeedFromUser(t *testing.T) {
	withEngine(t, nil)
	if got := aiBasis(); got != "" {
		t.Errorf("aiBasis() = %q with no engine, want empty", got)
	}

	withEngine(t, ai.NewEngine())
	if got := aiBasis(); !strings.Contains(got, "built-in") && !strings.Contains(got, "defaults") {
		t.Errorf("aiBasis() = %q for a fresh seeded engine, want it to credit the built-in defaults", got)
	}

	eng := muslPreferringEngine()
	withEngine(t, eng)
	if got := aiBasis(); !strings.Contains(got, "selections") && !strings.Contains(got, "choice") && !strings.Contains(got, "past choice") {
		t.Errorf("aiBasis() = %q after user selections, want it to mention them", got)
	}
}

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

func TestModelNeverOverridesTheDeterministicScore(t *testing.T) {
	resolver = testLinuxAMDResolver
	withEngine(t, muslPreferringEngine())

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
