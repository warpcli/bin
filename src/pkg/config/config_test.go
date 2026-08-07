package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func resetConfigTestState(t *testing.T, uid int) {
	t.Helper()

	oldOverrides := pathOverrides
	oldEffectiveUID := effectiveUID
	oldCfg := cfg
	pathOverrides = PathOverrides{}
	effectiveUID = func() int { return uid }
	cfg = config{}
	t.Cleanup(func() {
		pathOverrides = oldOverrides
		effectiveUID = oldEffectiveUID
		cfg = oldCfg
	})

	for _, name := range []string{
		"GETO_CONFIG_FILE",
		"GETO_CONFIG_HOME",
		"GETO_STATE_FILE",
		"GETO_STATE_HOME",
		"GETO_DEFAULT_PATH",
		"GETO_NONINTERACTIVE",
		"XDG_CONFIG_HOME",
		"XDG_STATE_HOME",
		"XDG_DATA_HOME",
	} {
		t.Setenv(name, "")
	}
}

func TestForgetBinarySelectionClearsOnlySavedChoices(t *testing.T) {
	resetConfigTestState(t, 1000)
	tmp := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(tmp, "config"))
	t.Setenv("XDG_DATA_HOME", filepath.Join(tmp, "data"))

	path := "$HOME/.local/bin/atuin"
	cfg = config{
		DefaultPath: "$HOME/.local/bin",
		Bins: map[string]*Binary{
			path: {
				Path:               path,
				RemoteName:         "atuin-server",
				Version:            "v1.0.0",
				Hash:               "abc123",
				URL:                "https://github.com/atuinsh/atuin",
				Provider:           "github",
				Description:        "shell history",
				PackagePath:        "atuin-server",
				Pinned:             true,
				Tags:               []string{"default", "shell"},
				Patch:              true,
				StateURL:           "https://github.com/atuinsh/atuin/releases/tag/v1.0.0",
				SelectedAsset:      "atuin-server-aarch64-unknown-linux-musl.tar.gz",
				AssetFingerprint:   []string{"old-asset"},
				PackageFingerprint: []string{"old-package"},
			},
		},
	}

	if err := ForgetBinarySelection(path); err != nil {
		t.Fatalf("ForgetBinarySelection: %v", err)
	}

	b := cfg.Bins[path]
	if b.RemoteName != "" || b.PackagePath != "" || b.SelectedAsset != "" ||
		len(b.AssetFingerprint) != 0 || len(b.PackageFingerprint) != 0 {
		t.Fatalf("selection memory was not cleared: %+v", b)
	}
	if b.Version != "v1.0.0" || b.Hash != "abc123" || b.URL != "https://github.com/atuinsh/atuin" ||
		b.Provider != "github" || b.Description != "shell history" || !b.Pinned || !b.Patch ||
		b.StateURL != "https://github.com/atuinsh/atuin/releases/tag/v1.0.0" ||
		len(b.Tags) != 2 || b.Tags[0] != "default" || b.Tags[1] != "shell" {
		t.Fatalf("non-selection fields changed unexpectedly: %+v", b)
	}
}

func TestPathOverridesForDeclarativeIntegrations(t *testing.T) {
	resetConfigTestState(t, 1000)
	tmp := t.TempDir()
	configFile := filepath.Join(tmp, "cfg", "list.json")
	stateFile := filepath.Join(tmp, "state", "state.json")

	t.Setenv("GETO_CONFIG_FILE", configFile)
	t.Setenv("GETO_STATE_FILE", stateFile)

	gotConfig, err := getConfigPath()
	if err != nil {
		t.Fatalf("getConfigPath: %v", err)
	}
	if gotConfig != configFile {
		t.Fatalf("config path = %q, want %q", gotConfig, configFile)
	}

	gotState, err := getStatePath(configFile)
	if err != nil {
		t.Fatalf("getStatePath: %v", err)
	}
	if gotState != stateFile {
		t.Fatalf("state path = %q, want %q", gotState, stateFile)
	}
}

func TestNonInteractiveDefaultPathFromEnvironment(t *testing.T) {
	resetConfigTestState(t, 1000)
	tmp := t.TempDir()
	t.Setenv("GETO_CONFIG_FILE", filepath.Join(tmp, "list.json"))
	t.Setenv("GETO_STATE_FILE", filepath.Join(tmp, "state.json"))
	t.Setenv("GETO_DEFAULT_PATH", filepath.Join(tmp, "bin"))
	t.Setenv("GETO_NONINTERACTIVE", "1")
	cfg = config{}

	if err := CheckAndLoad(); err != nil {
		t.Fatalf("CheckAndLoad: %v", err)
	}
	if cfg.DefaultPath != filepath.Join(tmp, "bin") {
		t.Fatalf("DefaultPath = %q", cfg.DefaultPath)
	}
}

func TestExplicitConfigPathDoesNotMergeSiblingJSON(t *testing.T) {
	resetConfigTestState(t, 1000)
	tmp := t.TempDir()
	configFile := filepath.Join(tmp, "list.json")
	sibling := filepath.Join(tmp, "desired.json")

	t.Setenv("GETO_CONFIG_FILE", configFile)
	t.Setenv("GETO_STATE_FILE", filepath.Join(tmp, "state.json"))
	t.Setenv("GETO_DEFAULT_PATH", filepath.Join(tmp, "bin"))
	t.Setenv("GETO_NONINTERACTIVE", "1")
	cfg = config{}

	if err := os.WriteFile(sibling, []byte(`{"not":"a bin manifest"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := CheckAndLoad(); err != nil {
		t.Fatalf("CheckAndLoad: %v", err)
	}
	if _, err := os.Stat(sibling); err != nil {
		t.Fatalf("sibling JSON should not be renamed/merged: %v", err)
	}
	if _, err := os.Stat(sibling + ".bak"); !os.IsNotExist(err) {
		t.Fatalf("sibling JSON was unexpectedly renamed to .bak")
	}
}

func TestStateDescriptionOverlaysDeclarativeManifest(t *testing.T) {
	resetConfigTestState(t, 1000)
	tmp := t.TempDir()
	configFile := filepath.Join(tmp, "list.json")
	stateFile := filepath.Join(tmp, "state.json")
	installDir := filepath.Join(tmp, "bin")
	binPath := filepath.Join(installDir, "mdbook")

	t.Setenv("GETO_CONFIG_FILE", configFile)
	t.Setenv("GETO_STATE_FILE", stateFile)
	t.Setenv("GETO_DEFAULT_PATH", installDir)
	t.Setenv("GETO_NONINTERACTIVE", "1")
	cfg = config{}

	if err := os.WriteFile(configFile, []byte(`{
		"default_path": "`+installDir+`",
		"bins": {
			"`+binPath+`": {
				"path": "`+binPath+`",
				"url": "github.com/rust-lang/mdBook",
				"provider": "github",
				"tags": ["default"],
				"patch": true
			}
		}
	}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(stateFile, []byte(`{
		"bins": {
			"`+binPath+`": {
				"version": "v0.5.3",
				"hash": "abc123",
				"package_path": "mdbook",
				"url": "github.com/rust-lang/mdBook",
				"description": "Create book from markdown files"
			}
		}
	}`), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := CheckAndLoad(); err != nil {
		t.Fatalf("CheckAndLoad: %v", err)
	}

	got := cfg.Bins[binPath]
	if got == nil {
		t.Fatal("expected mdbook entry")
	}
	if got.Description != "Create book from markdown files" {
		t.Fatalf("Description = %q", got.Description)
	}
	if got.Version != "v0.5.3" || got.Hash != "abc123" || got.PackagePath != "mdbook" {
		t.Fatalf("state fields were not overlaid: %+v", got)
	}
}

func TestUserDefaultPathsUseXDGConfigAndState(t *testing.T) {
	resetConfigTestState(t, 1000)
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	configPath, err := getConfigPath()
	if err != nil {
		t.Fatalf("getConfigPath: %v", err)
	}
	if want := filepath.Join(tmp, ".config", "geto", "list.json"); configPath != want {
		t.Fatalf("config path = %q, want %q", configPath, want)
	}

	statePath, err := getStatePath(configPath)
	if err != nil {
		t.Fatalf("getStatePath: %v", err)
	}
	if want := filepath.Join(tmp, ".local", "state", "geto", "config.state.json"); statePath != want {
		t.Fatalf("state path = %q, want %q", statePath, want)
	}

	if err := CheckAndLoad(); err != nil {
		t.Fatalf("CheckAndLoad: %v", err)
	}
	if want := filepath.Join(tmp, ".local", "bin"); cfg.DefaultPath != want {
		t.Fatalf("DefaultPath = %q, want %q", cfg.DefaultPath, want)
	}
	for _, dir := range []string{filepath.Join(tmp, ".local", "bin"), filepath.Join(tmp, ".local", "state", "geto")} {
		if st, err := os.Stat(dir); err != nil || !st.IsDir() {
			t.Fatalf("expected directory %s to exist, stat=%v err=%v", dir, st, err)
		}
	}
}

func TestSystemDefaultPathsDoNotUseRootHome(t *testing.T) {
	resetConfigTestState(t, 0)
	tmp := t.TempDir()
	t.Setenv("HOME", filepath.Join(tmp, "root"))

	configPath, err := getConfigPath()
	if err != nil {
		t.Fatalf("getConfigPath: %v", err)
	}
	if configPath != "/etc/geto/list.json" {
		t.Fatalf("config path = %q", configPath)
	}

	statePath, err := getStatePath(configPath)
	if err != nil {
		t.Fatalf("getStatePath: %v", err)
	}
	if statePath != "/var/lib/geto/config.state.json" {
		t.Fatalf("state path = %q", statePath)
	}

	defaultPath, err := defaultInstallPath()
	if err != nil {
		t.Fatalf("defaultInstallPath: %v", err)
	}
	if defaultPath != "/usr/local/bin" {
		t.Fatalf("default install path = %q", defaultPath)
	}
}

func TestRootEnvOverridesAllowManagedTempPaths(t *testing.T) {
	resetConfigTestState(t, 0)
	tmp := t.TempDir()
	configFile := filepath.Join(tmp, "etc", "geto", "list.json")
	stateFile := filepath.Join(tmp, "var", "lib", "geto", "config.state.json")
	installDir := filepath.Join(tmp, "usr", "local", "bin")

	t.Setenv("GETO_CONFIG_FILE", configFile)
	t.Setenv("GETO_STATE_FILE", stateFile)
	t.Setenv("GETO_DEFAULT_PATH", installDir)

	if err := CheckAndLoad(); err != nil {
		t.Fatalf("CheckAndLoad: %v", err)
	}
	if cfg.DefaultPath != installDir {
		t.Fatalf("DefaultPath = %q, want %q", cfg.DefaultPath, installDir)
	}
	for _, path := range []string{configFile, stateFile, installDir} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("expected %s to exist: %v", path, err)
		}
	}
}

func TestPathlessManifestUsesDefaultPath(t *testing.T) {
	resetConfigTestState(t, 1000)
	tmp := t.TempDir()
	configFile := filepath.Join(tmp, "list.json")
	installDir := filepath.Join(tmp, "bin")

	t.Setenv("GETO_CONFIG_FILE", configFile)
	t.Setenv("GETO_STATE_FILE", filepath.Join(tmp, "state.json"))
	t.Setenv("GETO_DEFAULT_PATH", installDir)

	if err := os.WriteFile(configFile, []byte(`{
		"default_path": "`+installDir+`",
		"bins": {
			"fd": {
				"url": "https://github.com/sharkdp/fd",
				"provider": "github",
				"tags": ["default"]
			}
		}
	}`), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := CheckAndLoad(); err != nil {
		t.Fatalf("CheckAndLoad: %v", err)
	}
	wantPath := filepath.Join(installDir, "fd")
	if cfg.Bins[wantPath] == nil {
		t.Fatalf("missing normalized entry %s in %#v", wantPath, cfg.Bins)
	}
	if cfg.Bins[wantPath].Path != wantPath {
		t.Fatalf("Path = %q, want %q", cfg.Bins[wantPath].Path, wantPath)
	}
}

func TestSystemConfigRejectsHomeExpansionPaths(t *testing.T) {
	resetConfigTestState(t, 0)
	tmp := t.TempDir()
	configFile := filepath.Join(tmp, "list.json")

	t.Setenv("GETO_CONFIG_FILE", configFile)
	t.Setenv("GETO_STATE_FILE", filepath.Join(tmp, "state.json"))
	t.Setenv("HOME", filepath.Join(tmp, "root"))

	if err := os.WriteFile(configFile, []byte(`{
		"default_path": "$HOME/.local/bin",
		"bins": {}
	}`), 0o644); err != nil {
		t.Fatal(err)
	}

	err := CheckAndLoad()
	if err == nil {
		t.Fatal("expected system config with $HOME default_path to fail")
	}
	if !strings.Contains(err.Error(), "must be absolute") && !strings.Contains(err.Error(), "must not use") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestLegacyShareStateMigratesToXDGState(t *testing.T) {
	resetConfigTestState(t, 1000)
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)
	configFile := filepath.Join(tmp, ".config", "geto", "list.json")
	legacyStateFile := filepath.Join(tmp, ".local", "share", "bin", "list.state.json")
	binPath := filepath.Join(tmp, ".local", "bin", "fd")

	if err := os.MkdirAll(filepath.Dir(configFile), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(legacyStateFile), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configFile, []byte(`{
		"default_path": "`+filepath.Join(tmp, ".local", "bin")+`",
		"bins": {
			"`+binPath+`": {
				"path": "`+binPath+`",
				"url": "https://github.com/sharkdp/fd",
				"provider": "github",
				"tags": ["default"]
			}
		}
	}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(legacyStateFile, []byte(`{
		"bins": {
			"`+binPath+`": {
				"version": "v10.0.0",
				"hash": "abc123",
				"package_path": "fd",
				"url": "https://github.com/sharkdp/fd"
			}
		}
	}`), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := CheckAndLoad(); err != nil {
		t.Fatalf("CheckAndLoad: %v", err)
	}
	if cfg.Bins[binPath].Version != "v10.0.0" {
		t.Fatalf("legacy state was not loaded: %+v", cfg.Bins[binPath])
	}
	newStateFile := filepath.Join(tmp, ".local", "state", "geto", "config.state.json")
	if _, err := os.Stat(newStateFile); err != nil {
		t.Fatalf("new state file was not written: %v", err)
	}
}
