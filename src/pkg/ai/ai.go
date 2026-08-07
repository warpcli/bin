// Package ai ranks release asset candidates using naive Bayes and neural network scoring.
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

// modelVersion identifies the feature vector schema version.
const modelVersion = 2

const (
	classifierFile = "bayesian.gob"
	stateFile      = "model.json"
)

const (
	numHidden = 8

	learningRate = 0.1
	trainEpochs  = 5

	// initSeed sets the deterministic random seed for weight initialization.
	initSeed = 0x62696e41
)

// Gate thresholds for automatic tie-breaking.
const (
	minSelections = 5
	minTopScore   = 0.60
	minMargin     = 0.20
)

// Feature indices for candidate scoring.
const (
	fBayes = iota
	fMusl
	fGnu
	fStatic
	fRepoRank
	fVariant
	fTarball
	fZip
	fExotic

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

// Observe records a user asset selection and trains the engine.
func (e *Engine) Observe(chosen string, rejected []string, repoName string) {
	e.mu.Lock()
	defer e.mu.Unlock()

	e.learn(chosen, rejected, repoName)
	e.selections++
}

// ObserveRejections records candidate rejections without selecting a winner.
func (e *Engine) ObserveRejections(rejected []string, repoName string) {
	e.mu.Lock()
	defer e.mu.Unlock()

	e.learn("", rejected, repoName)
}

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

	for i := 0; i < trainEpochs; i++ {
		for _, r := range rejected {
			if chosen != "" {
				e.nn.Train(e.features(chosen, repoName), []float64{1}, learningRate)
			}
			e.nn.Train(e.features(r, repoName), []float64{0}, learningRate)
		}
	}
}

// Save writes the model files atomically to dir.
func (e *Engine) Save(dir string) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if dir == "" {
		return errors.New("no model directory")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}

	if !allFinite(e.layer1.Weights()) || !allFinite(e.layer2.Weights()) {
		return errors.New("refusing to save non-finite weights")
	}

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

// Load restores model state from dir.
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
	c.DidConvertTfIdf = false

	e.classifier = c
	e.layer1.SetWeights(state.Weights1)
	e.layer2.SetWeights(state.Weights2)
	e.selections = state.Selections
	e.seeded = state.Seeded
	return nil
}

// Reset removes persisted model files from dir.
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

// repoNameRank ranks how closely filename matches repoName.
func repoNameRank(lower, repoName string) float64 {
	if repoName == "" {
		return 0
	}
	repoParts := splitTokens(repoName)
	if len(repoParts) == 0 {
		return 0
	}

	parts := splitTokens(lower)
	if len(parts) > len(repoParts) && slicesEqual(parts[:len(repoParts)], repoParts) {
		if next := parts[len(repoParts)]; platformTokens[next] || isNumeric(next) {
			return 1.0
		}
	}
	if strings.Contains(lower, strings.ToLower(repoName)) {
		return 0.5
	}
	return 0
}

// variantTokens identifies secondary artifacts.
var variantTokens = []string{
	"debug", "dbg", "symbols", "syms", "profile", "baseline",
	"src", "source", "sources", "vendor", "sbom", "package", "npm",
	"installer", "setup", "gui", "desktop", "app", "ui",
	"android", "ios", "cuda", "rocm", "vulkan", "mlx", "jetpack",
	"jetpack5", "jetpack6", "fips",
}

// platformTokens identifies platform keywords.
var platformTokens = map[string]bool{
	"linux": true, "windows": true, "win": true, "win32": true,
	"win64": true, "freebsd": true, "netbsd": true, "openbsd": true,
	"dragonfly": true, "solaris": true, "illumos": true, "android": true,
	"amd64": true, "x86": true, "x64": true, "i386": true, "i686": true,
	"i586": true, "arm": true, "arm64": true, "aarch64": true, "armv6": true,
	"armv7": true, "armv8": true, "armhf": true, "armel": true, "ppc64": true,
	"ppc64le": true, "s390x": true, "mips": true, "mipsle": true,
	"mips64": true, "mips64le": true, "riscv64": true, "loong64": true,
	"universal": true, "universal2": true, "intel": true, "intel64": true,
	"powerpc": true,
	"gnu":     true, "gnueabi": true, "gnueabihf": true, "musl": true,
	"musleabi": true, "musleabihf": true, "msvc": true, "mingw": true,
	"mingw32": true, "mingw64": true, "unknown": true, "pc": true,
	"none": true, "static": true,
	"tar": true, "gz": true, "tgz": true, "zip": true, "bz2": true,
	"tbz": true, "tbz2": true, "xz": true, "txz": true, "zst": true,
	"tzst": true, "7z": true, "exe": true, "appimage": true, "deb": true,
	"rpm": true, "dmg": true, "pkg": true, "msi": true, "bin": true,
}

// archiveKind classifies the container format suffix.
func archiveKind(lower string) (tarball, zip, exotic bool) {
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

// textScore returns the classifier probability for MatchClass.
func (e *Engine) textScore(tokens []string) float64 {
	if len(tokens) == 0 || e.classifier.Learned() == 0 {
		return 0.5
	}
	scores, _, _, _ := e.classifier.SafeProbScores(tokens)
	if len(scores) == 0 {
		return 0.5
	}
	return scores[0]
}

var (
	numericToken = regexp.MustCompile(`^v?[0-9]+$`)
	hashToken    = regexp.MustCompile(`^[0-9a-f]{7,}$`)
)

// splitTokens returns alphanumeric tokens from name.
func splitTokens(name string) []string {
	return strings.FieldsFunc(strings.ToLower(name), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	})
}

// tokenize extracts normalized vocabulary tokens from name.
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

// hasToken reports whether name contains any of the target tokens.
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

// writeFileAtomic writes data to path using an atomic rename.
func writeFileAtomic(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".*.tmp")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)

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
