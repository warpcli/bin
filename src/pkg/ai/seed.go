package ai

import (
	"bytes"
	"embed"
	"encoding/json"

	"github.com/jbrukh/bayesian"
)

// The seed model ships inside the binary so a fresh install has sensible
// defaults on day one instead of needing several selections first. It is built
// offline from a corpus of real release-asset names — see seed/corpus.json for
// the raw names, seed/groups.json for the labelled tie groups, and
// src/pkg/assets/seedgroups_test.go for the rules that produced those labels.
//
// Its labels come from that rule set, not from anyone's actual choices, so treat
// it as a prior rather than as learned truth. A user's own selections are
// trained on top of it and override it over time.
//
// Only the two model files are embedded. corpus.json and groups.json are
// generator inputs and stay out of the binary.
//
//go:embed seed/model.json seed/bayesian.gob
var seedFS embed.FS

// loadSeed applies the embedded model. Failures are silent by design: an engine
// with initial weights is untrained, and an untrained engine declines to decide,
// so a missing or unusable seed degrades to "ask the user".
func (e *Engine) loadSeed() {
	state, err := seedFS.ReadFile("seed/model.json")
	if err != nil {
		return
	}
	gobData, err := seedFS.ReadFile("seed/bayesian.gob")
	if err != nil {
		return
	}

	var m modelState
	if err := json.Unmarshal(state, &m); err != nil || m.Version != modelVersion {
		return
	}
	if len(m.Weights1) != len(e.layer1.Weights()) || len(m.Weights2) != len(e.layer2.Weights()) {
		return
	}
	if !allFinite(m.Weights1) || !allFinite(m.Weights2) {
		return
	}
	c, err := bayesian.NewClassifierFromReader(bytes.NewReader(gobData))
	if err != nil {
		return
	}
	c.DidConvertTfIdf = false

	e.classifier = c
	e.layer1.SetWeights(m.Weights1)
	e.layer2.SetWeights(m.Weights2)
	e.seeded = true
}

// Seeded reports whether this engine started from the embedded seed model.
func (e *Engine) Seeded() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.seeded
}
