package ai

import (
	"bytes"
	"embed"
	"encoding/json"

	"github.com/jbrukh/bayesian"
)

//go:embed seed/model.json seed/bayesian.gob
var seedFS embed.FS

// loadSeed loads the embedded seed model if present.
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
