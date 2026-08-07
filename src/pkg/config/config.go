package config

import (
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/caarlos0/log"
)

var cfg config
var pathOverrides PathOverrides
var effectiveUID = os.Geteuid

// PathOverrides configures process-local path overrides from CLI flags.
type PathOverrides struct {
	ConfigFile string
	StateFile  string
	DefaultDir string
}

// SetPathOverrides configures explicit path choices from CLI flags.
func SetPathOverrides(overrides PathOverrides) {
	pathOverrides = overrides
}

type config struct {
	DefaultPath string             `json:"default_path"`
	Bins        map[string]*Binary `json:"bins"`
}

type Binary struct {
	Path       string `json:"path"`
	RemoteName string `json:"remote_name"`
	Version    string `json:"version"`
	Hash       string `json:"hash"`
	URL        string `json:"url"`
	Provider   string `json:"provider"`
	// Description holds the upstream repository description.
	Description string `json:"description,omitempty"`
	// PackagePath holds the relative binary path within an archive.
	PackagePath string `json:"package_path"`
	Pinned      bool   `json:"pinned"`
	// Tags groups binaries into organizational tiers.
	Tags []string `json:"tags,omitempty"`
	// Patch reports whether ELF patches are enabled for host compatibility.
	Patch bool `json:"patch,omitempty"`
	// StateURL holds the version-specific download URL.
	StateURL string `json:"-"`
	// SelectedAsset holds the normalized name of the chosen asset.
	SelectedAsset string `json:"-"`
	// AssetFingerprint holds the set of installable assets.
	AssetFingerprint []string `json:"-"`
	// PackageFingerprint holds the set of installable archive files.
	PackageFingerprint []string `json:"-"`
}

// stateEntry stores per-machine mutable binary state.
type stateEntry struct {
	Version            string   `json:"version"`
	RemoteName         string   `json:"remote_name,omitempty"`
	Hash               string   `json:"hash"`
	PackagePath        string   `json:"package_path"`
	Pinned             bool     `json:"pinned"`
	URL                string   `json:"url"`
	Description        string   `json:"description,omitempty"`
	SelectedAsset      string   `json:"selected_asset,omitempty"`
	AssetFingerprint   []string `json:"asset_fingerprint,omitempty"`
	PackageFingerprint []string `json:"package_fingerprint,omitempty"`
}

type state struct {
	Bins map[string]*stateEntry `json:"bins"`
}

func CheckAndLoad() error {
	configPath, err := getConfigPath()
	if err != nil {
		return err
	}

	confDir := filepath.Dir(configPath)
	systemConfig := isSystemDefaultConfig(configPath)
	if err := prepareConfigDir(confDir, systemConfig); err != nil {
		return err
	}
	log.Debugf("Config directory is: %s", confDir)

	// Load manifest. User/override manifests may be created on first run; the
	// root/system manifest is declarative and must already exist.
	mf, err := openManifest(configPath, systemConfig)
	if err != nil {
		return err
	}
	defer mf.Close()
	cfg = config{}
	if err := json.NewDecoder(mf).Decode(&cfg); err != nil {
		if err == io.EOF {
			cfg.Bins = map[string]*Binary{}
		} else {
			return err
		}
	}
	if cfg.Bins == nil {
		cfg.Bins = map[string]*Binary{}
	}

	defaultPathChanged, err := ensureDefaultPath()
	if err != nil {
		return err
	}

	// Entries may omit path; in that case install into default_path using the
	// map key (or URL basename) as the binary name.
	pathsChanged := normalizeManifestPaths()

	// Re-key any entries that aren't keyed by their Path before we overlay
	// state below. The rest of the codebase relies on key==Path.
	keysChanged := normalizeManifestKeys()

	if err := validateInstallPaths(); err != nil {
		return err
	}

	// Detect a legacy manifest that still stores remote_name (now state-only):
	// any RemoteName present right after decoding came from the manifest, so a
	// rewrite is needed to move it into the state file.
	remoteNameInManifest := false
	for _, b := range cfg.Bins {
		if b != nil && b.RemoteName != "" {
			remoteNameInManifest = true
			break
		}
	}

	// Load state and overlay. If an old state location is found, writeAll below
	// will move the data to the new config.state.json location.
	sp, err := getStatePath(configPath)
	if err != nil {
		return err
	}
	st := state{Bins: map[string]*stateEntry{}}
	loadedStatePath, loadedState := loadState(configPath, sp, &st)
	stateMigrationNeeded := loadedState && loadedStatePath != sp

	// Ensure current bins carry "default" before merging siblings, so a binary
	// present in both the main config and a sibling keeps "default" and gains
	// the sibling's tag (rather than silently losing its default membership).
	preTags := normalizeTags()

	// One-shot migration: fold any sibling manifests (e.g. other.json) into the
	// single config, tagging their binaries by filename, then .bak the source.
	mergeChanged := mergeSiblingManifests(configPath, &st)

	for k, sb := range st.Bins {
		if b, ok := cfg.Bins[k]; ok && sb != nil {
			b.Version = sb.Version
			if sb.RemoteName != "" {
				b.RemoteName = sb.RemoteName
			}
			if b.Description == "" {
				b.Description = sb.Description
			}
			b.Hash = sb.Hash
			b.PackagePath = sb.PackagePath
			b.Pinned = sb.Pinned
			b.StateURL = sb.URL
			b.SelectedAsset = sb.SelectedAsset
			b.AssetFingerprint = sb.AssetFingerprint
			b.PackageFingerprint = sb.PackageFingerprint
		}
	}

	if err := ensureRuntimeDirs(sp); err != nil {
		return err
	}

	// Migration: if manifest contains state but state file is empty, split.
	needsMigration := false
	if len(cfg.Bins) > 0 && (!loadedState || len(st.Bins) == 0) {
		for _, b := range cfg.Bins {
			if b == nil {
				continue
			}
			if b.Version != "" || b.Hash != "" || b.PackagePath != "" || b.Pinned {
				needsMigration = true
				break
			}
		}
	}
	if needsMigration || stateMigrationNeeded {
		log.Infof("Splitting config manifest and state into %s and %s", configPath, sp)
		if err := writeAll(); err != nil {
			return err
		}
	}

	// Ensure every binary has at least the "default" tag.
	tagsChanged := normalizeTags()

	// Normalize URLs in manifest to base repository links when possible
	urlsChanged := normalizeManifestURLs()
	providersChanged := normalizeProviders()
	if urlsChanged || providersChanged || defaultPathChanged || pathsChanged || keysChanged || mergeChanged || preTags || tagsChanged || remoteNameInManifest {
		if err := writeAll(); err != nil {
			return err
		}
	}

	log.Debugf("Download path set to %s", cfg.DefaultPath)
	return nil
}

func prepareConfigDir(dir string, systemConfig bool) error {
	if systemConfig {
		info, err := os.Stat(dir)
		if err != nil {
			if os.IsNotExist(err) {
				return fmt.Errorf("system config directory %s does not exist; create /etc/geto/list.json or set GETO_CONFIG_FILE", dir)
			}
			return err
		}
		if !info.IsDir() {
			return fmt.Errorf("system config path %s is not a directory", dir)
		}
		return nil
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("error creating config directory %s: %w", dir, err)
	}
	return nil
}

func openManifest(path string, systemConfig bool) (*os.File, error) {
	if systemConfig {
		f, err := os.Open(path)
		if err != nil {
			if os.IsNotExist(err) {
				return nil, fmt.Errorf("system config file %s does not exist; create it with Nix or set GETO_CONFIG_FILE", path)
			}
			return nil, err
		}
		return f, nil
	}

	f, err := os.Open(path)
	if err == nil {
		return f, nil
	}
	if !os.IsNotExist(err) {
		return nil, err
	}
	return os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o664)
}

func ensureDefaultPath() (bool, error) {
	if p, ok := explicitDefaultPath(); ok {
		changed := cfg.DefaultPath != p
		cfg.DefaultPath = p
		return changed, nil
	}
	if cfg.DefaultPath != "" {
		return false, nil
	}
	p, err := defaultInstallPath()
	if err != nil {
		return false, err
	}
	cfg.DefaultPath = p
	return true, nil
}

func ensureRuntimeDirs(statePath string) error {
	if err := os.MkdirAll(filepath.Dir(statePath), 0o755); err != nil {
		return fmt.Errorf("error creating state directory %s: %w", filepath.Dir(statePath), err)
	}
	if cfg.DefaultPath == "" {
		return nil
	}
	p := cfg.DefaultPath
	if !isSystemMode() {
		p = os.ExpandEnv(p)
	}
	if err := os.MkdirAll(p, 0o755); err != nil {
		return fmt.Errorf("error creating default install directory %s: %w", p, err)
	}
	return nil
}

func loadState(configPath, primaryPath string, st *state) (string, bool) {
	for _, p := range stateReadPaths(configPath, primaryPath) {
		sf, err := os.Open(p)
		if err != nil {
			continue
		}
		err = json.NewDecoder(sf).Decode(st)
		_ = sf.Close()
		if err == nil || err == io.EOF {
			return p, true
		}
		log.Warnf("Skipping state file %s: %v", p, err)
	}
	return "", false
}

func stateReadPaths(configPath, primaryPath string) []string {
	paths := []string{primaryPath}
	if !hasConfigPathOverride() && !hasStatePathOverride() {
		paths = append(paths, legacyStatePaths(configPath)...)
	}

	seen := map[string]struct{}{}
	out := make([]string, 0, len(paths))
	for _, p := range paths {
		if p == "" {
			continue
		}
		if _, ok := seen[p]; ok {
			continue
		}
		seen[p] = struct{}{}
		out = append(out, p)
	}
	return out
}

func legacyStatePaths(configPath string) []string {
	base := filepath.Base(configPath)
	oldName := strings.TrimSuffix(base, filepath.Ext(base)) + ".state.json"
	names := []string{oldName, "config.state.json"}
	var paths []string

	addNames := func(dir string) {
		for _, name := range names {
			paths = append(paths, filepath.Join(dir, name))
		}
	}

	if d := os.Getenv("XDG_DATA_HOME"); d != "" {
		addNames(filepath.Join(d, "bin"))
	}
	if home, err := os.UserHomeDir(); err == nil {
		switch runtime.GOOS {
		case "windows":
			if ld := os.Getenv("LOCALAPPDATA"); ld != "" {
				addNames(filepath.Join(ld, "bin"))
			}
			if ad := os.Getenv("APPDATA"); ad != "" {
				addNames(filepath.Join(ad, "bin"))
			}
			addNames(filepath.Join(home, ".local", "share", "bin"))
		default:
			addNames(filepath.Join(home, ".local", "share", "bin"))
		}
	}
	addNames(filepath.Dir(configPath))
	return paths
}

func normalizeManifestPaths() bool {
	changed := false
	for key, b := range cfg.Bins {
		if b == nil || b.Path != "" {
			continue
		}
		b.Path = filepath.Join(cfg.DefaultPath, manifestEntryName(key, b))
		changed = true
	}
	return changed
}

func manifestEntryName(key string, b *Binary) string {
	if key != "" && !strings.ContainsAny(key, `/\`) {
		return key
	}
	if b.RemoteName != "" {
		return b.RemoteName
	}
	if b.URL != "" {
		return defaultBinaryName(b.URL)
	}
	name := filepath.Base(key)
	if name == "." || name == string(filepath.Separator) || name == "" {
		return "bin"
	}
	return name
}

func defaultBinaryName(raw string) string {
	s := raw
	for _, p := range []string{"https://", "http://", "docker://", "goinstall://"} {
		s = strings.TrimPrefix(s, p)
	}
	s = strings.TrimSuffix(strings.TrimSuffix(s, "/"), ".git")
	name := filepath.Base(s)
	if name == "." || name == string(filepath.Separator) || name == "" {
		return "bin"
	}
	return name
}

func validateInstallPaths() error {
	if !isSystemMode() {
		return nil
	}
	if err := validateSystemPath("default_path", cfg.DefaultPath); err != nil {
		return err
	}
	for _, b := range cfg.Bins {
		if b == nil {
			continue
		}
		if err := validateSystemPath("binary path", b.Path); err != nil {
			return err
		}
	}
	return nil
}

func validateSystemPath(label, p string) error {
	if p == "" {
		return nil
	}
	if strings.Contains(p, "$") || strings.HasPrefix(p, "~") {
		return fmt.Errorf("system %s must be absolute and must not use shell/home expansion: %s", label, p)
	}
	if !filepath.IsAbs(p) {
		return fmt.Errorf("system %s must be absolute: %s", label, p)
	}
	return nil
}

// normalizeManifestKeys ensures every binary is keyed by its Path field.
// Older or hand-edited manifests sometimes key entries by the bare binary
// name (e.g. "codex" instead of "$HOME/.local/bin/codex"), which breaks the
// key==Path invariant the rest of the code relies on and leads to nil map
// lookups (e.g. a panic on `bin update <name>`). Returns true if it modified cfg.
func normalizeManifestKeys() bool {
	changed := false
	rekey := map[string]*Binary{}
	for k, b := range cfg.Bins {
		if b == nil {
			delete(cfg.Bins, k)
			changed = true
			continue
		}
		if b.Path != "" && k != b.Path {
			rekey[k] = b
		}
	}
	for k, b := range rekey {
		log.Debugf("Re-keying manifest entry %q to %q", k, b.Path)
		delete(cfg.Bins, k)
		cfg.Bins[b.Path] = b
		changed = true
	}
	return changed
}

// addTag returns tags with t appended if not already present.
func addTag(tags []string, t string) []string {
	for _, x := range tags {
		if x == t {
			return tags
		}
	}
	return append(tags, t)
}

// normalizeTags ensures every binary has at least the "default" tag.
// Returns true if it modified cfg.
func normalizeTags() bool {
	changed := false
	for _, b := range cfg.Bins {
		if b != nil && len(b.Tags) == 0 {
			b.Tags = []string{"default"}
			changed = true
		}
	}
	return changed
}

// mergeSiblingManifests folds any other *.json manifests living next to the
// main config (e.g. a legacy other.json) into the single config, tagging the
// merged binaries by the source filename (other.json -> "other"). Their state
// files are merged too, and the sources are renamed to *.bak so the merge runs
// only once. Returns true if anything was merged.
func mergeSiblingManifests(configPath string, st *state) bool {
	// Explicit config paths are used by declarative integrations (NixOS/Home
	// Manager, tests, scripts). Do not scan the containing directory for legacy
	// sibling manifests there: the directory may be /tmp, /var/lib, or another
	// shared location containing unrelated JSON inputs.
	if hasConfigPathOverride() || isSystemMode() {
		return false
	}

	dir := filepath.Dir(configPath)
	mainBase := filepath.Base(configPath)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}

	changed := false
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if name == mainBase ||
			!strings.HasSuffix(name, ".json") ||
			strings.HasSuffix(name, ".state.json") {
			continue
		}
		tag := strings.TrimSuffix(name, ".json")
		sibPath := filepath.Join(dir, name)

		var sib config
		sf, oerr := os.Open(sibPath)
		if oerr != nil {
			continue
		}
		derr := json.NewDecoder(sf).Decode(&sib)
		sf.Close()
		if derr != nil && derr != io.EOF {
			log.Warnf("Skipping sibling config %s: %v", name, derr)
			continue
		}

		merged := 0
		for _, b := range sib.Bins {
			if b == nil || b.Path == "" {
				continue
			}
			if existing, ok := cfg.Bins[b.Path]; ok {
				existing.Tags = addTag(existing.Tags, tag)
			} else {
				b.Tags = addTag(b.Tags, tag)
				cfg.Bins[b.Path] = b
			}
			merged++
		}

		// Merge the sibling's state (versions/hashes) so nothing is lost.
		if ssp, serr := getStatePath(sibPath); serr == nil {
			if ssf, e2 := os.Open(ssp); e2 == nil {
				var sst state
				if json.NewDecoder(ssf).Decode(&sst) == nil {
					for k, se := range sst.Bins {
						if se == nil {
							continue
						}
						if _, ok := st.Bins[k]; !ok {
							st.Bins[k] = se
						}
					}
				}
				ssf.Close()
				_ = os.Rename(ssp, ssp+".bak")
			}
		}

		if err := os.Rename(sibPath, sibPath+".bak"); err != nil {
			log.Warnf("Merged %s but could not rename it: %v", name, err)
		}
		log.Infof("Merged %d binaries from %s as tag %q", merged, name, tag)
		changed = true
	}
	return changed
}

// normalizeProviders backfills an empty Provider from the URL host so older or
// hand-edited manifests don't carry blank providers. Returns true if changed.
func normalizeProviders() bool {
	changed := false
	for _, b := range cfg.Bins {
		if b == nil || b.Provider != "" || b.URL == "" {
			continue
		}
		host := ""
		if u, err := url.Parse(b.URL); err == nil {
			host = u.Host
		}
		switch {
		case strings.Contains(host, "github"):
			b.Provider = "github"
		case strings.Contains(host, "gitlab"):
			b.Provider = "gitlab"
		case strings.Contains(host, "codeberg"):
			b.Provider = "codeberg"
		case strings.Contains(host, "releases.hashicorp.com"):
			b.Provider = "hashicorp"
		default:
			continue
		}
		changed = true
	}
	return changed
}

// normalizeManifestURLs rewrites manifest URLs to stable base links
// (e.g. https://github.com/owner/repo) when they currently point
// at release/tag or download URLs. Returns true if it modified cfg.
func normalizeManifestURLs() bool {
	changed := false
	for _, b := range cfg.Bins {
		if b == nil || b.URL == "" {
			continue
		}
		base := normalizeBaseURL(b.URL, b.Provider)
		if base != "" && base != b.URL {
			// Preserve the original, potentially version-specific URL in state
			if b.StateURL == "" {
				b.StateURL = b.URL
			}
			log.Debugf("Normalizing manifest URL from %s to %s", b.URL, base)
			b.URL = base
			changed = true
		}
	}
	return changed
}

// normalizeBaseURL attempts to derive a stable repository/home URL from
// a potentially versioned or release-specific URL.
func normalizeBaseURL(raw, provider string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return ""
	}

	// If provider isn't set in the manifest (older entries), infer it from host
	inferredProvider := provider
	if inferredProvider == "" {
		host := u.Host
		if strings.Contains(host, "github") {
			inferredProvider = "github"
		} else if strings.Contains(host, "codeberg") {
			inferredProvider = "codeberg"
		} else if strings.Contains(host, "gitlab") {
			inferredProvider = "gitlab"
		}
	}

	switch inferredProvider {
	case "github", "codeberg", "gitlab":
		parts := strings.Split(u.Path, "/")
		if len(parts) >= 3 {
			return fmt.Sprintf("%s://%s/%s/%s", u.Scheme, u.Host, parts[1], parts[2])
		}
	}
	return ""
}

func Get() *config {
	return &cfg
}

// ConfigDir returns the directory holding the manifest (and config).
func ConfigDir() string {
	p, err := getConfigPath()
	if err != nil {
		return ""
	}
	return filepath.Dir(p)
}

// StateDir returns the directory holding bin's mutable state — the state file
// and anything else learned at runtime, as opposed to the user-editable config.
// It returns "" when no state path can be resolved.
func StateDir() string {
	p, err := getStatePath("")
	if err != nil {
		return ""
	}
	return filepath.Dir(p)
}

// UpsertBinary adds or updats an existing
// binary resource in the config
func UpsertBinary(c *Binary) error {
	if c != nil {
		// Preserve existing state-only fields unless the caller overrides them
		if existing, ok := cfg.Bins[c.Path]; ok {
			if c.StateURL == "" {
				c.StateURL = existing.StateURL
			}
			if c.SelectedAsset == "" {
				c.SelectedAsset = existing.SelectedAsset
			}
			if len(c.AssetFingerprint) == 0 {
				c.AssetFingerprint = existing.AssetFingerprint
			}
			if len(c.PackageFingerprint) == 0 {
				c.PackageFingerprint = existing.PackageFingerprint
			}
			if c.RemoteName == "" {
				c.RemoteName = existing.RemoteName
			}
			// Tags live in the manifest; preserve them unless the caller is
			// explicitly setting them (e.g. install or the `tag` command).
			if len(c.Tags) == 0 {
				c.Tags = existing.Tags
			}
			if c.Description == "" {
				c.Description = existing.Description
			}
			// Patch is a portable per-binary intent; preserve it unless re-set.
			if !c.Patch {
				c.Patch = existing.Patch
			}
		}
		if len(c.Tags) == 0 {
			c.Tags = []string{"default"}
		}
		cfg.Bins[c.Path] = c
		if err := writeAll(); err != nil {
			return err
		}
	}
	return nil
}

// ForgetBinarySelection clears the remembered release-asset and inner-archive
// choices for one binary while keeping its URL, tags, hash, version, pin state,
// and installed path. The next install/ensure/update must select an asset again
// instead of silently reusing a stale or wrong choice.
func ForgetBinarySelection(path string) error {
	b, ok := cfg.Bins[path]
	if !ok {
		expanded := os.ExpandEnv(path)
		for k, candidate := range cfg.Bins {
			if candidate != nil && os.ExpandEnv(candidate.Path) == expanded {
				path = k
				b = candidate
				ok = true
				break
			}
		}
	}
	if !ok || b == nil {
		return fmt.Errorf("binary path %s not found", path)
	}

	b.RemoteName = ""
	b.PackagePath = ""
	b.SelectedAsset = ""
	b.AssetFingerprint = nil
	b.PackageFingerprint = nil
	cfg.Bins[path] = b
	return writeAll()
}

// RemoveBinaries removes the specified paths
// from bin configuration. It doesn't care about the order
func RemoveBinaries(paths []string) error {
	for _, p := range paths {
		delete(cfg.Bins, p)
	}
	return writeAll()
}

// writeAll writes manifest and state to their respective locations
func writeAll() error {
	configPath, err := getConfigPath()
	if err != nil {
		return err
	}
	statePath, err := getStatePath(configPath)
	if err != nil {
		return err
	}
	if !isSystemDefaultConfig(configPath) {
		if err := writeManifest(configPath); err != nil {
			return err
		}
	} else {
		log.Debugf("Skipping manifest write for declarative system config %s", configPath)
	}
	if err := writeState(statePath); err != nil {
		return err
	}
	return nil
}

type manifestConfig struct {
	DefaultPath string                     `json:"default_path"`
	Bins        map[string]*manifestBinary `json:"bins"`
}

type manifestBinary struct {
	Path        string   `json:"path"`
	URL         string   `json:"url"`
	Provider    string   `json:"provider"`
	Description string   `json:"description,omitempty"`
	Tags        []string `json:"tags,omitempty"`
	Patch       bool     `json:"patch,omitempty"`
}

func writeManifest(manifestPath string) error {
	dir := filepath.Dir(manifestPath)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	f, err := os.OpenFile(manifestPath, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0664)
	if err != nil {
		return err
	}
	defer f.Close()

	// sanitize state fields out of manifest
	out := manifestConfig{DefaultPath: cfg.DefaultPath, Bins: map[string]*manifestBinary{}}
	for k, b := range cfg.Bins {
		if b == nil {
			continue
		}
		out.Bins[k] = &manifestBinary{
			Path:        b.Path,
			URL:         b.URL,
			Provider:    b.Provider,
			Description: b.Description,
			Tags:        b.Tags,
			Patch:       b.Patch,
		}
	}
	enc := json.NewEncoder(f)
	enc.SetIndent("", "    ")
	return enc.Encode(out)
}

func writeState(statePath string) error {
	dir := filepath.Dir(statePath)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	f, err := os.OpenFile(statePath, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0664)
	if err != nil {
		return err
	}
	defer f.Close()

	st := state{Bins: map[string]*stateEntry{}}
	for k, b := range cfg.Bins {
		if b == nil {
			continue
		}
		st.Bins[k] = &stateEntry{
			Version:            b.Version,
			RemoteName:         b.RemoteName,
			Hash:               b.Hash,
			PackagePath:        b.PackagePath,
			Pinned:             b.Pinned,
			URL:                b.StateURL,
			Description:        b.Description,
			SelectedAsset:      b.SelectedAsset,
			AssetFingerprint:   b.AssetFingerprint,
			PackageFingerprint: b.PackageFingerprint,
		}
	}
	enc := json.NewEncoder(f)
	enc.SetIndent("", "    ")
	return enc.Encode(st)
}

// GetArch returns the running program's architecture (one of amd64, arm64, 386
// and so on) together with the aliases release assets commonly name it by.
func GetArch() []string {
	res := []string{runtime.GOARCH}
	switch runtime.GOARCH {
	case "amd64":
		res = append(res, "x86_64")
		res = append(res, "x64")
		res = append(res, "x86-64")
		res = append(res, "intel_64")
		res = append(res, "intel64")
	case "arm64":
		res = append(res, "aarch64")
		res = append(res, "arm_64")
		res = append(res, "arm-64")
		res = append(res, "armv8")
	case "386":
		res = append(res, "i386")
		res = append(res, "i686")
		res = append(res, "x86")
	}
	return res
}

// GetOS returns the running program's operating system (linux or windows)
// together with the aliases release assets commonly name it by.
func GetOS() []string {
	res := []string{runtime.GOOS}
	if runtime.GOOS == "windows" {
		res = append(res, "win")
	}
	return res
}

func explicitDefaultPath() (string, bool) {
	if p := pathOverrides.DefaultDir; p != "" {
		return p, true
	}
	if p := os.Getenv("GETO_DEFAULT_PATH"); p != "" {
		return p, true
	}
	return "", false
}

func defaultInstallPath() (string, error) {
	if isSystemMode() {
		return "/usr/local/bin", nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".local", "bin"), nil
}

func hasConfigPathOverride() bool {
	return pathOverrides.ConfigFile != "" ||
		os.Getenv("GETO_CONFIG_FILE") != "" ||
		os.Getenv("GETO_CONFIG_HOME") != ""
}

func hasStatePathOverride() bool {
	return pathOverrides.StateFile != "" ||
		os.Getenv("GETO_STATE_FILE") != "" ||
		os.Getenv("GETO_STATE_HOME") != ""
}

func isSystemMode() bool {
	return runtime.GOOS != "windows" && effectiveUID() == 0
}

func isSystemDefaultConfig(configPath string) bool {
	return isSystemMode() && !hasConfigPathOverride() && configPath == "/etc/geto/list.json"
}

// getConfigPath returns the path to the manifest file (list.json). Root defaults
// to the system/declarative config in /etc/geto; normal users default to XDG
// config (or ~/.config/geto), with ~/.geto/list.json kept as a legacy fallback
// only when no XDG config exists.
func getConfigPath() (string, error) {
	if p := pathOverrides.ConfigFile; p != "" {
		return p, nil
	}
	if p := os.Getenv("GETO_CONFIG_FILE"); p != "" {
		return p, nil
	}
	if p := os.Getenv("GETO_CONFIG_HOME"); p != "" {
		return filepath.Join(p, "list.json"), nil
	}
	if isSystemMode() {
		return "/etc/geto/list.json", nil
	}

	home, homeErr := os.UserHomeDir()
	configHome := os.Getenv("XDG_CONFIG_HOME")
	if configHome == "" {
		if homeErr != nil {
			return "", homeErr
		}
		configHome = filepath.Join(home, ".config")
	}
	configPath := filepath.Join(configHome, "geto", "list.json")
	if _, err := os.Stat(configPath); err == nil || homeErr != nil {
		return configPath, nil
	}

	legacyPath := filepath.Join(home, ".geto", "list.json")
	if _, err := os.Stat(legacyPath); err == nil {
		return legacyPath, nil
	}
	return configPath, nil
}

// getStatePath computes the per-machine mutable state path. Unlike the
// manifest, root writes under /var/lib and users write under XDG_STATE_HOME (or
// ~/.local/state); legacy XDG_DATA_HOME paths are read separately for migration.
func getStatePath(manifestPath string) (string, error) {
	if p := pathOverrides.StateFile; p != "" {
		return p, nil
	}
	if p := os.Getenv("GETO_STATE_FILE"); p != "" {
		return p, nil
	}
	if p := os.Getenv("GETO_STATE_HOME"); p != "" {
		return filepath.Join(p, "config.state.json"), nil
	}
	if isSystemMode() {
		return "/var/lib/geto/config.state.json", nil
	}

	if d := os.Getenv("XDG_STATE_HOME"); d != "" {
		return filepath.Join(d, "geto", "config.state.json"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	if runtime.GOOS == "windows" {
		if ld := os.Getenv("LOCALAPPDATA"); ld != "" {
			return filepath.Join(ld, "geto", "config.state.json"), nil
		}
		if ad := os.Getenv("APPDATA"); ad != "" {
			return filepath.Join(ad, "geto", "config.state.json"), nil
		}
	}
	return filepath.Join(home, ".local", "state", "geto", "config.state.json"), nil
}

func GetOSSpecificExtensions() []string {
	switch runtime.GOOS {
	case "linux":
		return []string{"AppImage"}
	case "windows":
		return []string{"exe"}
	default:
		return nil
	}
}

func envBool(name string) bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(name))) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}
