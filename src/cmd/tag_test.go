package cmd

import (
	"testing"

	"github.com/bresilla/geto/src/pkg/config"
)

func TestBinTagsDefault(t *testing.T) {
	if got := binTags(&config.Binary{}); len(got) != 1 || got[0] != "default" {
		t.Fatalf("untagged binary should be default, got %v", got)
	}
	if got := binTags(&config.Binary{Tags: []string{"a", "b"}}); len(got) != 2 {
		t.Fatalf("explicit tags should be returned, got %v", got)
	}
}

func TestBinHasAnyTag(t *testing.T) {
	b := &config.Binary{Tags: []string{"default", "other"}}
	if !binHasAnyTag(b, []string{"other"}) {
		t.Fatal("expected match on 'other'")
	}
	if binHasAnyTag(b, []string{"essential"}) {
		t.Fatal("did not expect match on 'essential'")
	}
	if !binHasAnyTag(&config.Binary{}, []string{"default"}) {
		t.Fatal("untagged binary should match default")
	}
}

func TestWantedTagsAndAll(t *testing.T) {
	defer func() { activeTags = nil }()

	activeTags = nil
	if w := wantedTags(); len(w) != 1 || w[0] != "default" {
		t.Fatalf("no flag should default to 'default', got %v", w)
	}
	if tagFilterAll() {
		t.Fatal("no flag should not be 'all'")
	}

	activeTags = []string{"all"}
	if !tagFilterAll() {
		t.Fatal("--tag all should report all")
	}
}

func TestSelectByTag(t *testing.T) {
	defer func() { activeTags = nil }()

	bins := map[string]*config.Binary{
		"a": {Path: "a", Tags: []string{"default"}},
		"b": {Path: "b", Tags: []string{"other"}},
		"c": {Path: "c", Tags: []string{"default", "other"}},
		"d": {Path: "d"},
	}

	activeTags = nil
	if got := selectByTag(bins); len(got) != 3 {
		t.Fatalf("default scope should match 3, got %d", len(got))
	}

	activeTags = []string{"other"}
	if got := selectByTag(bins); len(got) != 2 {
		t.Fatalf("other scope should match 2, got %d", len(got))
	}

	activeTags = []string{"all"}
	if got := selectByTag(bins); len(got) != 4 {
		t.Fatalf("all scope should match 4, got %d", len(got))
	}
}
