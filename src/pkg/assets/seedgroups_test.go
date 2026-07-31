package assets

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// This file is the first half of the seed-model generator. It turns a corpus of
// real release-asset names into labelled tie groups:
//
//	seed/corpus.json  --(this file)-->  seed/groups.json  --(ai/seedgen_test.go)-->  seed/model.json
//
// It lives in package assets because it must use the real scorer to find real
// ties — reimplementing that logic would let the training data drift away from
// what bin actually asks about. Regenerate with:
//
//	BIN_GENERATE_SEED=1 go test ./src/pkg/assets -run TestGenerateSeedGroups
//
// The labels come from the rule set in oracleScore below, not from user
// selections, so seed/groups.json is committed to make every label reviewable.

const (
	corpusPath = "../ai/seed/corpus.json"
	groupsPath = "../ai/seed/groups.json"
)

type seedCorpusRepo struct {
	Owner  string   `json:"owner"`
	Repo   string   `json:"repo"`
	Assets []string `json:"assets"`
}

// seedGroup is one labelled tie group. Chosen is empty when the group's
// remaining candidates are a genuine toss-up; Rejected is still meaningful.
type seedGroup struct {
	Repo     string   `json:"repo"`
	Platform string   `json:"platform"`
	Chosen   string   `json:"chosen,omitempty"`
	Rejected []string `json:"rejected"`
	Note     string   `json:"note,omitempty"`
}

// seedPlatforms mirrors config.GetOS/GetArch exactly, for every platform bin
// ships. Using a made-up alias list here would manufacture ties that bin never
// actually sees.
var seedPlatforms = []struct {
	name string
	res  *mockOSResolver
}{
	{"linux/amd64", &mockOSResolver{OS: []string{"linux"}, Arch: []string{"amd64", "x86_64", "x64", "x86-64", "intel_64", "intel64"}, OSSpecificExtensions: []string{"AppImage"}}},
	{"linux/arm64", &mockOSResolver{OS: []string{"linux"}, Arch: []string{"arm64", "aarch64", "arm_64", "arm-64", "armv8"}, OSSpecificExtensions: []string{"AppImage"}}},
	{"windows/amd64", &mockOSResolver{OS: []string{"windows", "win"}, Arch: []string{"amd64", "x86_64", "x64", "x86-64", "intel_64", "intel64"}, OSSpecificExtensions: []string{"exe"}}},
}

func TestGenerateSeedGroups(t *testing.T) {
	if os.Getenv("BIN_GENERATE_SEED") == "" {
		t.Skip("set BIN_GENERATE_SEED=1 to regenerate " + groupsPath)
	}

	corpus := loadSeedCorpus(t)
	prev := resolver
	t.Cleanup(func() { resolver = prev })

	var (
		groups       []seedGroup
		unambiguous  int
		mixedTarget  int
		noWinner     int
		mixedSamples []string
	)

	for _, p := range seedPlatforms {
		resolver = p.res
		f := NewFilter(&FilterOpts{})

		for _, r := range corpus {
			as := make([]*Asset, 0, len(r.Assets))
			for _, n := range r.Assets {
				as = append(as, &Asset{Name: n, URL: "https://example/" + n})
			}
			matches := f.scoredMatches(r.Repo, filterUsableAssets(as))
			if len(matches) < 2 {
				unambiguous++
				continue
			}

			names := make([]string, 0, len(matches))
			for _, m := range matches {
				names = append(names, m.Name)
			}
			sort.Strings(names)

			// Groups whose candidates target different platforms are ambiguous for
			// a reason the model cannot see: it has no OS or arch feature, because
			// those are equal in a legitimate tie. Training on them would label
			// identical feature vectors 1 in one group and 0 in another.
			if !sameTarget(names) {
				mixedTarget++
				if len(mixedSamples) < 12 {
					mixedSamples = append(mixedSamples, fmt.Sprintf("[%s] %s: %v", p.name, r.Repo, names))
				}
				continue
			}

			g := labelGroup(r.Repo, p.name, names)
			switch {
			case g == nil:
				noWinner++
			default:
				groups = append(groups, *g)
			}
		}
	}

	sort.Slice(groups, func(i, j int) bool {
		if groups[i].Repo != groups[j].Repo {
			return groups[i].Repo < groups[j].Repo
		}
		return groups[i].Platform < groups[j].Platform
	})

	if err := writeJSON(groupsPath, groups); err != nil {
		t.Fatal(err)
	}

	labelled, negOnly := 0, 0
	for _, g := range groups {
		if g.Chosen == "" {
			negOnly++
		} else {
			labelled++
		}
	}
	t.Logf("%d repos x %d platforms", len(corpus), len(seedPlatforms))
	t.Logf("  %d unambiguous (no tie, nothing to learn)", unambiguous)
	t.Logf("  %d groups with a labelled winner", labelled)
	t.Logf("  %d groups labelled negatives-only (no single winner)", negOnly)
	t.Logf("  %d dropped: candidates target different platforms (scorer limitation)", mixedTarget)
	t.Logf("  %d dropped: every candidate scored the same", noWinner)
	for _, s := range mixedSamples {
		t.Logf("    mixed-target sample: %s", s)
	}
	t.Logf("wrote %s (%d groups)", groupsPath, len(groups))
}

// labelGroup applies the rules to one tie group. It returns nil when no single
// candidate comes out on top, and a group with an empty Chosen when the winners
// differ only by libc — a real toss-up we refuse to invent an answer for.
func labelGroup(repo, platform string, names []string) *seedGroup {
	best := -1 << 30
	scores := make(map[string]int, len(names))
	for _, n := range names {
		s := oracleScore(n, repo)
		scores[n] = s
		if s > best {
			best = s
		}
	}

	winners, losers := []string{}, []string{}
	for _, n := range names {
		if scores[n] == best {
			winners = append(winners, n)
		} else {
			losers = append(losers, n)
		}
	}

	switch {
	case len(winners) == 1:
		return &seedGroup{Repo: repo, Platform: platform, Chosen: winners[0], Rejected: losers}
	case len(losers) == 0:
		// Every candidate scored the same; there is nothing to learn either way.
		return nil
	default:
		// Several candidates tied at the top. We know the losers are wrong but not
		// which winner is right, so record the negatives only rather than invent a
		// preference between the leaders.
		return &seedGroup{
			Repo:     repo,
			Platform: platform,
			Rejected: losers,
			Note:     "no single winner; tied leaders: " + strings.Join(winners, " "),
		}
	}
}

// oracleScore ranks one candidate. This is the whole labelling policy, and the
// only place a preference is asserted. Higher wins.
func oracleScore(name, repo string) int {
	lower := strings.ToLower(name)
	score := 0

	// The project's own binary beats the things shipped beside it. This is the
	// most common real ambiguity in the corpus by a wide margin.
	switch rank := repoRank(lower, repo); {
	case rank == 2:
		score += 100
	case rank == 1:
		score += 40
	}

	// Debug symbols, profiling builds, GPU-specific builds, packaging
	// by-products: never what someone means by "install this tool".
	if hasAnyToken(lower, "debug", "dbg", "symbols", "syms", "profile",
		"src", "source", "sources", "vendor", "sbom", "package", "npm",
		"installer", "setup", "gui", "desktop", "app", "ui",
		"cuda", "rocm", "vulkan", "mlx", "jetpack", "jetpack5", "jetpack6", "fips") {
		score -= 120
	}
	// A build for a different platform that still scored equally.
	if hasAnyToken(lower, "android", "ios") {
		score -= 150
	}
	// Reduced-compatibility or reduced-feature builds.
	if hasAnyToken(lower, "baseline", "slim", "nolibgit", "libgit") {
		score -= 30
	}
	// The explicitly-named default build (spotifyd ships default/full/slim).
	if hasAnyToken(lower, "default") {
		score += 20
	}

	// Portability preference: a musl build is static and has no glibc version
	// coupling, so it is the more likely of the two to simply run.
	if strings.Contains(lower, "musl") {
		score += 15
	}
	if hasAnyToken(lower, "static") {
		score += 10
	}

	// Container format: the ubiquitous ones over the exotic ones.
	switch {
	case hasAnySuffix(lower, ".tar.gz", ".tgz", ".tar"):
		score += 12
	case hasAnySuffix(lower, ".zip"):
		score += 6
	case hasAnySuffix(lower, ".tar.bz2", ".tbz2", ".tbz", ".bz2",
		".tar.xz", ".txz", ".xz", ".tar.zst", ".tzst", ".zst", ".7z"):
		score += 0
	default:
		score += 8 // a bare executable is perfectly fine
	}

	return score
}

// repoRank mirrors ai.repoNameRank, on the integer scale the oracle uses:
// 2 = the project's own artifact, 1 = a companion, 0 = neither.
func repoRank(lower, repo string) int {
	if repo == "" {
		return 0
	}
	repoParts := seedTokens(repo)
	parts := seedTokens(lower)
	if len(repoParts) == 0 || len(parts) <= len(repoParts) {
		return 0
	}
	if equalTokens(parts[:len(repoParts)], repoParts) && seedPlatformToken(parts[len(repoParts)]) {
		return 2
	}
	if strings.Contains(lower, strings.ToLower(repo)) {
		return 1
	}
	return 0
}

// sameTarget reports whether every name in a group names the same OS and the
// same architecture (or names none at all).
func sameTarget(names []string) bool {
	var os, arch string
	for i, n := range names {
		o, a := targetOf(n)
		if i == 0 {
			os, arch = o, a
			continue
		}
		if o != os || a != arch {
			return false
		}
	}
	return true
}

// seedOSPatterns and seedArchPatterns are matched as substrings, in order, so
// the first match wins. Order is load-bearing:
//
//   - "linux-android" is android, not linux;
//   - "x86_64" must be tested before "x86", and "arm64" before "arm".
//
// Substrings rather than tokens because "x86_64" splits into "x86" and "64",
// and "x86" alone means the 32-bit architecture.
var (
	seedOSPatterns = []struct{ pattern, family string }{
		{"android", "android"}, {"ios", "ios"},
		// bin does not target Apple platforms, but their assets still show up in
		// release listings and must be recognised so they are never mistaken for
		// a supported target.
		{"darwin", "darwin"}, {"macosx", "darwin"}, {"macos", "darwin"},
		{"apple", "darwin"}, {"osx", "darwin"},
		{"freebsd", "freebsd"}, {"netbsd", "netbsd"}, {"openbsd", "openbsd"},
		{"dragonfly", "dragonfly"}, {"solaris", "solaris"}, {"illumos", "illumos"},
		{"linux", "linux"},
		{"windows", "windows"}, {"win32", "windows"}, {"win64", "windows"},
		{"msvc", "windows"}, {"mingw", "windows"}, {"win", "windows"},
	}
	seedArchPatterns = []struct{ pattern, family string }{
		{"x86_64", "x86_64"}, {"x86-64", "x86_64"}, {"amd64", "x86_64"},
		{"intel_64", "x86_64"}, {"intel64", "x86_64"}, {"x64", "x86_64"},
		{"aarch64", "arm64"}, {"arm64", "arm64"}, {"arm_64", "arm64"},
		{"arm-64", "arm64"}, {"armv8", "arm64"},
		{"ppc64le", "ppc64le"}, {"ppc64", "ppc64"},
		{"s390x", "s390x"}, {"riscv64", "riscv64"}, {"loong64", "loong64"},
		{"armv7", "arm"}, {"armv6", "arm"}, {"armhf", "arm"}, {"armel", "arm"},
		{"i686", "x86"}, {"i586", "x86"}, {"i386", "x86"}, {"x86", "x86"},
		{"universal2", "universal"}, {"universal", "universal"},
		{"arm", "arm"},
	}
)

// targetOf extracts the OS and architecture family a name refers to, or "" when
// the name says nothing about it. A bare "64" is deliberately not an
// architecture: it appears inside x86_64, arm_64 and intel_64 alike, and on its
// own (micromamba's "linux-64") it is genuinely unidentifiable.
func targetOf(name string) (os, arch string) {
	lower := strings.ToLower(name)
	for _, p := range seedOSPatterns {
		if strings.Contains(lower, p.pattern) {
			os = p.family
			break
		}
	}
	for _, p := range seedArchPatterns {
		if strings.Contains(lower, p.pattern) {
			arch = p.family
			break
		}
	}
	return os, arch
}

func seedTokens(s string) []string {
	return strings.FieldsFunc(strings.ToLower(s), func(r rune) bool {
		return !('a' <= r && r <= 'z' || '0' <= r && r <= '9')
	})
}

// seedPlatformToken reports whether a token marks the start of the platform
// description, i.e. the end of the project name.
func seedPlatformToken(t string) bool {
	switch t {
	case "linux", "darwin", "macos", "macosx", "osx", "mac", "apple",
		"windows", "win", "win32", "win64", "freebsd", "netbsd", "openbsd",
		"dragonfly", "solaris", "illumos", "android", "ios",
		"amd64", "x86", "x64", "i386", "i686", "i586", "arm", "arm64",
		"aarch64", "armv6", "armv7", "armv8", "armhf", "armel", "ppc64",
		"ppc64le", "s390x", "mips", "mipsle", "mips64", "mips64le", "riscv64",
		"loong64", "universal", "universal2", "intel", "intel64", "powerpc",
		"gnu", "gnueabi", "gnueabihf", "musl", "musleabi", "musleabihf",
		"msvc", "mingw", "mingw32", "mingw64", "unknown", "pc", "none", "static",
		"tar", "gz", "tgz", "zip", "bz2", "tbz", "tbz2", "xz", "txz", "zst",
		"tzst", "7z", "exe", "appimage", "deb", "rpm", "dmg", "pkg", "msi", "bin":
		return true
	}
	// A version number also ends the project name.
	for _, r := range t {
		if r < '0' || r > '9' {
			return false
		}
	}
	return t != ""
}

func hasAnyToken(name string, want ...string) bool {
	toks := seedTokens(name)
	for _, w := range want {
		for _, t := range toks {
			if t == w {
				return true
			}
		}
	}
	return false
}

func hasAnySuffix(s string, suffixes ...string) bool {
	for _, suffix := range suffixes {
		if strings.HasSuffix(s, suffix) {
			return true
		}
	}
	return false
}

func equalTokens(a, b []string) bool {
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

func loadSeedCorpus(t *testing.T) []seedCorpusRepo {
	t.Helper()
	raw, err := os.ReadFile(corpusPath)
	if err != nil {
		t.Fatalf("reading corpus: %v", err)
	}
	var corpus []seedCorpusRepo
	if err := json.Unmarshal(raw, &corpus); err != nil {
		t.Fatalf("parsing corpus: %v", err)
	}
	return corpus
}

func writeJSON(path string, v any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(v, "", " ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(data, '\n'), 0o644)
}
