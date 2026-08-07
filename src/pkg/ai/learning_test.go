package ai

import (
	"testing"
)

// gnuPicks provides test selections preferring gnu over musl.
var gnuPicks = []selection{
	{"fd", "fd-x86_64-unknown-linux-gnu.tar.gz", []string{"fd-x86_64-unknown-linux-musl.tar.gz"}},
	{"bat", "bat-x86_64-unknown-linux-gnu.tar.gz", []string{"bat-x86_64-unknown-linux-musl.tar.gz"}},
	{"ripgrep", "ripgrep-x86_64-unknown-linux-gnu.tar.gz", []string{"ripgrep-x86_64-unknown-linux-musl.tar.gz"}},
	{"jj", "jj-x86_64-unknown-linux-gnu.tar.gz", []string{"jj-x86_64-unknown-linux-musl.tar.gz"}},
}

func TestUserLearningAccumulatesAcrossRuns(t *testing.T) {
	dir := t.TempDir()
	musl := "someapp-x86_64-unknown-linux-musl.tar.gz"
	gnu := "someapp-x86_64-unknown-linux-gnu.tar.gz"

	run := func() *Engine {
		e := NewEngine()
		if err := e.Load(dir); err != nil && e.Selections() != 0 {
			t.Fatalf("Load: %v", err)
		}
		train(e, gnuPicks)
		if err := e.Save(dir); err != nil {
			t.Fatalf("Save: %v", err)
		}
		return e
	}
	reload := func() *Engine {
		e := NewEngine()
		if err := e.Load(dir); err != nil {
			t.Fatalf("Load: %v", err)
		}
		return e
	}

	fresh := NewEngine()
	if fresh.Score(musl, "someapp") <= fresh.Score(gnu, "someapp") {
		t.Fatal("precondition: the seed should prefer musl")
	}

	var flippedAt int
	for round := 1; round <= 50; round++ {
		run()
		e := reload()
		if e.Score(gnu, "someapp") > e.Score(musl, "someapp") {
			flippedAt = e.Selections()
			break
		}
	}
	if flippedAt == 0 {
		e := reload()
		t.Fatalf("after %d selections the user still cannot override the seed (musl=%.3f gnu=%.3f)",
			e.Selections(), e.Score(musl, "someapp"), e.Score(gnu, "someapp"))
	}
	t.Logf("user preference overtook the seed after %d selections", flippedAt)

	for round := 0; round < 40; round++ {
		run()
	}
	e := reload()
	best, ok := e.Decide([]string{musl, gnu}, "someapp")
	if !ok {
		t.Fatalf("still abstaining after %d selections (musl=%.3f gnu=%.3f)",
			e.Selections(), e.Score(musl, "someapp"), e.Score(gnu, "someapp"))
	}
	if best != gnu {
		t.Fatalf("Decide chose %q after %d gnu selections, want the gnu build", best, e.Selections())
	}
	t.Logf("after %d selections it decides gnu on its own (musl=%.3f gnu=%.3f)",
		e.Selections(), e.Score(musl, "someapp"), e.Score(gnu, "someapp"))
}

func TestEngineAbstainsWhileUserAndSeedDisagree(t *testing.T) {
	dir := t.TempDir()
	musl := "someapp-x86_64-unknown-linux-musl.tar.gz"
	gnu := "someapp-x86_64-unknown-linux-gnu.tar.gz"

	sawAbstention := false
	for round := 1; round <= 25; round++ {
		e := NewEngine()
		_ = e.Load(dir)
		train(e, gnuPicks)
		if err := e.Save(dir); err != nil {
			t.Fatalf("Save: %v", err)
		}
		if _, ok := e.Decide([]string{musl, gnu}, "someapp"); !ok {
			sawAbstention = true
			break
		}
	}
	if !sawAbstention {
		t.Error("never abstained while the user was contradicting the seed; a disagreement should bring the prompt back")
	}
}

// The seed must never be a floor the user cannot get below: a saved model has to
// carry the user's accumulated learning, not silently reset to the seed.
func TestSavedModelIsNotResetBySeedOnLoad(t *testing.T) {
	dir := t.TempDir()

	e := NewEngine()
	for i := 0; i < 5; i++ {
		train(e, gnuPicks)
	}
	if err := e.Save(dir); err != nil {
		t.Fatalf("Save: %v", err)
	}
	wantSelections := e.Selections()
	name := "fd-x86_64-unknown-linux-gnu.tar.gz"
	want := e.Score(name, "fd")

	reloaded := NewEngine() // seed first...
	if err := reloaded.Load(dir); err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := reloaded.Selections(); got != wantSelections {
		t.Errorf("Selections() = %d after reload, want %d", got, wantSelections)
	}
	if got := reloaded.Score(name, "fd"); got != want {
		t.Errorf("Score = %.6f after reload, want %.6f: the seed overwrote the user's model", got, want)
	}
	if !reloaded.Trained() {
		t.Error("a model with user history reports itself untrained")
	}
}
