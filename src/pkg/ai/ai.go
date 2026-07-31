// Package ai implements the small on-device learner that helps bin pick the
// right release asset when the deterministic scorer can't decide on its own.
//
// It only ever runs on a tie. The scorer in pkg/assets ranks candidates by
// OS/arch/repo-name hits; when several candidates come out exactly equal, this
// package is asked whether it is confident enough to break the tie. When it
// isn't — which includes every fresh install — the user is prompted as before,
// and that answer is fed back through Observe as a training example. Keeping
// the prompt as the fallback matters: it is the only source of training data,
// so a model that suppressed it would freeze at whatever it learned first.
//
// Two models cooperate. A naive-bayes classifier over filename tokens learns
// vocabulary preferences (musl over gnu, static over dynamic, tar over zip)
// that the hand-written rules know nothing about. A small neural net then
// combines that text score with a handful of structural features into a single
// confidence. The features are deliberately restricted to properties that can
// actually differ between tied candidates: OS and arch belong to the scorer,
// and by the time we are called they are equal by definition.
package ai

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"math/rand"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"unicode"

	"github.com/jbrukh/bayesian"
	nanonn "github.com/zserge/nanonn/go"
)

const (
	MatchClass    bayesian.Class = "Match"
	MismatchClass bayesian.Class = "Mismatch"
)

// modelVersion is bumped whenever the tokenizer or the feature vector changes.
// Both invalidate every previously saved model, since old weights were fit
// against inputs that no longer mean the same thing.
//
// 2: features reworked against a corpus of real releases (see seed/corpus.json).
const modelVersion = 2

const (
	classifierFile = "bayesian.gob"
	stateFile      = "model.json"
)

const (
	numHidden = 8

	learningRate = 0.1
	trainEpochs  = 5

	// initSeed keeps weight initialisation deterministic. nanonn seeds Dense
	// layers from the global math/rand, which Go auto-seeds per process, so an
	// untrained engine would otherwise rank the same assets differently on
	// every invocation — unacceptable for a tool that installs binaries.
	initSeed = 0x62696e41 // "binA"
)

// Confidence gate. The engine only breaks a tie once it has learned from enough
// real selections and the winner is clearly ahead of the runner-up. Anything
// less falls through to the prompt.
const (
	minSelections = 5
	minTopScore   = 0.60
	minMargin     = 0.20
)

// Feature indices, named so the persisted weight vector and the extraction code
// can't drift apart silently. Every one of these was chosen because it varies
// between candidates that the deterministic scorer rates equally — the shape of
// real ties, measured over seed/corpus.json rather than guessed.
const (
	fBayes    = iota // classifier's P(Match) over the filename's tokens
	fMusl            // musl build: static, no glibc coupling
	fGnu             // glibc build
	fStatic          // explicitly labelled static
	fRepoRank        // primary artifact vs companion binary vs unrelated
	fVariant         // marked as a secondary artifact (symbols, profile, cuda, ...)
	fTarball         // .tar / .tar.gz / .tgz
	fZip             // .zip
	fExotic          // .bz2 / .xz / .zst / .7z — rarely the primary artifact

	numFeatures
)

type Engine struct {
	mu         sync.Mutex
	classifier *bayesian.Classifier
	nn         nanonn.Network
	layer1     nanonn.Layer
	layer2     nanonn.Layer
	selections int  // this user's own selections; persisted
	seeded     bool // holding the embedded seed model rather than a user's
}

// modelState is the on-disk companion to bayesian.gob. Version and the weight
// lengths are validated on load; nanonn's SetWeights copies into a fixed-size
// slice, so a truncated file would otherwise leave part of the net at its
// initial values with no error reported.
type modelState struct {
	Version    int `json:"version"`
	Selections int `json:"selections"`
	// Seeded records that this model descends from the embedded seed. Without it
	// a user who has made one selection would save a model that reads as
	// untrained on the next run, throwing the seed's head start away.
	Seeded   bool      `json:"seeded"`
	Weights1 []float64 `json:"weights1"`
	Weights2 []float64 `json:"weights2"`
}

// NewEngine returns an engine preloaded with the embedded seed model, so a
// fresh install starts from sensible defaults rather than from nothing. See
// seed.go for how that model is built.
func NewEngine() *Engine {
	e := newEngine()
	e.loadSeed()
	return e
}

// newEngine returns an untrained engine with deterministic initial weights. The
// seed generator uses this so it never trains on top of a previous seed.
func newEngine() *Engine {
	l1 := nanonn.Dense(numHidden, numFeatures)
	l2 := nanonn.Dense(1, numHidden)

	r := rand.New(rand.NewSource(initSeed))
	seedWeights(r, l1, numFeatures, numHidden)
	seedWeights(r, l2, numHidden, 1)

	n, err := nanonn.New(l1, l2)
	if err != nil {
		// Only reachable if the layer sizes above disagree, which is a
		// programming error rather than a runtime condition.
		panic(fmt.Sprintf("ai: inconsistent network shape: %v", err))
	}

	return &Engine{
		classifier: bayesian.NewClassifier(MatchClass, MismatchClass),
		nn:         n,
		layer1:     l1,
		layer2:     l2,
	}
}

// seedWeights overwrites nanonn's randomly seeded weights with a deterministic
// Xavier/Glorot uniform draw, which suits the sigmoid activations nanonn uses.
// Zero-initialising instead would be deterministic too, but it makes every
// hidden unit identical and they never differentiate.
func seedWeights(r *rand.Rand, l nanonn.Layer, fanIn, fanOut int) {
	limit := math.Sqrt(6 / float64(fanIn+fanOut))
	w := make([]float64, len(l.Weights()))
	for i := range w {
		w[i] = (r.Float64()*2 - 1) * limit
	}
	l.SetWeights(w)
}

// Selections reports how many user selections the engine has learned from.
func (e *Engine) Selections() int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.selections
}

// Trained reports whether the engine has enough history to be worth consulting:
// either it carries the embedded seed model, or this user has made enough
// selections of their own.
func (e *Engine) Trained() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.trained()
}

func (e *Engine) trained() bool {
	return e.seeded || e.selections >= minSelections
}

// Score returns the model's confidence, in [0,1], that filename is the asset
// the user wants. Only the ordering between candidates from the same release is
// meaningful; the absolute value is not calibrated.
func (e *Engine) Score(filename, repoName string) float64 {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.score(filename, repoName)
}

func (e *Engine) score(filename, repoName string) float64 {
	out := e.nn.Predict(e.features(filename, repoName))
	if len(out) == 0 {
		return 0
	}
	// nanonn returns the output layer's internal buffer, which the next Predict
	// overwrites. Reading it here, under the lock, is what keeps that safe.
	s := out[0]
	if math.IsNaN(s) {
		// NaN compares false against everything, so it would slip straight
		// through the confidence gate below. Treat a diverged net as no opinion.
		return 0
	}
	return math.Max(0, math.Min(1, s))
}

// Decide picks a winner among candidates the deterministic scorer rated equally.
// ok is false when the engine hasn't seen enough selections, or when the winner
// isn't clearly ahead — including exact ties, which keeps the outcome
// independent of the order names are passed in. The caller should then ask the
// user and feed the answer back through Observe.
func (e *Engine) Decide(names []string, repoName string) (best string, ok bool) {
	e.mu.Lock()
	defer e.mu.Unlock()

	switch len(names) {
	case 0:
		return "", false
	case 1:
		return names[0], true
	}
	if !e.trained() {
		return "", false
	}

	top, second := math.Inf(-1), math.Inf(-1)
	for _, n := range names {
		switch s := e.score(n, repoName); {
		case s > top:
			top, second, best = s, top, n
		case s > second:
			second = s
		}
	}
	if top < minTopScore || top-second < minMargin {
		return "", false
	}
	return best, true
}

// Observe records a real user selection: chosen is the asset they picked,
// rejected the equally-scored candidates they passed over.
//
// Note the absence of a ConvertTermsFreqToTfIdf call. bayesian panics if it is
// invoked more than once, and it persists that fact into the gob, so calling it
// here would crash on the second selection in a process and on the first
// selection of every later run. It is also a no-op for the plain (non-TF-IDF)
// classifier this engine builds.
func (e *Engine) Observe(chosen string, rejected []string, repoName string) {
	e.mu.Lock()
	defer e.mu.Unlock()

	e.learn(chosen, rejected, repoName)
	e.selections++
}

// ObserveRejections records only that some candidates are wrong, without
// claiming any of the others is right. The seed generator uses it for groups
// whose remaining candidates are a genuine toss-up (a gnu/musl pair, say): the
// companion binaries and debug artifacts in the group are still worth learning
// as negatives, but asserting a winner there would be inventing a preference.
func (e *Engine) ObserveRejections(rejected []string, repoName string) {
	e.mu.Lock()
	defer e.mu.Unlock()

	e.learn("", rejected, repoName)
}

// learn runs the shared training step. chosen may be empty, in which case only
// the negatives are learned. Callers must hold the lock.
//
// A group is one winner against several losers — about 1:3 across the corpus.
// Feeding the losers unopposed teaches the net to answer "no" to everything,
// which surfaces as the confidence gate abstaining on cases it should call, so
// the winner is paired against each loser in turn to keep the classes balanced.
func (e *Engine) learn(chosen string, rejected []string, repoName string) {
	if len(rejected) == 0 {
		if chosen != "" {
			e.classifier.Learn(tokenize(chosen), MatchClass)
			for i := 0; i < trainEpochs; i++ {
				e.nn.Train(e.features(chosen, repoName), []float64{1}, learningRate)
			}
		}
		return
	}

	for _, r := range rejected {
		if chosen != "" {
			e.classifier.Learn(tokenize(chosen), MatchClass)
		}
		e.classifier.Learn(tokenize(r), MismatchClass)
	}

	// Features are re-extracted on every step on purpose: fBayes is a function of
	// the classifier that was just updated, so the net trains against the input
	// distribution it will actually see at Score time.
	for i := 0; i < trainEpochs; i++ {
		for _, r := range rejected {
			if chosen != "" {
				e.nn.Train(e.features(chosen, repoName), []float64{1}, learningRate)
			}
			e.nn.Train(e.features(r, repoName), []float64{0}, learningRate)
		}
	}
}

// Save writes the model to dir, replacing any previous one. Both files are
// written to a temporary name and renamed into place, so an interrupted save
// leaves the old model intact rather than a truncated one. Two bin processes
// saving at once is last-writer-wins: one selection's learning is lost, but
// neither reader ever sees a partial file.
func (e *Engine) Save(dir string) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if dir == "" {
		return errors.New("no model directory")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}

	// encoding/json cannot represent NaN or Inf, so a diverged net would fail
	// to marshal with an opaque error. Catch it here with a clear one instead.
	if !allFinite(e.layer1.Weights()) || !allFinite(e.layer2.Weights()) {
		return errors.New("refusing to save non-finite weights")
	}

	// Encode into memory first so a failing encode can't touch the disk.
	var buf bytes.Buffer
	if err := e.classifier.WriteGob(&buf); err != nil {
		return fmt.Errorf("encoding classifier: %w", err)
	}
	state, err := json.Marshal(modelState{
		Version:    modelVersion,
		Selections: e.selections,
		Seeded:     e.seeded,
		Weights1:   e.layer1.Weights(),
		Weights2:   e.layer2.Weights(),
	})
	if err != nil {
		return fmt.Errorf("encoding weights: %w", err)
	}

	if err := writeFileAtomic(filepath.Join(dir, classifierFile), buf.Bytes()); err != nil {
		return err
	}
	return writeFileAtomic(filepath.Join(dir, stateFile), state)
}

// Load restores a model previously written by Save. A missing, unreadable, or
// version-mismatched model is reported as an error and leaves the engine at its
// deterministic initial state — an untrained engine declines to decide, so a
// corrupt model degrades to "ask the user" rather than to silent guessing.
func (e *Engine) Load(dir string) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if dir == "" {
		return errors.New("no model directory")
	}

	raw, err := os.ReadFile(filepath.Join(dir, stateFile))
	if err != nil {
		return err
	}
	var state modelState
	if err := json.Unmarshal(raw, &state); err != nil {
		return fmt.Errorf("reading %s: %w", stateFile, err)
	}
	if state.Version != modelVersion {
		return fmt.Errorf("model version %d, want %d", state.Version, modelVersion)
	}
	if got, want := len(state.Weights1), len(e.layer1.Weights()); got != want {
		return fmt.Errorf("hidden layer has %d weights, want %d", got, want)
	}
	if got, want := len(state.Weights2), len(e.layer2.Weights()); got != want {
		return fmt.Errorf("output layer has %d weights, want %d", got, want)
	}
	// Unreachable through JSON, which can't encode NaN or Inf, but cheap
	// insurance against a hand-edited or differently-encoded model.
	if !allFinite(state.Weights1) || !allFinite(state.Weights2) {
		return errors.New("model contains non-finite weights")
	}
	if state.Selections < 0 {
		return fmt.Errorf("model reports %d selections", state.Selections)
	}

	gobData, err := os.ReadFile(filepath.Join(dir, classifierFile))
	if err != nil {
		return err
	}
	c, err := bayesian.NewClassifierFromReader(bytes.NewReader(gobData))
	if err != nil {
		return fmt.Errorf("reading %s: %w", classifierFile, err)
	}
	// Models written by earlier builds carry DidConvertTfIdf, which arms the
	// panic described on Observe. This engine never converts, so clear it.
	c.DidConvertTfIdf = false

	// Everything validated: commit.
	e.classifier = c
	e.layer1.SetWeights(state.Weights1)
	e.layer2.SetWeights(state.Weights2)
	e.selections = state.Selections
	e.seeded = state.Seeded
	return nil
}

// Reset deletes the learned model from dir, so the next run starts over. It is
// idempotent; removed reports whether there was anything to delete.
func Reset(dir string) (removed bool, err error) {
	if dir == "" {
		return false, errors.New("no model directory")
	}
	for _, name := range []string{classifierFile, stateFile} {
		switch err := os.Remove(filepath.Join(dir, name)); {
		case err == nil:
			removed = true
		case !os.IsNotExist(err):
			return removed, err
		}
	}
	return removed, nil
}

func (e *Engine) features(filename, repoName string) []float64 {
	lower := strings.ToLower(filename)
	tarball, zip, exotic := archiveKind(lower)

	f := make([]float64, numFeatures)
	f[fBayes] = e.textScore(tokenize(filename))
	f[fMusl] = boolFeature(strings.Contains(lower, "musl"))
	f[fGnu] = boolFeature(strings.Contains(lower, "gnu") || strings.Contains(lower, "glibc"))
	f[fStatic] = boolFeature(hasToken(lower, "static"))
	f[fRepoRank] = repoNameRank(lower, repoName)
	f[fVariant] = boolFeature(hasToken(lower, variantTokens...))
	f[fTarball] = boolFeature(tarball)
	f[fZip] = boolFeature(zip)
	f[fExotic] = boolFeature(exotic)
	return f
}

// repoNameRank separates a project's primary artifact from the companion
// binaries shipped beside it — the most common real ambiguity in the corpus:
// atuin vs atuin-server, codex vs codex-app-server, hugo vs hugo_extended,
// netbird vs netbird-ui, lockbook vs lockbook-cli, cloudflared vs
// cloudflared-fips.
//
//	1.0  the name is the repo name followed straight by the platform
//	0.5  the repo name is in there, but with extra words attached
//	0.0  the repo name doesn't appear (or we don't have one)
func repoNameRank(lower, repoName string) float64 {
	// strings.Contains(x, "") is true, so an empty repo name has to short-circuit
	// or this feature would read 1 for every URL-based install.
	if repoName == "" {
		return 0
	}
	repoParts := splitTokens(repoName)
	if len(repoParts) == 0 {
		return 0
	}

	parts := splitTokens(lower)
	if len(parts) > len(repoParts) && slicesEqual(parts[:len(repoParts)], repoParts) {
		// What follows the name decides: a platform word means this is the
		// project itself, another name word means it's something shipped beside it.
		if next := parts[len(repoParts)]; platformTokens[next] || isNumeric(next) {
			return 1.0
		}
	}
	if strings.Contains(lower, strings.ToLower(repoName)) {
		return 0.5
	}
	return 0
}

// variantTokens mark an asset as a secondary artifact: debug symbols, profiling
// builds, hardware-specific builds, packaging by-products. Drawn from what
// actually shows up in tie groups across the corpus.
var variantTokens = []string{
	"debug", "dbg", "symbols", "syms", "profile", "baseline",
	"src", "source", "sources", "vendor", "sbom", "package", "npm",
	"installer", "setup", "gui", "desktop", "app", "ui",
	"android", "ios", "cuda", "rocm", "vulkan", "mlx", "jetpack",
	"jetpack5", "jetpack6", "fips",
}

// platformTokens are the words that follow a project's name in a release asset:
// operating system, architecture, toolchain and container format. They mark
// where the project name ends and the platform description begins.
var platformTokens = map[string]bool{
	// operating system
	"linux": true, "windows": true, "win": true, "win32": true,
	"win64": true, "freebsd": true, "netbsd": true, "openbsd": true,
	"dragonfly": true, "solaris": true, "illumos": true, "android": true,
	// architecture
	"amd64": true, "x86": true, "x64": true, "i386": true, "i686": true,
	"i586": true, "arm": true, "arm64": true, "aarch64": true, "armv6": true,
	"armv7": true, "armv8": true, "armhf": true, "armel": true, "ppc64": true,
	"ppc64le": true, "s390x": true, "mips": true, "mipsle": true,
	"mips64": true, "mips64le": true, "riscv64": true, "loong64": true,
	"universal": true, "universal2": true, "intel": true, "intel64": true,
	"powerpc": true,
	// toolchain / environment, as they appear in rust and zig target triples
	"gnu": true, "gnueabi": true, "gnueabihf": true, "musl": true,
	"musleabi": true, "musleabihf": true, "msvc": true, "mingw": true,
	"mingw32": true, "mingw64": true, "unknown": true, "pc": true,
	"none": true, "static": true,
	// container format
	"tar": true, "gz": true, "tgz": true, "zip": true, "bz2": true,
	"tbz": true, "tbz2": true, "xz": true, "txz": true, "zst": true,
	"tzst": true, "7z": true, "exe": true, "appimage": true, "deb": true,
	"rpm": true, "dmg": true, "pkg": true, "msi": true, "bin": true,
}

// archiveKind classifies the container format. A bare executable is all false,
// which is a distinct and meaningful combination.
func archiveKind(lower string) (tarball, zip, exotic bool) {
	// Longest suffix first: ".exe.tar.gz" and ".tar.gz.zip" both occur.
	switch {
	case hasAnySuffix(lower, ".tar.gz", ".tgz", ".tar"):
		return true, false, false
	case hasAnySuffix(lower, ".zip"):
		return false, true, false
	case hasAnySuffix(lower, ".tar.bz2", ".tbz2", ".tbz", ".bz2",
		".tar.xz", ".txz", ".xz", ".tar.zst", ".tzst", ".zst", ".7z"):
		return false, false, true
	}
	return false, false, false
}

func hasAnySuffix(s string, suffixes ...string) bool {
	for _, suffix := range suffixes {
		if strings.HasSuffix(s, suffix) {
			return true
		}
	}
	return false
}

func slicesEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func isNumeric(s string) bool { return numericToken.MatchString(s) }

// textScore is the classifier's probability that the name belongs to the Match
// class, or 0.5 ("no opinion") before anything has been learned.
func (e *Engine) textScore(tokens []string) float64 {
	if len(tokens) == 0 || e.classifier.Learned() == 0 {
		return 0.5
	}
	// ErrUnderflow is deliberately ignored: the scores it comes with are
	// recovered from the log domain, which is the more reliable of the two.
	scores, _, _, _ := e.classifier.SafeProbScores(tokens)
	if len(scores) == 0 {
		return 0.5
	}
	return scores[0] // index 0 is MatchClass
}

var (
	numericToken = regexp.MustCompile(`^v?[0-9]+$`)
	hashToken    = regexp.MustCompile(`^[0-9a-f]{7,}$`)
)

// splitTokens lowercases and splits on anything that isn't a letter or digit.
func splitTokens(name string) []string {
	return strings.FieldsFunc(strings.ToLower(name), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	})
}

// tokenize produces the classifier's vocabulary. Version numbers, commit
// hashes and single characters are dropped: they are unique per release, so
// keeping them would grow the saved model without bound and dilute the tokens
// that actually distinguish one asset from another.
func tokenize(name string) []string {
	fields := splitTokens(name)
	out := make([]string, 0, len(fields))
	for _, f := range fields {
		if len(f) < 2 || len(f) > 32 {
			continue
		}
		if numericToken.MatchString(f) || hashToken.MatchString(f) {
			continue
		}
		out = append(out, f)
	}
	return out
}

// hasToken matches whole tokens, so "sources" doesn't fire on "resources".
func hasToken(name string, want ...string) bool {
	for _, t := range splitTokens(name) {
		for _, w := range want {
			if t == w {
				return true
			}
		}
	}
	return false
}

func boolFeature(b bool) float64 {
	if b {
		return 1
	}
	return 0
}

func allFinite(xs []float64) bool {
	for _, x := range xs {
		if math.IsNaN(x) || math.IsInf(x, 0) {
			return false
		}
	}
	return true
}

// writeFileAtomic writes data through a temporary file in the same directory
// and renames it into place.
func writeFileAtomic(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".*.tmp")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name) // no-op once the rename below succeeds

	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(name, 0o644); err != nil {
		return err
	}
	return os.Rename(name, path)
}
