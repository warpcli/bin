package assets

import (
	"archive/tar"
	"bytes"
	"fmt"
	"io"
	"strings"
	"testing"

	"github.com/klauspost/compress/zstd"
)

type mockOSResolver struct {
	OS                   []string
	Arch                 []string
	OSSpecificExtensions []string
}

func (m *mockOSResolver) GetOS() []string {
	return m.OS
}

func (m *mockOSResolver) GetArch() []string {
	return m.Arch
}

func (m *mockOSResolver) GetOSSpecificExtensions() []string {
	return m.OSSpecificExtensions
}

var (
	testLinuxAMDResolver   = &mockOSResolver{OS: []string{"linux"}, Arch: []string{"amd64", "x86_64", "x64", "64"}, OSSpecificExtensions: []string{"AppImage"}}
	testLinuxARMResolver   = &mockOSResolver{OS: []string{"linux"}, Arch: []string{"arm64", "aarch64", "arm_64", "arm-64", "armv8"}, OSSpecificExtensions: []string{"AppImage"}}
	testWindowsAMDResolver = &mockOSResolver{OS: []string{"windows", "win"}, Arch: []string{"amd64", "x86_64", "x64", "64"}, OSSpecificExtensions: []string{"exe"}}
)

func TestSanitizeName(t *testing.T) {
	cases := []struct {
		in       string
		v        string
		out      string
		resolver platformResolver
	}{
		{"bin_amd64_linux", "v0.0.1", "bin", testLinuxAMDResolver},
		{"bin_0.0.1_amd64_linux", "0.0.1", "bin", testLinuxAMDResolver},
		{"bin_0.0.1_amd64_linux", "v0.0.1", "bin", testLinuxAMDResolver},
		{"gitlab-runner-linux-amd64", "v13.2.1", "gitlab-runner", testLinuxAMDResolver},
		{"jq-linux64", "jq-1.5", "jq", testLinuxAMDResolver},
		{"launchpad-linux-x64", "1.2.0-rc.1", "launchpad", testLinuxAMDResolver},
		{"launchpad-win-x64.exe", "1.2.0-rc.1", "launchpad.exe", testWindowsAMDResolver},
		{"bin_0.0.1_Windows_x86_64.exe", "0.0.1", "bin.exe", testWindowsAMDResolver},
	}

	for _, c := range cases {
		resolver = c.resolver
		if n := SanitizeName(c.in, c.v); n != c.out {
			t.Fatalf("Error replacing %s: %s does not match %s", c.in, n, c.out)
		}
	}

}

type args struct {
	repoName string
	as       []*Asset
}

func (a args) String() string {
	assetStrings := []string{}
	for _, asset := range a.as {
		assetStrings = append(assetStrings, asset.String())
	}
	return fmt.Sprintf("%s (%v)", a.repoName, strings.Join(assetStrings, ","))
}

func TestFilterAssets(t *testing.T) {
	cases := []struct {
		in       args
		out      string
		resolver platformResolver
	}{
		{args{"bin", []*Asset{
			{Name: "bin_0.0.1_Linux_x86_64", URL: "https://github.com/bresilla/geto/releases/download/v0.0.1/bin_0.0.1_Linux_x86_64"},
			{Name: "bin_0.0.1_Linux_i386", URL: "https://github.com/bresilla/geto/releases/download/v0.0.1/bin_0.0.1_Linux_i386"},
			{Name: "bin_0.0.1_Darwin_x86_64", URL: "https://github.com/bresilla/geto/releases/download/v0.0.1/bin_0.0.1_Darwin_x86_64"},
		}}, "bin_0.0.1_Linux_x86_64", testLinuxAMDResolver},
		{args{"bin", []*Asset{
			{Name: "bin_0.1.0_Windows_i386.exe", URL: "https://github.com/bresilla/geto/releases/download/v0.0.1/bin_0.1.0_Windows_i386.exe"},
			{Name: "bin_0.1.0_Linux_x86_64", URL: "https://github.com/bresilla/geto/releases/download/v0.0.1/bin_0.1.0_Linux_x86_64"},
			{Name: "bin_0.1.0_Darwin_x86_64", URL: "https://github.com/bresilla/geto/releases/download/v0.0.1/bin_0.1.0_Darwin_x86_64"},
		}}, "bin_0.1.0_Linux_x86_64", testLinuxAMDResolver},
		{args{"bin", []*Asset{
			{Name: "bin_0.1.0_Windows_i386.exe", URL: "https://github.com/bresilla/geto/releases/download/v0.0.1/bin_0.1.0_Windows_i386.exe"},
			{Name: "bin_0.1.0_Linux_x86_64", URL: "https://github.com/bresilla/geto/releases/download/v0.0.1/bin_0.1.0_Linux_x86_64"},
			{Name: "bin_0.1.0_Darwin_x86_64", URL: "https://github.com/bresilla/geto/releases/download/v0.0.1/bin_0.1.0_Darwin_x86_64"},
		}}, "bin_0.1.0_Linux_x86_64", testLinuxAMDResolver},
		{args{"gitlab-runner", []*Asset{
			{Name: "gitlab-runner-windows-amd64", URL: "https://gitlab-runner-downloads.s3.amazonaws.com/v13.2.1/binaries/gitlab-runner-windows-amd64.zip"},
			{Name: "gitlab-runner-linux-amd64", URL: "https://gitlab-runner-downloads.s3.amazonaws.com/v13.2.1/binaries/gitlab-runner-linux-amd64"},
			{Name: "gitlab-runner-darwin-amd64", URL: "https://gitlab-runner-downloads.s3.amazonaws.com/v13.2.1/binaries/gitlab-runner-darwin-amd64"},
		}}, "gitlab-runner-linux-amd64", testLinuxAMDResolver},
		{args{"yq", []*Asset{
			{Name: "yq_freebsd_amd64", URL: "https://github.com/mikefarah/yq/releases/download/3.3.2/yq_freebsd_amd64"},
			{Name: "yq_linux_amd64", URL: "https://github.com/mikefarah/yq/releases/download/3.3.2/yq_linux_amd64"},
			{Name: "yq_windows_amd64.exe", URL: "https://github.com/mikefarah/yq/releases/download/3.3.2/yq_windows_amd64.exe"},
		}}, "yq_linux_amd64", testLinuxAMDResolver},
		{args{"jq", []*Asset{
			{Name: "jq-win64.exe", URL: "https://github.com/stedolan/jq/releases/download/jq-1.6/jq-win64.exe"},
			{Name: "jq-linux64", URL: "https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64"},
			{Name: "jq-osx-amd64", URL: "https://github.com/stedolan/jq/releases/download/jq-1.6/jq-osx-amd64"},
		}}, "jq-linux64", testLinuxAMDResolver},
		{args{"bin", []*Asset{
			{Name: "bin_0.0.1_Windows_x86_64.exe", URL: "https://github.com/bresilla/geto/releases/download/v0.0.1/bin_0.0.1_Windows_x86_64.exe"},
			{Name: "bin_0.1.0_Linux_x86_64", URL: "https://github.com/bresilla/geto/releases/download/v0.0.1/bin_0.1.0_Linux_x86_64"},
			{Name: "bin_0.1.0_Darwin_x86_64", URL: "https://github.com/bresilla/geto/releases/download/v0.0.1/bin_0.1.0_Darwin_x86_64"},
		}}, "bin_0.0.1_Windows_x86_64.exe", testWindowsAMDResolver},
		{args{"tezos", []*Asset{
			{Name: "x86_64-linux-tezos-binaries.tar.gz", URL: "https://gitlab.com/api/v4/projects/3836952/packages/generic/tezos/8.2.0/x86_64-linux-tezos-binaries.tar.gz"},
		}}, "x86_64-linux-tezos-binaries.tar.gz", testLinuxAMDResolver},
		{args{"launchpad", []*Asset{
			{Name: "launchpad-linux-x64", URL: "https://github.com/Mirantis/launchpad/releases/download/1.2.0-rc.1/launchpad-linux-x64"},
			{Name: "launchpad-win-x64.exe", URL: "https://github.com/Mirantis/launchpad/releases/download/1.2.0-rc.1/launchpad-win-x64.exe"},
		}}, "launchpad-linux-x64", testLinuxAMDResolver},
		{args{"launchpad", []*Asset{
			{Name: "launchpad-linux-x64", URL: "https://github.com/Mirantis/launchpad/releases/download/1.2.0-rc.1/launchpad-linux-x64"},
			{Name: "launchpad-win-x64.exe", URL: "https://github.com/Mirantis/launchpad/releases/download/1.2.0-rc.1/launchpad-win-x64.exe"},
		}}, "launchpad-win-x64.exe", testWindowsAMDResolver},
		{args{"usql", []*Asset{
			{Name: "usql-0.8.2-darwin-amd64.tar.bz2", URL: "https://github.com/xo/usql/releases/download/v0.8.2/usql-0.8.2-darwin-amd64.tar.bz2"},
			{Name: "usql-0.8.2-linux-amd64.tar.bz2", URL: "https://github.com/xo/usql/releases/download/v0.8.2/usql-0.8.2-linux-amd64.tar.bz2"},
			{Name: "usql-0.8.2-windows-amd64.zip", URL: "https://github.com/xo/usql/releases/download/v0.8.2/usql-0.8.2-windows-amd64.zip"},
		}}, "usql-0.8.2-linux-amd64.tar.bz2", testLinuxAMDResolver},
		{args{"usql", []*Asset{
			{Name: "usql-0.8.2-darwin-amd64.tar.bz2", URL: "https://github.com/xo/usql/releases/download/v0.8.2/usql-0.8.2-darwin-amd64.tar.bz2"},
			{Name: "usql-0.8.2-linux-amd64.tar.bz2", URL: "https://github.com/xo/usql/releases/download/v0.8.2/usql-0.8.2-linux-amd64.tar.bz2"},
			{Name: "usql-0.8.2-windows-amd64.zip", URL: "https://github.com/xo/usql/releases/download/v0.8.2/usql-0.8.2-windows-amd64.zip"},
		}}, "usql-0.8.2-windows-amd64.zip", testWindowsAMDResolver},
		{args{"cli", []*Asset{
			{Name: "dapr", URL: ""},
		}}, "dapr", testLinuxAMDResolver},
	}

	f := NewFilter(&FilterOpts{SkipScoring: false})
	for _, c := range cases {
		resolver = c.resolver
		if n, err := f.FilterAssets(c.in.repoName, c.in.as); err != nil {
			for _, a := range c.in.as {
				fmt.Println(a.Name, c.resolver)
			}
			t.Fatalf("Error filtering assets %v", err)
		} else if n.Name != c.out {
			t.Fatalf("Error filtering %+v: %+v does not match %s", c.in, n, c.out)
		}
	}

}

func TestNormalizeAssetName(t *testing.T) {
	cases := []struct{ a, b string }{
		// same asset, only the version differs => must normalize equal
		{"codex-npm-linux-x64-0.140.0.tgz", "codex-npm-linux-x64-0.141.0.tgz"},
		{"codex-x86_64-unknown-linux-musl.tar.gz", "codex-x86_64-unknown-linux-musl.tar.gz"},
		{"tool-v1.2.3-linux", "tool-v9.0.0-linux"},
	}
	for _, c := range cases {
		if NormalizeAssetName(c.a) != NormalizeAssetName(c.b) {
			t.Fatalf("expected %q and %q to normalize equal, got %q vs %q", c.a, c.b, NormalizeAssetName(c.a), NormalizeAssetName(c.b))
		}
	}
	// different assets must NOT normalize equal
	if NormalizeAssetName("codex-x86_64-unknown-linux-musl.tar.gz") == NormalizeAssetName("codex-zsh-x86_64-unknown-linux-musl.tar.gz") {
		t.Fatal("distinct assets normalized to the same value")
	}
}

func TestIsUsableAsset(t *testing.T) {
	resolver = testLinuxAMDResolver
	keep := []string{
		"codex-x86_64-unknown-linux-musl.tar.gz",
		"codex-npm-linux-x64-0.140.0.tgz",
		"jq-linux64",                    // extensionless
		"tool-v0.140.0",                 // version-number "extension"
		"Ultimaker_Cura-4.8.0.AppImage", // OS-specific
	}
	drop := []string{
		"codex-x86_64-unknown-linux-musl.sigstore",
		"openai_codex_cli_bin-0.140.0-py3-none-manylinux_2_17_x86_64.whl",
		"checksums.txt",
		"codex.tar.gz.sha256",
		"release.sbom.json",
		"pkg.deb",
	}
	for _, n := range keep {
		if !isUsableAsset(n) {
			t.Fatalf("expected %q to be usable", n)
		}
	}
	for _, n := range drop {
		if isUsableAsset(n) {
			t.Fatalf("expected %q to be dropped", n)
		}
	}
}

// codexAssets mirrors the real openai/codex release layout the user hit.
func codexAssets(version string) []*Asset {
	names := []string{
		"codex-app-server-package-x86_64-unknown-linux-musl.tar.gz",
		"codex-app-server-x86_64-unknown-linux-musl.sigstore",
		"codex-app-server-x86_64-unknown-linux-musl.tar.gz",
		"codex-npm-linux-x64-" + version + ".tgz",
		"codex-package-x86_64-unknown-linux-musl.tar.gz",
		"codex-responses-api-proxy-x86_64-unknown-linux-musl.sigstore",
		"codex-responses-api-proxy-x86_64-unknown-linux-musl.tar.gz",
		"codex-symbols-x86_64-unknown-linux-musl-app-server.tar.gz",
		"codex-symbols-x86_64-unknown-linux-musl.tar.gz",
		"codex-x86_64-unknown-linux-musl.sigstore",
		"codex-x86_64-unknown-linux-musl.tar.gz",
		"codex-zsh-x86_64-unknown-linux-musl.tar.gz",
		"openai_codex_cli_bin-" + version + "-py3-none-manylinux_2_17_x86_64.whl",
	}
	as := make([]*Asset, 0, len(names))
	for _, n := range names {
		as = append(as, &Asset{Name: n, URL: "https://example/" + n})
	}
	return as
}

func TestSelectReleaseAssetReusesChoice(t *testing.T) {
	resolver = testLinuxAMDResolver

	chosen := "codex-app-server-x86_64-unknown-linux-musl.tar.gz"
	usable := filterUsableAssets(codexAssets("0.140.0"))
	fp := Fingerprint(usable)

	// Next release: identical layout, only the version bumped. Must reuse the
	// remembered choice with no prompt and pick the same (current) asset.
	f := NewFilter(&FilterOpts{
		SelectedAsset:    NormalizeAssetName(chosen),
		AssetFingerprint: fp,
	})
	gf, err := f.SelectReleaseAsset("codex", codexAssets("0.141.0"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gf.Name != chosen {
		t.Fatalf("expected reused asset %q, got %q", chosen, gf.Name)
	}
}

func TestSelectReleaseAssetDetectsLayoutChange(t *testing.T) {
	resolver = testLinuxAMDResolver

	oldFP := Fingerprint(filterUsableAssets(codexAssets("0.140.0")))

	// A genuinely new installable file appears => fingerprint must differ,
	// which is what forces a re-prompt in SelectReleaseAsset.
	withExtra := append(codexAssets("0.141.0"),
		&Asset{Name: "codex-extra-x86_64-unknown-linux-musl.tar.gz", URL: "https://example/extra"})
	newFP := Fingerprint(filterUsableAssets(withExtra))

	if stringSlicesEqual(oldFP, newFP) {
		t.Fatal("expected fingerprint to change when an installable asset is added")
	}

	// Adding only a junk file (e.g. a new signature) must NOT change it.
	withJunk := append(codexAssets("0.141.0"),
		&Asset{Name: "codex-extra-x86_64-unknown-linux-musl.sigstore", URL: "https://example/junk"})
	junkFP := Fingerprint(filterUsableAssets(withJunk))
	if !stringSlicesEqual(oldFP, junkFP) {
		t.Fatal("adding a junk file must not change the fingerprint")
	}
}

func TestIsSupportedExt(t *testing.T) {
	cases := []struct {
		in  string
		out bool
	}{
		{
			"Ultimaker_Cura-4.8.0.AppImage",
			true,
		},
		{
			"Ultimaker_Cura-4.7.1-win64.msi",
			false,
		},
	}

	for _, c := range cases {
		result := isSupportedExt(c.in)
		if result != c.out {
			t.Fatalf("Expected result for extension %v to be %v, but got result %v", c.in, c.out, result)
		}
	}

}

func TestPreferArchiveType(t *testing.T) {
	in := []*Asset{
		{Name: "eza_x86_64-unknown-linux-gnu.tar.gz"},
		{Name: "eza_x86_64-unknown-linux-gnu.zip"},
		{Name: "eza_x86_64-unknown-linux-musl.tar.gz"},
		{Name: "eza_x86_64-unknown-linux-musl.zip"},
		{Name: "eza_x86_64-unknown-linux.AppImage"}, // no twin -> kept
	}

	resolver = testLinuxAMDResolver
	out := preferArchiveType(in)
	if len(out) != 3 { // 2 tar + AppImage
		t.Fatalf("linux: want 3, got %d", len(out))
	}
	for _, a := range out {
		if strings.HasSuffix(strings.ToLower(a.Name), ".zip") {
			t.Fatalf("linux should drop zip twins, got %s", a.Name)
		}
	}

	resolver = testWindowsAMDResolver
	out = preferArchiveType(in)
	for _, a := range out {
		if strings.HasSuffix(strings.ToLower(a.Name), ".tar.gz") {
			t.Fatalf("windows should drop tar twins, got %s", a.Name)
		}
	}
}

func TestPreferMusl(t *testing.T) {
	// gnu/musl twins of the same asset -> only musl kept
	in := []*Asset{
		{Name: "eza_x86_64-unknown-linux-gnu.tar.gz"},
		{Name: "eza_x86_64-unknown-linux-musl.tar.gz"},
	}
	out := preferMusl(in)
	if len(out) != 1 || !strings.Contains(out[0].Name, "musl") {
		t.Fatalf("want only musl twin, got %v", names(out))
	}
	// genuinely different assets must NOT be collapsed
	in2 := []*Asset{
		{Name: "codex-app-server-x86_64-unknown-linux-musl.tar.gz"},
		{Name: "codex-x86_64-unknown-linux-musl.tar.gz"},
	}
	if out2 := preferMusl(in2); len(out2) != 2 {
		t.Fatalf("distinct assets must be kept, got %v", names(out2))
	}
	// gnu-only (no musl twin) is kept as-is
	in3 := []*Asset{{Name: "tool-linux-gnu.tar.gz"}}
	if out3 := preferMusl(in3); len(out3) != 1 {
		t.Fatalf("gnu-only should be kept, got %v", names(out3))
	}
}

func names(as []*Asset) []string {
	out := make([]string, len(as))
	for i, a := range as {
		out[i] = a.Name
	}
	return out
}

func TestAppImageNotPreferredOverBinary(t *testing.T) {
	resolver = testLinuxAMDResolver

	// opencode ships a CLI tarball and a desktop GUI AppImage: never auto-pick
	// the AppImage when a real binary is present.
	chosen, opts := Preview("opencode", []string{
		"opencode-desktop-linux-x86_64.AppImage",
		"opencode-desktop-linux-amd64.deb",
		"opencode-linux-x64.tar.gz",
		"opencode-linux-x64-musl.tar.gz",
	})
	for _, n := range append(opts, chosen) {
		if strings.HasSuffix(strings.ToLower(n), ".appimage") {
			t.Fatalf("AppImage should not be offered when a binary exists; chosen=%q opts=%v", chosen, opts)
		}
	}

	// AppImage-only release: the AppImage is still selected (nothing else).
	chosen2, _ := Preview("cura", []string{
		"Ultimaker_Cura-4.7.1-Darwin.dmg",
		"Ultimaker_Cura-4.7.1-win64.exe",
		"Ultimaker_Cura-4.7.1.AppImage",
		"Ultimaker_Cura-4.7.1.AppImage.asc",
	})
	if !strings.HasSuffix(chosen2, ".AppImage") {
		t.Fatalf("AppImage-only release should pick the AppImage, got %q", chosen2)
	}
}

func TestARMAndX86ReleaseAssetSelection(t *testing.T) {
	cases := []struct {
		name     string
		repoName string
		resolver platformResolver
		assets   []string
		want     string
	}{
		{
			name:     "pik arm picks aarch64",
			repoName: "pik",
			resolver: testLinuxARMResolver,
			assets: []string{
				"pik-1.0.0-aarch64-unknown-linux-gnu.tar.gz",
				"pik-1.0.0-x86_64-unknown-linux-gnu.tar.gz",
			},
			want: "pik-1.0.0-aarch64-unknown-linux-gnu.tar.gz",
		},
		{
			name:     "pik x86 picks x86_64",
			repoName: "pik",
			resolver: testLinuxAMDResolver,
			assets: []string{
				"pik-1.0.0-aarch64-unknown-linux-gnu.tar.gz",
				"pik-1.0.0-x86_64-unknown-linux-gnu.tar.gz",
			},
			want: "pik-1.0.0-x86_64-unknown-linux-gnu.tar.gz",
		},
		{
			name:     "git-town arm picks arm_64",
			repoName: "git-town",
			resolver: testLinuxARMResolver,
			assets: []string{
				"git-town_linux_arm_64.tar.gz",
				"git-town_linux_intel_64.tar.gz",
			},
			want: "git-town_linux_arm_64.tar.gz",
		},
		{
			name:     "git-town x86 picks intel_64",
			repoName: "git-town",
			resolver: testLinuxAMDResolver,
			assets: []string{
				"git-town_linux_arm_64.tar.gz",
				"git-town_linux_intel_64.tar.gz",
			},
			want: "git-town_linux_intel_64.tar.gz",
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			resolver = c.resolver
			got, opts := Preview(c.repoName, c.assets)
			if got != c.want {
				t.Fatalf("want %q, got %q, options=%v", c.want, got, opts)
			}
		})
	}
}

func TestAtuinARMSelectionDropsUpdateServerAndX86Assets(t *testing.T) {
	resolver = testLinuxARMResolver

	names := []string{
		"atuin-aarch64-unknown-linux-musl-update",
		"atuin-aarch64-unknown-linux-musl.tar.gz",
		"atuin-server-aarch64-unknown-linux-musl-update",
		"atuin-server-aarch64-unknown-linux-musl.tar.gz",
		"atuin-server-x86_64-unknown-linux-musl-update",
		"atuin-server-x86_64-unknown-linux-musl.tar.gz",
	}
	as := make([]*Asset, 0, len(names))
	for _, n := range names {
		as = append(as, &Asset{Name: n})
	}

	gf, err := NewFilter(&FilterOpts{PackageName: "atuin", NonInteractive: true}).SelectReleaseAsset("atuin", as)
	if err != nil {
		t.Fatalf("unexpected selection error: %v", err)
	}
	if gf.Name != "atuin-aarch64-unknown-linux-musl.tar.gz" {
		t.Fatalf("want atuin aarch64 tarball, got %q", gf.Name)
	}
}

func TestZstTarExtraction(t *testing.T) {
	resolver = testLinuxAMDResolver
	// build a tar with a single (fake) binary file
	var tarbuf bytes.Buffer
	tw := tar.NewWriter(&tarbuf)
	content := append([]byte{0x7f, 'E', 'L', 'F'}, make([]byte, 64)...)
	_ = tw.WriteHeader(&tar.Header{Name: "ollama", Mode: 0o755, Size: int64(len(content)), Typeflag: tar.TypeReg})
	_, _ = tw.Write(content)
	_ = tw.Close()
	// zstd-compress it (-> .tar.zst)
	var zbuf bytes.Buffer
	zw, _ := zstd.NewWriter(&zbuf)
	_, _ = zw.Write(tarbuf.Bytes())
	_ = zw.Close()

	f := NewFilter(&FilterOpts{})
	ff, err := f.processReader(bytes.NewReader(zbuf.Bytes()))
	if err != nil {
		t.Fatalf("processReader(.tar.zst): %v", err)
	}
	if ff.Name != "ollama" {
		t.Fatalf("extracted name = %q, want ollama", ff.Name)
	}
	got, _ := io.ReadAll(ff.Source)
	if !bytes.Equal(got, content) {
		t.Fatalf("extracted content mismatch (%d bytes)", len(got))
	}
}
