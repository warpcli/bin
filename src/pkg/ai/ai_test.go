package ai

import (
	"encoding/json"
	"errors"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"testing"
)

// selection is one user choice: what they picked, and what they passed over.
type selection struct {
	repo     string
	chosen   string
	rejected []string
}

// muslSelections is a user who consistently prefers musl over gnu.
var muslSelections = []selection{
	{"ripgrep", "ripgrep-14.1.0-x86_64-unknown-linux-musl.tar.gz", []string{"ripgrep-14.1.0-x86_64-unknown-linux-gnu.tar.gz"}},
	{"fd", "fd-v10.2.0-x86_64-unknown-linux-musl.tar.gz", []string{"fd-v10.2.0-x86_64-unknown-linux-gnu.tar.gz"}},
	{"bat", "bat-v0.24.0-x86_64-unknown-linux-musl.tar.gz", []string{"bat-v0.24.0-x86_64-unknown-linux-gnu.tar.gz"}},
	{"eza", "eza_x86_64-unknown-linux-musl.tar.gz", []string{"eza_x86_64-unknown-linux-gnu.tar.gz"}},
	{"delta", "delta-0.18.2-x86_64-unknown-linux-musl.tar.gz", []string{"delta-0.18.2-x86_64-unknown-linux-gnu.tar.gz"}},
	{"hyperfine", "hyperfine-v1.19.0-x86_64-unknown-linux-musl.tar.gz", []string{"hyperfine-v1.19.0-x86_64-unknown-linux-gnu.tar.gz"}},
}

func train(e *Engine, sels []selection) {
	for _, s := range sels {
		e.Observe(s.chosen, s.rejected, s.repo)
	}
}

// Observe used to call bayesian.ConvertTermsFreqToTfIdf, which panics on the
// second call. Two prompts in one run were enough to crash bin.
func TestObserveRepeatedlyDoesNotPanic(t *testing.T) {
	e := newEngine()
	for i := 0; i < 50; i++ {
		train(e, muslSelections)
	}
	if got := e.Selections(); got != 50*len(muslSelections) {
		t.Fatalf("Selections() = %d, want %d", got, 50*len(muslSelections))
	}
}

// The panic flag was also persisted into the gob, so the first Observe of every
// later run crashed too.
func TestObserveAfterReloadDoesNotPanic(t *testing.T) {
	dir := t.TempDir()

	e := newEngine()
	train(e, muslSelections)
	if err := e.Save(dir); err != nil {
		t.Fatalf("Save: %v", err)
	}

	reloaded := newEngine()
	if err := reloaded.Load(dir); err != nil {
		t.Fatalf("Load: %v", err)
	}
	train(reloaded, muslSelections)
	if err := reloaded.Save(dir); err != nil {
		t.Fatalf("Save after reload: %v", err)
	}
}

// nanonn seeds Dense layers from the global math/rand, which Go auto-seeds per
// process. Without a fixed seed, a fresh install ranked assets differently on
// every invocation.
func TestFreshEnginesScoreIdentically(t *testing.T) {
	names := []string{
		"ripgrep-14.1.0-x86_64-unknown-linux-musl.tar.gz",
		"ripgrep-14.1.0-x86_64-unknown-linux-gnu.tar.gz",
		"ripgrep-14.1.0-x86_64-pc-windows-msvc.zip",
		"ripgrep",
	}

	want := make([]float64, len(names))
	for i, n := range names {
		want[i] = newEngine().Score(n, "ripgrep")
	}
	for run := 0; run < 5; run++ {
		e := newEngine()
		for i, n := range names {
			if got := e.Score(n, "ripgrep"); got != want[i] {
				t.Fatalf("run %d: Score(%q) = %v, want %v", run, n, got, want[i])
			}
		}
	}
}

func TestSaveLoadPreservesScores(t *testing.T) {
	dir := t.TempDir()
	names := []string{
		"ripgrep-14.1.0-x86_64-unknown-linux-musl.tar.gz",
		"ripgrep-14.1.0-x86_64-unknown-linux-gnu.tar.gz",
	}

	e := newEngine()
	train(e, muslSelections)
	if err := e.Save(dir); err != nil {
		t.Fatalf("Save: %v", err)
	}

	reloaded := newEngine()
	if err := reloaded.Load(dir); err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got, want := reloaded.Selections(), e.Selections(); got != want {
		t.Fatalf("Selections() = %d, want %d", got, want)
	}
	for _, n := range names {
		want := e.Score(n, "ripgrep")
		if got := reloaded.Score(n, "ripgrep"); got != want {
			t.Errorf("Score(%q) = %v after reload, want %v", n, got, want)
		}
	}
}

// An untrained engine must decline, so a fresh install always prompts instead
// of guessing from initial weights.
func TestUntrainedEngineDeclinesToDecide(t *testing.T) {
	e := newEngine()
	names := []string{
		"ripgrep-14.1.0-x86_64-unknown-linux-musl.tar.gz",
		"ripgrep-14.1.0-x86_64-unknown-linux-gnu.tar.gz",
	}
	if best, ok := e.Decide(names, "ripgrep"); ok {
		t.Fatalf("untrained engine decided on %q; want a prompt", best)
	}
	if e.Trained() {
		t.Fatal("Trained() = true on a fresh engine")
	}
}

func TestDecideNeedsMinSelections(t *testing.T) {
	names := []string{
		"ripgrep-14.1.0-x86_64-unknown-linux-musl.tar.gz",
		"ripgrep-14.1.0-x86_64-unknown-linux-gnu.tar.gz",
	}
	e := newEngine()
	for i := 0; i < minSelections-1; i++ {
		e.Observe(muslSelections[i].chosen, muslSelections[i].rejected, muslSelections[i].repo)
		if _, ok := e.Decide(names, "ripgrep"); ok {
			t.Fatalf("decided after %d selections; minimum is %d", i+1, minSelections)
		}
	}
}

// The point of the whole package: a consistent preference should eventually be
// applied to a repo the user has never chosen for.
func TestLearnsPreferenceAndAppliesItToNewRepo(t *testing.T) {
	e := newEngine()
	for round := 0; round < 20; round++ {
		train(e, muslSelections)
	}

	// "zoxide" appears in none of the training selections.
	musl := "zoxide-x86_64-unknown-linux-musl.tar.gz"
	gnu := "zoxide-x86_64-unknown-linux-gnu.tar.gz"

	best, ok := e.Decide([]string{gnu, musl}, "zoxide")
	if !ok {
		t.Fatalf("declined to decide after %d selections (musl=%.3f gnu=%.3f)",
			e.Selections(), e.Score(musl, "zoxide"), e.Score(gnu, "zoxide"))
	}
	if best != musl {
		t.Fatalf("chose %q, want %q (musl=%.3f gnu=%.3f)",
			best, musl, e.Score(musl, "zoxide"), e.Score(gnu, "zoxide"))
	}

	// Order of the candidates must not change the outcome.
	if reversed, _ := e.Decide([]string{musl, gnu}, "zoxide"); reversed != best {
		t.Fatalf("candidate order changed the winner: %q vs %q", best, reversed)
	}
}

// Identical scores must not be resolved: whichever name happened to come first
// would otherwise win, making the choice depend on input order.
func TestDecideRejectsExactTies(t *testing.T) {
	e := newEngine()
	for round := 0; round < 20; round++ {
		train(e, muslSelections)
	}
	// Same name twice guarantees identical feature vectors.
	name := "ripgrep-14.1.0-x86_64-unknown-linux-musl.tar.gz"
	if best, ok := e.Decide([]string{name, name}, "ripgrep"); ok {
		t.Fatalf("resolved an exact tie to %q; want a prompt", best)
	}
}

// strings.Contains(x, "") is true, which used to pin this feature to 1 for
// every install that has no repo name (URL-based ones).
func TestRepoFeatureIsZeroWithoutRepoName(t *testing.T) {
	e := newEngine()
	if got := e.features("whatever-linux-amd64.tar.gz", "")[fRepoRank]; got != 0 {
		t.Fatalf("fRepoRank = %v with an empty repo name, want 0", got)
	}
	if got := e.features("ripgrep-linux-amd64.tar.gz", "ripgrep")[fRepoRank]; got != 1 {
		t.Fatalf("fRepoRank = %v for a matching repo name, want 1", got)
	}
}

// Features must actually differ between candidates the scorer rated equally,
// otherwise the net has nothing to learn from.
func TestFeaturesDiscriminateBetweenTiedCandidates(t *testing.T) {
	e := newEngine()
	pairs := [][2]string{
		{"ripgrep-14.1.0-x86_64-unknown-linux-musl.tar.gz", "ripgrep-14.1.0-x86_64-unknown-linux-gnu.tar.gz"},
		{"hugo_0.140.0_linux-amd64.tar.gz", "hugo_0.140.0_linux-amd64.zip"},
		{"tool-v2-linux-amd64", "tool-v2-linux-amd64.tar.gz"},
		{"tool-linux-amd64-static.tar.gz", "tool-linux-amd64.tar.gz"},
		{"tool-linux-amd64.tar.gz", "tool-linux-amd64-src.tar.gz"},
	}
	for _, p := range pairs {
		a := e.features(p[0], "tool")
		b := e.features(p[1], "tool")
		if reflect.DeepEqual(a, b) {
			t.Errorf("%q and %q produce identical features %v", p[0], p[1], a)
		}
	}
}

func TestTokenizeDropsPerReleaseNoise(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"ripgrep-14.1.0-x86_64-unknown-linux-musl.tar.gz", []string{"ripgrep", "x86", "unknown", "linux", "musl", "tar", "gz"}},
		{"fd-v10.2.0-x86_64-unknown-linux-gnu.tar.gz", []string{"fd", "x86", "unknown", "linux", "gnu", "tar", "gz"}},
		{"tool-linux-amd64-2f8a91c3de.tar.gz", []string{"tool", "linux", "amd64", "tar", "gz"}},
	}
	for _, c := range cases {
		if got := tokenize(c.in); !reflect.DeepEqual(got, c.want) {
			t.Errorf("tokenize(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}

// Two releases of the same tool must tokenize identically, or the vocabulary
// grows on every upgrade.
func TestTokenizeIsStableAcrossVersions(t *testing.T) {
	a := tokenize("ripgrep-14.1.0-x86_64-unknown-linux-musl.tar.gz")
	b := tokenize("ripgrep-14.2.7-x86_64-unknown-linux-musl.tar.gz")
	if !reflect.DeepEqual(a, b) {
		t.Fatalf("version bump changed tokens: %v vs %v", a, b)
	}
}

func TestHasTokenMatchesWholeTokensOnly(t *testing.T) {
	if hasToken("tool-resources-linux.tar.gz", "source", "sources", "src") {
		t.Error(`"resources" matched a source token`)
	}
	if !hasToken("tool-src-linux.tar.gz", "src") {
		t.Error(`"src" did not match`)
	}
}

// A corrupt or stale model must leave the engine untrained (so it prompts)
// rather than half-loaded.
func TestLoadRejectsBadModels(t *testing.T) {
	good := newEngine()
	train(good, muslSelections)

	valid := func() modelState {
		return modelState{
			Version:    modelVersion,
			Selections: 100,
			Weights1:   append([]float64(nil), good.layer1.Weights()...),
			Weights2:   append([]float64(nil), good.layer2.Weights()...),
		}
	}

	cases := map[string]func(*modelState){
		"version mismatch":    func(s *modelState) { s.Version = modelVersion + 1 },
		"zero version":        func(s *modelState) { s.Version = 0 },
		"short hidden layer":  func(s *modelState) { s.Weights1 = s.Weights1[:len(s.Weights1)-1] },
		"long output layer":   func(s *modelState) { s.Weights2 = append(s.Weights2, 0.5) },
		"missing weights":     func(s *modelState) { s.Weights1 = nil },
		"negative selections": func(s *modelState) { s.Selections = -1 },
	}

	for name, corrupt := range cases {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			if err := good.Save(dir); err != nil {
				t.Fatalf("Save: %v", err)
			}
			state := valid()
			corrupt(&state)
			data, err := json.Marshal(state)
			if err != nil {
				t.Fatalf("Marshal: %v", err)
			}
			if err := os.WriteFile(filepath.Join(dir, stateFile), data, 0o644); err != nil {
				t.Fatalf("WriteFile: %v", err)
			}

			e := newEngine()
			if err := e.Load(dir); err == nil {
				t.Fatal("Load accepted a corrupt model")
			}
			if e.Trained() {
				t.Fatal("engine reports Trained() after a rejected model")
			}
			// The rejected load must not have moved the weights either.
			fresh := newEngine()
			if !reflect.DeepEqual(e.layer1.Weights(), fresh.layer1.Weights()) {
				t.Error("hidden layer weights changed despite the rejected load")
			}
		})
	}
}

// encoding/json cannot represent NaN or Inf, so a diverged net must be caught
// before it reaches the encoder — otherwise saving fails forever with an opaque
// error and the learning silently stops.
func TestSaveRejectsNonFiniteWeights(t *testing.T) {
	for name, bad := range map[string]float64{"NaN": math.NaN(), "+Inf": math.Inf(1), "-Inf": math.Inf(-1)} {
		t.Run(name, func(t *testing.T) {
			e := newEngine()
			train(e, muslSelections)
			w := append([]float64(nil), e.layer1.Weights()...)
			w[0] = bad
			e.layer1.SetWeights(w)

			if err := e.Save(t.TempDir()); err == nil {
				t.Fatal("Save accepted non-finite weights")
			}
		})
	}
}

// A diverged net must read as "no opinion", not slip through the gate on NaN
// comparisons that are false in both directions.
func TestNonFiniteWeightsDeclineToDecide(t *testing.T) {
	e := newEngine()
	for round := 0; round < 20; round++ {
		train(e, muslSelections)
	}
	names := []string{
		"zoxide-x86_64-unknown-linux-musl.tar.gz",
		"zoxide-x86_64-unknown-linux-gnu.tar.gz",
	}
	if _, ok := e.Decide(names, "zoxide"); !ok {
		t.Fatal("precondition failed: trained engine should decide here")
	}

	w := append([]float64(nil), e.layer2.Weights()...)
	w[0] = math.NaN()
	e.layer2.SetWeights(w)

	for _, n := range names {
		if s := e.Score(n, "zoxide"); math.IsNaN(s) || s < 0 || s > 1 {
			t.Errorf("Score(%q) = %v with a diverged net, want [0,1]", n, s)
		}
	}
	if best, ok := e.Decide(names, "zoxide"); ok {
		t.Fatalf("diverged net decided on %q; want a prompt", best)
	}
}

func TestLoadRejectsGarbageAndMissingFiles(t *testing.T) {
	t.Run("empty dir", func(t *testing.T) {
		if err := newEngine().Load(t.TempDir()); err == nil {
			t.Fatal("Load of an empty directory succeeded")
		}
	})
	t.Run("no dir", func(t *testing.T) {
		if err := newEngine().Load(""); err == nil {
			t.Fatal("Load of an empty path succeeded")
		}
	})
	t.Run("truncated gob", func(t *testing.T) {
		dir := t.TempDir()
		good := newEngine()
		train(good, muslSelections)
		if err := good.Save(dir); err != nil {
			t.Fatalf("Save: %v", err)
		}
		gob := filepath.Join(dir, classifierFile)
		data, err := os.ReadFile(gob)
		if err != nil {
			t.Fatalf("ReadFile: %v", err)
		}
		if err := os.WriteFile(gob, data[:len(data)/2], 0o644); err != nil {
			t.Fatalf("WriteFile: %v", err)
		}
		e := newEngine()
		if err := e.Load(dir); err == nil {
			t.Fatal("Load accepted a truncated classifier")
		}
		if e.Trained() {
			t.Fatal("engine reports Trained() after a rejected model")
		}
	})
	t.Run("garbage json", func(t *testing.T) {
		dir := t.TempDir()
		if err := os.WriteFile(filepath.Join(dir, stateFile), []byte("{not json"), 0o644); err != nil {
			t.Fatalf("WriteFile: %v", err)
		}
		if err := newEngine().Load(dir); err == nil {
			t.Fatal("Load accepted invalid JSON")
		}
	})
}

// A failed save must not destroy the model already on disk.
func TestSaveLeavesPreviousModelIntactOnFailure(t *testing.T) {
	dir := t.TempDir()
	e := newEngine()
	train(e, muslSelections)
	if err := e.Save(dir); err != nil {
		t.Fatalf("Save: %v", err)
	}
	before, err := os.ReadFile(filepath.Join(dir, stateFile))
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}

	// A read-only directory makes the temp-file write fail.
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Skipf("cannot chmod temp dir: %v", err)
	}
	t.Cleanup(func() { os.Chmod(dir, 0o700) })

	train(e, muslSelections)
	if err := e.Save(dir); err == nil {
		t.Skip("save unexpectedly succeeded in a read-only directory (running as root?)")
	}

	after, err := os.ReadFile(filepath.Join(dir, stateFile))
	if err != nil {
		t.Fatalf("previous model unreadable after a failed save: %v", err)
	}
	if string(before) != string(after) {
		t.Fatal("failed save modified the model on disk")
	}
}

func TestSaveWritesNoLeftoverTempFiles(t *testing.T) {
	dir := t.TempDir()
	e := newEngine()
	train(e, muslSelections)
	if err := e.Save(dir); err != nil {
		t.Fatalf("Save: %v", err)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	want := []string{classifierFile, stateFile}
	if !reflect.DeepEqual(names, want) {
		t.Fatalf("model directory contains %v, want exactly %v", names, want)
	}
}

func TestReset(t *testing.T) {
	dir := t.TempDir()
	e := newEngine()
	train(e, muslSelections)
	if err := e.Save(dir); err != nil {
		t.Fatalf("Save: %v", err)
	}
	removed, err := Reset(dir)
	if err != nil {
		t.Fatalf("Reset: %v", err)
	}
	if !removed {
		t.Fatal("Reset reported nothing removed, but a model was saved")
	}
	if err := newEngine().Load(dir); err == nil {
		t.Fatal("Load succeeded after Reset")
	}

	// Reset on an already-clean directory is not an error, and says so.
	removed, err = Reset(dir)
	if err != nil {
		t.Fatalf("second Reset: %v", err)
	}
	if removed {
		t.Fatal("second Reset reported a removal")
	}

	if _, err := Reset(""); err == nil {
		t.Fatal("Reset of an empty path succeeded")
	}
}

// The status command distinguishes "nothing learned yet" from "model unusable",
// which relies on a missing model surfacing as os.ErrNotExist.
func TestLoadMissingModelIsNotExist(t *testing.T) {
	if err := newEngine().Load(t.TempDir()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("Load of an empty directory returned %v, want os.ErrNotExist", err)
	}
}

// Scores stay in [0,1] no matter what the filename looks like, so the
// confidence thresholds mean what they say.
func TestScoreStaysInRange(t *testing.T) {
	e := newEngine()
	train(e, muslSelections)
	names := []string{
		"", "-", "...", "ripgrep", "ripgrep.tar.gz",
		"UPPERCASE-LINUX-AMD64.TAR.GZ",
		"tool-" + string(make([]byte, 300)) + ".tar.gz",
		"日本語-linux-amd64.tar.gz",
	}
	for _, n := range names {
		s := e.Score(n, "ripgrep")
		if math.IsNaN(s) || s < 0 || s > 1 {
			t.Errorf("Score(%q) = %v, want [0,1]", n, s)
		}
	}
}

// Run with -race: the engine is shared process-wide.
func TestConcurrentUse(t *testing.T) {
	e := newEngine()
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			for j := 0; j < 20; j++ {
				s := muslSelections[j%len(muslSelections)]
				e.Observe(s.chosen, s.rejected, s.repo)
				e.Score(s.chosen, s.repo)
				e.Decide([]string{s.chosen, s.rejected[0]}, s.repo)
				e.Trained()
				e.Selections()
			}
		}(i)
	}
	wg.Wait()
}
