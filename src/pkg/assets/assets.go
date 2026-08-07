package assets

import (
	"archive/tar"
	"bytes"
	"compress/bzip2"
	"compress/gzip"
	"debug/elf"
	"debug/pe"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"

	"github.com/bresilla/bin/src/pkg/ai"
	"github.com/bresilla/bin/src/pkg/config"
	"github.com/bresilla/bin/src/pkg/options"
	bstrings "github.com/bresilla/bin/src/pkg/strings"
	"github.com/bresilla/bin/src/pkg/ui"
	"github.com/caarlos0/log"
	"github.com/h2non/filetype"
	"github.com/h2non/filetype/matchers"
	"github.com/h2non/filetype/types"
	"github.com/klauspost/compress/zstd"
	"github.com/krolaw/zipstream"
	"github.com/xi2/xz"
)

var (
	msiType = filetype.AddType("msi", "application/octet-stream")
	ascType = filetype.AddType("asc", "text/plain")

	aiEngine *ai.Engine
	aiOnce   sync.Once
)

// AIModelDir returns the directory path for the AI model.
func AIModelDir() string {
	if aiDisabled() {
		return ""
	}
	dir := config.StateDir()
	if dir == "" {
		return ""
	}
	return filepath.Join(dir, "ai")
}

// aiDisabled reports whether BIN_NO_AI opts out of asset-selection learning.
func aiDisabled() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("BIN_NO_AI"))) {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}

// getAIEngine returns the process-wide AI engine.
func getAIEngine() *ai.Engine {
	aiOnce.Do(func() {
		dir := AIModelDir()
		if dir == "" {
			log.Debugf("Asset-selection learning is disabled")
			return
		}
		e := ai.NewEngine()
		if err := e.Load(dir); err != nil {
			log.Debugf("No usable asset-selection model in %s (%v); starting fresh", dir, err)
		} else {
			log.Debugf("Loaded asset-selection model from %s (%d selections)", dir, e.Selections())
		}
		aiEngine = e
	})
	return aiEngine
}

// aiEngineFor resolves the AI engine used for tie-breaking.
var aiEngineFor = getAIEngine

// aiPick returns the AI-selected asset for tie-breaking.
func aiPick(repoName string, matches []*FilteredAsset) *FilteredAsset {
	engine := aiEngineFor()
	if engine == nil || !engine.Trained() {
		return nil
	}

	names := make([]string, 0, len(matches))
	for _, m := range matches {
		names = append(names, m.Name)
	}

	bestName, ok := engine.Decide(names, repoName)
	if !ok {
		return nil
	}
	for _, m := range matches {
		if m.Name == bestName {
			return m
		}
	}
	return nil
}

// aiBasis returns the origin description of an automatic asset choice.
func aiBasis() string {
	engine := aiEngineFor()
	if engine == nil {
		return ""
	}
	switch n := engine.Selections(); {
	case n == 0:
		return "using bin's built-in defaults"
	case engine.Seeded():
		return fmt.Sprintf("using bin's built-in defaults and your %d past choice(s)", n)
	default:
		return fmt.Sprintf("based on your %d past choice(s)", n)
	}
}

func aiLearn(repoName string, chosen *FilteredAsset, matches []*FilteredAsset) {
	engine := aiEngineFor()
	if engine == nil || chosen == nil || len(matches) <= 1 {
		return
	}
	rejected := make([]string, 0, len(matches)-1)
	for _, m := range matches {
		if m != chosen {
			rejected = append(rejected, m.Name)
		}
	}
	engine.Observe(chosen.Name, rejected, repoName)
	dir := AIModelDir()
	if dir != "" {
		if err := engine.Save(dir); err != nil {
			log.Debugf("Failed to save asset-selection model: %v", err)
		}
	}
}

var Quiet bool

type Asset struct {
	Name        string
	DisplayName string
	URL         string
}

func (g Asset) String() string {
	if g.DisplayName != "" {
		return g.DisplayName
	}
	return g.Name
}

type FilteredAsset struct {
	RepoName     string
	Name         string
	DisplayName  string
	URL          string
	score        int
	ExtraHeaders map[string]string
	Fingerprint  []string
	Data         []byte
	Sidecars     map[string]*Sidecar
}

type finalFile struct {
	Source             io.Reader
	Name               string
	PackagePath        string
	PackageFingerprint []string
	Sidecars           map[string]*Sidecar
}

// Sidecar represents a shared library file or symlink.
type Sidecar struct {
	Data []byte
	Link string
}

type platformResolver interface {
	GetOS() []string
	GetArch() []string
	GetOSSpecificExtensions() []string
}

type Filter struct {
	opts               *FilterOpts
	repoName           string
	name               string
	packagePath        string
	packageFingerprint []string
	sidecars           map[string]*Sidecar
}

type FilterOpts struct {
	SkipScoring     bool
	SkipPathCheck   bool
	PackageName     string
	PrevPackagePath string

	PackagePath        string
	PackageFingerprint []string

	SelectedAsset    string
	AssetFingerprint []string
	Recheck          bool

	WantedAsset       string
	WantedPackagePath string

	NonInteractive bool
	CollectLibs    bool
}

type runtimeResolver struct{}

func (runtimeResolver) GetOS() []string {
	return config.GetOS()
}

func (runtimeResolver) GetArch() []string {
	return config.GetArch()
}

func (runtimeResolver) GetOSSpecificExtensions() []string {
	return config.GetOSSpecificExtensions()
}

var resolver platformResolver = runtimeResolver{}

func (g FilteredAsset) String() string {
	if g.DisplayName != "" {
		return g.DisplayName
	}
	return g.Name
}

func NewFilter(opts *FilterOpts) *Filter {
	return &Filter{opts: opts}
}

// assetVersionRe matches version-like number groups (e.g. "0.140.0", "86",
// "64") so they can be collapsed when comparing asset names across releases.
var assetVersionRe = regexp.MustCompile(`[0-9]+(\.[0-9]+)*`)

var assetTokenRe = regexp.MustCompile(`[^a-z0-9]+`)

// NormalizeAssetName lowercases an asset name and replaces version-like number
// groups with a placeholder, so the same asset across different releases (which
// only differ by version) compares equal.
func NormalizeAssetName(name string) string {
	return assetVersionRe.ReplaceAllString(strings.ToLower(name), "#")
}

// Fingerprint returns the sorted, version-normalized names of the given assets.
// It's used to detect when a release's set of installable files has changed
// (files added/removed/renamed) versus a pure version bump.
func Fingerprint(as []*Asset) []string {
	out := make([]string, 0, len(as))
	for _, a := range as {
		out = append(out, NormalizeAssetName(a.Name))
	}
	sort.Strings(out)
	return out
}

func stringSlicesEqual(a, b []string) bool {
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

// installableSuffixes are archive/compression formats bin can unpack.
var installableSuffixes = []string{
	".tar.gz", ".tgz",
	".tar.xz", ".txz",
	".tar.bz2", ".tbz2", ".tbz",
	".tar.zst", ".tzst",
	".tar", ".zip", ".gz", ".xz", ".bz2", ".zst",
}

// ignoredExts are file extensions that are never installable binaries:
// signatures, checksums, SBOMs, packages, docs, etc.
var ignoredExts = map[string]bool{
	"sha256": true, "sha512": true, "sha1": true, "md5": true, "sum": true,
	"checksum": true, "sig": true, "sigstore": true, "asc": true, "gpg": true,
	"pem": true, "pub": true, "crt": true, "cert": true, "minisig": true,
	"sbom": true, "spdx": true, "cdx": true, "intoto": true, "jsonl": true,
	"json": true, "txt": true, "md": true, "yaml": true, "yml": true,
	"deb": true, "rpm": true, "msi": true, "pkg": true, "dmg": true,
	"apk": true, "snap": true, "flatpak": true, "whl": true,
	// libraries / object files are never the CLI binary we want.
	"a": true, "o": true, "so": true, "dll": true, "dylib": true, "lib": true,
}

var ignoredNameSuffixes = []string{
	"-update",
	"_update",
	".update",
}

var archAliasGroups = [][]string{
	{"amd64", "x86_64", "x86-64", "x64", "intel_64", "intel64"},
	{"arm64", "aarch64", "arm_64", "arm-64", "armv8"},
	{"386", "i386", "i686", "x86"},
}

// isUsableAsset reports whether an asset could be something bin can install.
// It keeps supported archives, OS-appropriate single files, and raw binaries
// (which are often extensionless and contain dots from a version, e.g.
// "tool-7.1.0-linux-amd64"), and rejects only known non-binary file types.
func isUsableAsset(name string) bool {
	n := strings.ToLower(name)
	for _, s := range ignoredNameSuffixes {
		if strings.HasSuffix(n, s) {
			return false
		}
	}

	// Supported archives are always fine.
	for _, s := range installableSuffixes {
		if strings.HasSuffix(n, s) {
			return true
		}
	}
	// OS-specific single files for the current platform (AppImage / exe).
	for _, ext := range resolver.GetOSSpecificExtensions() {
		if strings.HasSuffix(n, "."+strings.ToLower(ext)) {
			return true
		}
	}

	ext := strings.TrimPrefix(filepath.Ext(n), ".")
	switch {
	case ignoredExts[ext]:
		return false
	case ext == "exe", ext == "appimage", ext == "dmg":
		// Executables for another OS (the current-OS ones were kept above).
		return false
	}
	// Everything else — raw binaries (extensionless or with a dotted version)
	// and unknown formats — is kept; scoring decides the best match.
	return true
}

func archAliasSet(aliases []string) map[string]bool {
	out := make(map[string]bool, len(aliases))
	for _, a := range aliases {
		out[strings.ToLower(a)] = true
	}
	return out
}

func currentArchGroup() []string {
	current := archAliasSet(resolver.GetArch())
	for _, group := range archAliasGroups {
		for _, alias := range group {
			if current[strings.ToLower(alias)] {
				return group
			}
		}
	}
	return resolver.GetArch()
}

func containsArchAlias(name string, aliases []string) bool {
	n := strings.ToLower(name)
	for _, alias := range aliases {
		if strings.Contains(n, strings.ToLower(alias)) {
			return true
		}
	}
	return false
}

func hasNativeArch(name string) bool {
	return containsArchAlias(name, currentArchGroup())
}

func hasForeignArch(name string) bool {
	native := archAliasSet(currentArchGroup())
	for _, group := range archAliasGroups {
		isNativeGroup := false
		for _, alias := range group {
			if native[strings.ToLower(alias)] {
				isNativeGroup = true
				break
			}
		}
		if isNativeGroup {
			continue
		}
		if containsArchAlias(name, group) {
			return true
		}
	}
	return false
}

// preferNativeArch drops obvious foreign-architecture assets once at least one
// native-architecture asset is present. If a release has no native match, keep
// the original set so the user can still choose manually.
func preferNativeArch(as []*Asset) []*Asset {
	hasNative := false
	for _, a := range as {
		if hasNativeArch(a.Name) {
			hasNative = true
			break
		}
	}
	if !hasNative {
		return as
	}

	out := make([]*Asset, 0, len(as))
	for _, a := range as {
		if hasNativeArch(a.Name) || !hasForeignArch(a.Name) {
			out = append(out, a)
		}
	}
	return out
}

// preferMusl collapses assets that are identical except for their libc flavor
// (musl vs glibc/gnu): when a group contains a musl build, the glibc/gnu twins
// are dropped so only musl is offered. Assets without a musl twin are kept as
// is — this only hides redundant duplicates, it never hides real choices.
func preferMusl(as []*Asset) []*Asset {
	stem := func(name string) string {
		n := strings.ToLower(name)
		for _, t := range []string{"musl", "glibc", "gnu"} {
			n = strings.ReplaceAll(n, t, "")
		}
		return n
	}

	groups := map[string][]*Asset{}
	order := []string{}
	for _, a := range as {
		s := stem(a.Name)
		if _, ok := groups[s]; !ok {
			order = append(order, s)
		}
		groups[s] = append(groups[s], a)
	}

	out := make([]*Asset, 0, len(as))
	for _, s := range order {
		g := groups[s]
		hasMusl := false
		for _, a := range g {
			if strings.Contains(strings.ToLower(a.Name), "musl") {
				hasMusl = true
				break
			}
		}
		for _, a := range g {
			n := strings.ToLower(a.Name)
			if hasMusl && (strings.Contains(n, "gnu") || strings.Contains(n, "glibc")) {
				continue // drop the glibc/gnu twin in favor of musl
			}
			out = append(out, a)
		}
	}
	return out
}

var tarSuffixes = []string{".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz2", ".tbz", ".tar.zst", ".tzst", ".tar"}

// archiveStem returns the asset name without its archive suffix, plus whether
// it was a tar-family or a zip archive.
func archiveStem(name string) (stem string, isTar, isZip bool) {
	n := strings.ToLower(name)
	for _, s := range tarSuffixes {
		if strings.HasSuffix(n, s) {
			return n[:len(n)-len(s)], true, false
		}
	}
	if strings.HasSuffix(n, ".zip") {
		return n[:len(n)-len(".zip")], false, true
	}
	return n, false, false
}

// preferArchiveType collapses tar-vs-zip duplicates of the same asset, keeping
// the format preferred for the current OS: tar on Linux/BSD, zip on Windows.
// Assets without a tar/zip twin are left untouched.
func preferArchiveType(as []*Asset) []*Asset {
	preferTar := false
	for _, os := range resolver.GetOS() {
		switch os {
		case "linux", "freebsd", "openbsd", "netbsd", "dragonfly":
			preferTar = true
		}
	}

	type group struct{ tar, zip, other []*Asset }
	groups := map[string]*group{}
	order := []string{}
	for _, a := range as {
		stem, isTar, isZip := archiveStem(a.Name)
		g := groups[stem]
		if g == nil {
			g = &group{}
			groups[stem] = g
			order = append(order, stem)
		}
		switch {
		case isTar:
			g.tar = append(g.tar, a)
		case isZip:
			g.zip = append(g.zip, a)
		default:
			g.other = append(g.other, a)
		}
	}

	out := make([]*Asset, 0, len(as))
	for _, stem := range order {
		g := groups[stem]
		if len(g.tar) > 0 && len(g.zip) > 0 {
			if preferTar {
				out = append(out, g.tar...)
			} else {
				out = append(out, g.zip...)
			}
		} else {
			out = append(out, g.tar...)
			out = append(out, g.zip...)
		}
		out = append(out, g.other...)
	}
	return out
}

// Preview runs the release-asset selection pipeline over the given asset names
// without downloading anything. It returns the auto-selected asset (chosen) or,
// when the choice is ambiguous, the candidates the user would be prompted with.
// Intended for diagnostics/testing.
func Preview(repoName string, names []string) (chosen string, options []string) {
	as := make([]*Asset, 0, len(names))
	for _, n := range names {
		as = append(as, &Asset{Name: n})
	}
	usable := filterUsableAssets(as)
	if len(usable) == 0 {
		usable = as
	}
	usable = preferArchiveType(usable)
	usable = preferMusl(usable)
	usable = preferNativeArch(usable)

	f := &Filter{opts: &FilterOpts{}}
	matches := f.scoredMatches(repoName, usable)
	if len(matches) == 1 {
		return matches[0].Name, nil
	}
	for _, m := range matches {
		options = append(options, m.Name)
	}
	return "", options
}

func filterUsableAssets(as []*Asset) []*Asset {
	out := make([]*Asset, 0, len(as))
	for _, a := range as {
		if isUsableAsset(a.Name) {
			out = append(out, a)
		} else {
			log.Debugf("Ignoring asset %q (not an installable archive/binary)", a.Name)
		}
	}
	return out
}

// SelectReleaseAsset chooses which release asset to download. It drops files
// bin can't install, then—unless re-checking or the installable asset layout
// changed since last time—reuses the previously selected asset so the user
// isn't prompted on every update. The returned asset carries the current
// Fingerprint so callers can persist it.
func (f *Filter) SelectReleaseAsset(repoName string, as []*Asset) (*FilteredAsset, error) {
	usable := filterUsableAssets(as)
	if len(usable) == 0 {
		// Nothing recognizable; fall back to the full list so the user can
		// still pick something manually rather than hard-failing.
		log.Debugf("No installable assets after filtering; falling back to full list")
		usable = as
	}
	usable = preferArchiveType(usable)
	usable = preferMusl(usable)
	usable = preferNativeArch(usable)

	fp := Fingerprint(usable)

	// --all shows everything (including filtered-out files) and always prompts.
	selectFrom := usable
	if f.opts.SkipScoring {
		selectFrom = as
	}

	if !f.opts.SkipScoring && f.opts.WantedAsset != "" {
		want := NormalizeAssetName(f.opts.WantedAsset)
		for _, a := range usable {
			if a.Name == f.opts.WantedAsset || NormalizeAssetName(a.Name) == want {
				log.Debugf("Using requested asset %q", a.Name)
				return &FilteredAsset{RepoName: repoName, Name: a.Name, DisplayName: a.DisplayName, URL: a.URL, Fingerprint: fp}, nil
			}
		}
		return nil, fmt.Errorf("requested asset %q not found in compatible release assets", f.opts.WantedAsset)
	}

	if !f.opts.Recheck && !f.opts.SkipScoring && f.opts.SelectedAsset != "" {
		if stringSlicesEqual(fp, f.opts.AssetFingerprint) {
			for _, a := range usable {
				if NormalizeAssetName(a.Name) == f.opts.SelectedAsset {
					log.Debugf("Reusing remembered asset %q (release layout unchanged)", a.Name)
					return &FilteredAsset{RepoName: repoName, Name: a.Name, DisplayName: a.DisplayName, URL: a.URL, Fingerprint: fp}, nil
				}
			}
			log.Debugf("Remembered asset %q no longer present; re-prompting", f.opts.SelectedAsset)
		} else {
			log.Infof("Release assets changed since last update; please re-select")
		}
	}

	gf, err := f.FilterAssets(repoName, selectFrom)
	if err != nil {
		return nil, err
	}
	gf.Fingerprint = fp
	return gf, nil
}

// scoredMatches scores the candidates by OS/arch/repo and returns the
// highest-scoring subset (the set a user would be prompted with). With a single
// candidate or SkipScoring it returns everything unscored.
func (f *Filter) scoredMatches(repoName string, as []*Asset) []*FilteredAsset {
	matches := []*FilteredAsset{}
	if len(as) == 1 {
		a := as[0]
		return []*FilteredAsset{{RepoName: repoName, Name: a.Name, DisplayName: a.DisplayName, URL: a.URL, score: 0}}
	}
	if f.opts.SkipScoring {
		log.Debugf("--all flag was supplied, skipping scoring")
		for _, a := range as {
			matches = append(matches, &FilteredAsset{RepoName: repoName, Name: a.Name, DisplayName: a.DisplayName, URL: a.URL, score: 0})
		}
		return matches
	}

	scores := map[string]int{}
	scoreKeys := []string{}
	if repoName != "" {
		scores[repoName] = 1
	}
	for _, os := range resolver.GetOS() {
		scores[os] = 10
	}
	for _, arch := range resolver.GetArch() {
		scores[arch] = 5
	}
	for key := range scores {
		scoreKeys = append(scoreKeys, strings.ToLower(key))
	}

	for _, a := range as {
		gf := &FilteredAsset{RepoName: repoName, Name: a.Name, DisplayName: a.DisplayName, URL: a.URL, score: 0}
		candidate := a.Name
		candidateScore := 0
		if bstrings.ContainsAny(strings.ToLower(candidate), scoreKeys) && isSupportedExt(candidate) {
			for toMatch, score := range scores {
				if strings.Contains(strings.ToLower(candidate), strings.ToLower(toMatch)) {
					log.Debugf("Candidate %s contains %s. Adding score %d", candidate, toMatch, score)
					candidateScore += score
				}
			}
			// The learned model deliberately stays out of this score: it decides
			// only which of several *equally* scored candidates wins, in
			// FilterAssets. Folding it in here would make exact ties impossible
			// and so suppress the prompt it learns from.
			gf.score = candidateScore
		}
		if gf.score > 0 {
			matches = append(matches, gf)
		}
	}

	highest := 0
	for _, m := range matches {
		if m.score > highest {
			highest = m.score
		}
	}
	for i := len(matches) - 1; i >= 0; i-- {
		if matches[i].score < highest {
			matches = append(matches[:i], matches[i+1:]...)
		}
	}
	matches = preferPackageName(matches, f.opts.PackageName)

	// AppImage is a GUI-app fallback; if a regular binary/archive scored just
	// as high, drop the AppImage(s) so the CLI build is preferred. AppImage-only
	// releases keep their AppImage (nothing else to fall back to).
	isAppImage := func(n string) bool { return strings.HasSuffix(strings.ToLower(n), ".appimage") }
	hasOther := false
	for _, m := range matches {
		if !isAppImage(m.Name) {
			hasOther = true
			break
		}
	}
	if hasOther {
		kept := make([]*FilteredAsset, 0, len(matches))
		for _, m := range matches {
			if !isAppImage(m.Name) {
				kept = append(kept, m)
			}
		}
		matches = kept
	}
	return matches
}

func preferPackageName(matches []*FilteredAsset, packageName string) []*FilteredAsset {
	best := 0
	for _, m := range matches {
		if rank := packageNameRank(m.Name, packageName); rank > best {
			best = rank
		}
	}
	if best == 0 {
		return matches
	}

	out := make([]*FilteredAsset, 0, len(matches))
	for _, m := range matches {
		if packageNameRank(m.Name, packageName) == best {
			out = append(out, m)
		}
	}
	return out
}

func packageNameRank(assetName, packageName string) int {
	nameTokens := assetTokens(assetName)
	packageTokens := assetTokens(packageName)
	if len(packageTokens) == 0 || len(nameTokens) < len(packageTokens) {
		return 0
	}

	for i := 0; i <= len(nameTokens)-len(packageTokens); i++ {
		if !tokensEqual(nameTokens[i:i+len(packageTokens)], packageTokens) {
			continue
		}
		if i == 0 {
			if len(nameTokens) == len(packageTokens) || isPlatformOrVersionToken(nameTokens[len(packageTokens)]) {
				return 3
			}
			return 2
		}
		return 1
	}
	return 0
}

func assetTokens(name string) []string {
	n := strings.ToLower(name)
	if stem, isTar, isZip := archiveStem(n); isTar || isZip {
		n = stem
	} else {
		for _, s := range []string{".appimage", ".exe"} {
			n = strings.TrimSuffix(n, s)
		}
	}

	raw := assetTokenRe.Split(n, -1)
	out := make([]string, 0, len(raw))
	for _, token := range raw {
		if token != "" {
			out = append(out, token)
		}
	}
	return out
}

func tokensEqual(a, b []string) bool {
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

func isPlatformOrVersionToken(token string) bool {
	if token == "" {
		return false
	}
	if assetVersionRe.MatchString(token) {
		return true
	}
	switch token {
	case "linux", "windows", "win",
		"freebsd", "openbsd", "netbsd", "dragonfly",
		"unknown", "musl", "gnu", "glibc", "static",
		"amd64", "x86", "x64", "intel", "arm64", "aarch64", "arm",
		"386", "i386", "i686":
		return true
	default:
		return false
	}
}

// FilterAssets selects the proper asset, prompting the user when it can't
// determine a single best match.
func (f *Filter) FilterAssets(repoName string, as []*Asset) (*FilteredAsset, error) {
	matches := f.scoredMatches(repoName, as)

	var gf *FilteredAsset
	if len(matches) == 0 {
		return nil, fmt.Errorf("Could not find any compatible files")
	} else if len(matches) > 1 {
		generic := make([]fmt.Stringer, 0)
		for _, f := range matches {
			generic = append(generic, f)
		}

		sort.SliceStable(generic, func(i, j int) bool {
			return generic[i].String() < generic[j].String()
		})

		// A model trained on enough past selections can resolve the tie itself.
		// This runs before the NonInteractive bail-out on purpose: it lets the
		// TUI get through an ambiguous release it would otherwise have to fail.
		if chosen := aiPick(repoName, matches); chosen != nil {
			log.Infof("Selected %s from %d equally-scored assets %s; run `bin update -r %s` to change it",
				chosen.Name, len(matches), aiBasis(), repoName)
			return chosen, nil
		}

		if f.opts.NonInteractive {
			return nil, fmt.Errorf("multiple matching assets and running non-interactively; run `bin update -r %s` to choose", repoName)
		}

		choice, err := options.Select("Multiple matches found, please select one:", generic)
		if err != nil {
			return nil, err
		}
		gf = choice.(*FilteredAsset)
		aiLearn(repoName, gf, matches)
		// TODO make user select the proper file
	} else {
		gf = matches[0]
	}

	return gf, nil
}

// SanitizeName removes irrelevant information from the
// file name in case it exists
func SanitizeName(name, version string) string {
	name = strings.ToLower(name)
	replacements := []string{}

	// TODO maybe instead of doing this put everything in a map (set) and then
	// generate the replacements? IDK.
	firstPass := true
	for _, osName := range resolver.GetOS() {
		for _, archName := range resolver.GetArch() {
			replacements = append(replacements, "_"+osName+archName, "")
			replacements = append(replacements, "-"+osName+archName, "")
			replacements = append(replacements, "."+osName+archName, "")

			if firstPass {
				replacements = append(replacements, "_"+archName, "")
				replacements = append(replacements, "-"+archName, "")
				replacements = append(replacements, "."+archName, "")
			}
		}

		replacements = append(replacements, "_"+osName, "")
		replacements = append(replacements, "-"+osName, "")
		replacements = append(replacements, "."+osName, "")

		firstPass = false

	}

	replacements = append(replacements, "_"+version, "")
	replacements = append(replacements, "_"+strings.TrimPrefix(version, "v"), "")
	replacements = append(replacements, "-"+version, "")
	replacements = append(replacements, "-"+strings.TrimPrefix(version, "v"), "")
	r := strings.NewReplacer(replacements...)
	return r.Replace(name)
}

// ProcessURL processes a FilteredAsset by uncompressing/unarchiving the URL of the asset.
func (f *Filter) ProcessURL(gf *FilteredAsset) (*finalFile, error) {
	f.repoName = gf.RepoName
	f.name = gf.Name
	// We're not closing the body here since the caller is in charge of that
	req, err := http.NewRequest(http.MethodGet, gf.URL, nil)
	if err != nil {
		return nil, err
	}
	for name, value := range gf.ExtraHeaders {
		req.Header.Add(name, value)
	}
	log.Debugf("Checking binary from %s", gf.URL)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}

	if res.StatusCode > 299 || res.StatusCode < 200 {
		return nil, fmt.Errorf("%d response when checking binary from %s", res.StatusCode, gf.URL)
	}

	// We're caching the whole file into memory so we can prompt
	// the user which file they want to download

	var reader io.Reader = res.Body
	if !Quiet {
		pr := ui.NewProgressReader(res.Body, res.ContentLength, gf.String())
		defer pr.Finish()
		reader = pr
	}
	buf := new(bytes.Buffer)
	_, err = io.Copy(buf, reader)
	if err != nil {
		return nil, err
	}
	return f.processReader(buf)
}

func (f *Filter) processReader(r io.Reader) (*finalFile, error) {
	var buf bytes.Buffer
	tee := io.TeeReader(r, &buf)

	t, err := filetype.MatchReader(tee)
	if err != nil {
		return nil, err
	}

	outputFile := io.MultiReader(&buf, r)

	type processorFunc func(repoName string, r io.Reader) (*finalFile, error)
	var processor processorFunc
	switch t {
	case matchers.TypeGz:
		processor = f.processGz
	case matchers.TypeTar:
		processor = f.processTar
	case matchers.TypeXz:
		processor = f.processXz
	case matchers.TypeBz2:
		processor = f.processBz2
	case matchers.TypeZstd:
		processor = f.processZst
	case matchers.TypeZip:
		processor = f.processZip
	}

	if processor != nil {
		// log.Debugf("Processing %s file %s with %s", repoName, name, runtime.FuncForPC(reflect.ValueOf(processor).Pointer()).Name())
		outFile, err := processor(f.repoName, outputFile)
		if err != nil {
			return nil, err
		}

		outputFile = outFile.Source

		f.name = outFile.Name
		f.packagePath = outFile.PackagePath
		if len(outFile.PackageFingerprint) > 0 {
			f.packageFingerprint = outFile.PackageFingerprint
		}
		if len(outFile.Sidecars) > 0 {
			f.sidecars = outFile.Sidecars
		}

		// In case of e.g. a .tar.gz, process the uncompressed archive by calling recursively
		return f.processReader(outputFile)
	}

	return &finalFile{Source: outputFile, Name: f.name, PackagePath: f.packagePath, PackageFingerprint: f.packageFingerprint, Sidecars: f.sidecars}, err
}

// processGz receives a tar.gz file and returns the
// correct file for bin to download
func (f *Filter) processGz(name string, r io.Reader) (*finalFile, error) {
	gr, err := gzip.NewReader(r)
	if err != nil {
		return nil, err
	}

	return &finalFile{Source: gr, Name: gr.Name}, nil
}

func (f *Filter) processTar(name string, r io.Reader) (*finalFile, error) {
	tr := tar.NewReader(r)
	tarFiles := map[string][]byte{}
	tarLinks := map[string]string{} // symlink path -> link target
	if len(f.opts.PackagePath) > 0 {
		log.Debugf("Processing tag with PackagePath %s\n", f.opts.PackagePath)
	}
	for {
		header, err := tr.Next()
		if err == io.EOF {
			break
		} else if err != nil {
			return nil, err
		} else if header.FileInfo().IsDir() {
			continue
		}

		switch header.Typeflag {
		case tar.TypeReg:
			bs, err := io.ReadAll(tr)
			if err != nil {
				return nil, err
			}
			tarFiles[header.Name] = bs
		case tar.TypeSymlink, tar.TypeLink:
			tarLinks[header.Name] = header.Linkname
		}
	}
	if len(tarFiles) == 0 {
		return nil, fmt.Errorf("no files found in tar archive")
	}

	selectedFile, err := f.pickArchiveFile(name, tarFiles)
	if err != nil {
		return nil, err
	}

	out := &finalFile{Source: bytes.NewReader(tarFiles[selectedFile]), Name: filepath.Base(selectedFile), PackagePath: selectedFile, PackageFingerprint: f.packageFingerprint}
	if f.opts.CollectLibs {
		out.Sidecars = collectLibClosure(tarFiles[selectedFile], tarFiles, tarLinks)
	}
	return out, nil
}

// collectLibClosure resolves the shared-library dependency closure of binary
// (its DT_NEEDED, transitively) against the shared libraries present in the same
// archive, following symlinks. System libraries not shipped in the archive are
// skipped. Returns sidecars keyed by basename (regular files and symlinks).
func collectLibClosure(binary []byte, files map[string][]byte, links map[string]string) map[string]*Sidecar {
	// index archive entries by basename
	fileByBase := map[string][]byte{}
	for p, data := range files {
		if isSharedLib(p) {
			fileByBase[filepath.Base(p)] = data
		}
	}
	linkByBase := map[string]string{}
	for p, target := range links {
		if isSharedLib(p) {
			linkByBase[filepath.Base(p)] = filepath.Base(target)
		}
	}

	needed := func(data []byte) []string {
		ef, err := elf.NewFile(bytes.NewReader(data))
		if err != nil {
			return nil
		}
		defer ef.Close()
		libs, _ := ef.ImportedLibraries()
		return libs
	}

	out := map[string]*Sidecar{}
	seen := map[string]bool{}
	var queue []string
	queue = append(queue, needed(binary)...)

	for len(queue) > 0 {
		base := queue[0]
		queue = queue[1:]
		if base == "" || seen[base] {
			continue
		}
		seen[base] = true

		if target, ok := linkByBase[base]; ok {
			out[base] = &Sidecar{Link: target}
			queue = append(queue, target) // resolve the link target too
			continue
		}
		if data, ok := fileByBase[base]; ok {
			out[base] = &Sidecar{Data: data}
			queue = append(queue, needed(data)...)
		}
		// otherwise it's a system lib (not in the archive); skip.
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// isSharedLib reports whether a path looks like a shared object (.so / .so.N…).
func isSharedLib(p string) bool {
	b := filepath.Base(p)
	return strings.HasSuffix(b, ".so") || strings.Contains(b, ".so.")
}

func (f *Filter) processBz2(name string, r io.Reader) (*finalFile, error) {
	br := bzip2.NewReader(r)

	return &finalFile{Source: br, Name: name}, nil
}

func (f *Filter) processZst(name string, r io.Reader) (*finalFile, error) {
	zr, err := zstd.NewReader(r)
	if err != nil {
		return nil, err
	}
	return &finalFile{Source: zr.IOReadCloser(), Name: name}, nil
}

func (f *Filter) processXz(name string, r io.Reader) (*finalFile, error) {
	xr, err := xz.NewReader(r, 0)
	if err != nil {
		return nil, err
	}

	return &finalFile{Source: xr, Name: name}, nil
}

func (f *Filter) processZip(name string, r io.Reader) (*finalFile, error) {
	zr := zipstream.NewReader(r)

	zipFiles := map[string][]byte{}
	if len(f.opts.PackagePath) > 0 {
		log.Debugf("Processing tag with PackagePath %s\n", f.opts.PackagePath)
	}
	for {
		header, err := zr.Next()
		if err == io.EOF {
			break
		} else if err != nil {
			return nil, err
		} else if header.Mode().IsDir() {
			continue
		}

		bs, err := io.ReadAll(zr)
		if err != nil {
			return nil, err
		}
		zipFiles[header.Name] = bs
	}
	if len(zipFiles) == 0 {
		return nil, fmt.Errorf("no files found in zip archive")
	}

	selectedFile, err := f.pickArchiveFile(name, zipFiles)
	if err != nil {
		return nil, err
	}
	// return base of selected file since archives usually have folders inside
	return &finalFile{Name: filepath.Base(selectedFile), Source: bytes.NewReader(zipFiles[selectedFile]), PackagePath: selectedFile, PackageFingerprint: f.packageFingerprint}, nil
}

// pickArchiveFile decides which file inside an archive to extract, mirroring
// the release-asset logic one level down:
//  1. keep only installable files (binaries or nested archives),
//  2. if the remembered package fingerprint is unchanged (only versions
//     differ), reuse the same file with the new version in its name — no prompt,
//  3. if the set of files changed (e.g. a new musl build appears) re-prompt,
//  4. a single installable file always auto-selects.
//
// It records the current fingerprint on the Filter so it can be persisted.
func (f *Filter) pickArchiveFile(name string, files map[string][]byte) (string, error) {
	usable := preferNativeArch(installableCandidates(files))
	fp := Fingerprint(usable)
	f.packageFingerprint = fp

	if f.opts.WantedPackagePath != "" {
		want := NormalizeAssetName(f.opts.WantedPackagePath)
		for _, a := range usable {
			if a.Name == f.opts.WantedPackagePath || NormalizeAssetName(a.Name) == want {
				log.Debugf("Using requested package path %q", a.Name)
				return a.Name, nil
			}
		}
		return "", fmt.Errorf("requested package path %q not found in archive", f.opts.WantedPackagePath)
	}

	if !f.opts.Recheck && !f.opts.SkipPathCheck && f.opts.PackagePath != "" {
		want := NormalizeAssetName(f.opts.PackagePath)
		if stringSlicesEqual(fp, f.opts.PackageFingerprint) {
			for _, a := range usable {
				if NormalizeAssetName(a.Name) == want {
					log.Debugf("Reusing remembered package %q as %q (layout unchanged)", f.opts.PackagePath, a.Name)
					return a.Name, nil
				}
			}
			log.Debugf("Remembered package %q not found; re-selecting", f.opts.PackagePath)
		} else {
			log.Infof("Archive contents changed since last update; please re-select")
		}
	}

	choice, err := f.FilterAssets(name, usable)
	if err != nil {
		return "", err
	}
	return choice.String(), nil
}

// isBinaryFile reports whether data is an executable binary by actually
// parsing it as one of the supported object formats (ELF or PE). This
// introspects the real headers rather than sniffing magic bytes, so
// docs/scripts/configs are reliably excluded.
func isBinaryFile(data []byte) bool {
	r := bytes.NewReader(data)
	if f, err := elf.NewFile(r); err == nil {
		f.Close()
		return true
	}
	if f, err := pe.NewFile(r); err == nil {
		f.Close()
		return true
	}
	return false
}

// isCompressedFile reports whether data is a supported archive/compression
// wrapper (so nested archives inside an archive stay selectable).
func isCompressedFile(data []byte) bool {
	switch t, _ := filetype.Match(data); t {
	case matchers.TypeGz, matchers.TypeTar, matchers.TypeXz, matchers.TypeBz2, matchers.TypeZip:
		return true
	}
	return false
}

// installableCandidates returns only the files bin can install from an archive
// — executable binaries or nested archives. If none qualify, it falls back to
// all files so the user can still pick manually.
func installableCandidates(files map[string][]byte) []*Asset {
	keep := make([]*Asset, 0)
	all := make([]*Asset, 0, len(files))
	for name, data := range files {
		all = append(all, &Asset{Name: name})
		if isBinaryFile(data) || isCompressedFile(data) {
			keep = append(keep, &Asset{Name: name})
		}
	}
	if len(keep) > 0 {
		return keep
	}
	return all
}

// isSupportedExt checks if this provider supports
// dealing with this specific file extension
func isSupportedExt(filename string) bool {
	if ext := strings.TrimPrefix(filepath.Ext(filename), "."); len(ext) > 0 {
		switch filetype.GetType(ext) {
		case msiType, matchers.TypeDeb, matchers.TypeRpm, ascType:
			log.Debugf("Filename %s doesn't have a supported extension", filename)
			return false
		case matchers.TypeGz, types.Unknown, matchers.TypeZip, matchers.TypeXz, matchers.TypeTar, matchers.TypeBz2, matchers.TypeZstd, matchers.TypeExe:
			break
		default:
			log.Debugf("Filename %s doesn't have a supported extension", filename)
			return false
		}
	}

	return true
}
