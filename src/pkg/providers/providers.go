package providers

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"net/url"
	"regexp"
	"strings"

	"github.com/bresilla/bin/src/pkg/assets"
)

var ErrInvalidProvider = errors.New("invalid provider")

type File struct {
	Data        io.Reader
	Name        string
	Version     string
	Length      int64
	PackagePath string
	// SelectedAsset holds the version-normalized name of the chosen release asset.
	SelectedAsset string
	// AssetFingerprint holds the normalized set of installable assets.
	AssetFingerprint []string
	// PackageFingerprint holds the normalized set of inner-archive files.
	PackageFingerprint []string
	// Libs holds extracted shared-library sidecar dependencies.
	Libs map[string]*assets.Sidecar
}

func (f *File) Hash() ([]byte, error) {
	h := sha256.New()
	if _, err := io.Copy(h, f.Data); err != nil {
		return nil, err
	}
	return h.Sum(nil), nil
}

type FetchOpts struct {
	All            bool
	PackageName    string
	PackagePath    string
	SkipPatchCheck bool
	Version        string
	// SelectedAsset carries the remembered asset choice.
	SelectedAsset string
	// AssetFingerprint carries the remembered set of assets.
	AssetFingerprint []string
	Recheck          bool
	// WantedAsset specifies an exact asset choice.
	WantedAsset string
	// WantedPackagePath specifies an exact package path choice.
	WantedPackagePath string
	// PackageFingerprint carries the remembered inner-archive file set.
	PackageFingerprint []string
	// NonInteractive fails when interactive selection is required.
	NonInteractive bool
	// CollectLibs enables extraction of shared-library dependencies.
	CollectLibs bool
}

type Provider interface {
	// Fetch returns the file metadata for the provider.
	Fetch(*FetchOpts) (*File, error)
	// GetLatestVersion returns the latest version tag and download URL.
	GetLatestVersion() (string, string, error)

	// GetID returns the unique provider identifier.
	GetID() string
}

// Describer provides the repository's short description.
type Describer interface {
	GetDescription() (string, error)
}

var (
	httpUrlPrefix      = regexp.MustCompile("^https?://")
	dockerUrlPrefix    = regexp.MustCompile("^docker://")
	goinstallUrlPrefix = regexp.MustCompile("^goinstall://")
)

func New(u, provider string) (Provider, error) {
	if dockerUrlPrefix.MatchString(u) {
		return newDocker(u)
	}
	if goinstallUrlPrefix.MatchString(u) || provider == "goinstall" {
		return newGoInstall(u)
	}
	if !httpUrlPrefix.MatchString(u) {
		u = fmt.Sprintf("https://%s", u)
	}

	purl, err := url.Parse(u)
	if err != nil {
		return nil, err
	}

	if strings.Contains(purl.Host, "github") || provider == "github" {
		return newGitHub(purl)
	}

	if strings.Contains(purl.Host, "gitlab") || provider == "gitlab" {
		return newGitLab(purl)
	}

	if strings.Contains(purl.Host, "codeberg") || provider == "codeberg" {
		return newCodeberg(purl)
	}

	if strings.Contains(purl.Host, "releases.hashicorp.com") || provider == "hashicorp" {
		return newHashiCorp(purl)
	}

	return nil, fmt.Errorf("Can't find provider for url %s", u)
}
