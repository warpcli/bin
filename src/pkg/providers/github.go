package providers

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"

	"github.com/bresilla/geto/src/pkg/assets"
	"github.com/caarlos0/log"
	"github.com/google/go-github/v31/github"
	"golang.org/x/oauth2"
)

type gitHub struct {
	url    *url.URL
	client *github.Client
	owner  string
	repo   string
	tag    string
	token  string
}

func (g *gitHub) Fetch(opts *FetchOpts) (*File, error) {
	var release *github.RepositoryRelease

	var err error
	var resp *github.Response
	if len(g.tag) > 0 || len(opts.Version) > 0 {
		if len(opts.Version) > 0 {
			g.tag = opts.Version
		}
		log.Debugf("Getting %s release for %s/%s", g.tag, g.owner, g.repo)
		release, _, err = g.client.Repositories.GetReleaseByTag(context.TODO(), g.owner, g.repo, g.tag)
	} else {
		log.Debugf("Getting latest release for %s/%s", g.owner, g.repo)
		release, resp, err = g.client.Repositories.GetLatestRelease(context.TODO(), g.owner, g.repo)
		if resp.StatusCode == http.StatusNotFound {
			err = fmt.Errorf("repository %s/%s does not have releases", g.owner, g.repo)
		}
	}

	if err != nil {
		return nil, err
	}

	candidates := []*assets.Asset{}
	for _, a := range release.Assets {
		candidates = append(candidates, &assets.Asset{Name: a.GetName(), URL: a.GetURL()})
	}
	f := assets.NewFilter(&assets.FilterOpts{SkipScoring: opts.All, PackagePath: opts.PackagePath, PackageFingerprint: opts.PackageFingerprint, SkipPathCheck: opts.SkipPatchCheck, PackageName: opts.PackageName, SelectedAsset: opts.SelectedAsset, AssetFingerprint: opts.AssetFingerprint, Recheck: opts.Recheck, WantedAsset: opts.WantedAsset, WantedPackagePath: opts.WantedPackagePath, NonInteractive: opts.NonInteractive, CollectLibs: opts.CollectLibs})

	gf, err := f.SelectReleaseAsset(g.repo, candidates)
	if err != nil {
		return nil, err
	}

	gf.ExtraHeaders = map[string]string{"Accept": "application/octet-stream"}
	if g.token != "" {
		gf.ExtraHeaders["Authorization"] = fmt.Sprintf("token %s", g.token)
	}

	outFile, err := f.ProcessURL(gf)
	if err != nil {
		return nil, err
	}

	version := release.GetTagName()

	// TODO: calculate and verify release asset SHA256 checksum.
	file := &File{Data: outFile.Source, Name: outFile.Name, Version: version, PackagePath: outFile.PackagePath, PackageFingerprint: outFile.PackageFingerprint, SelectedAsset: assets.NormalizeAssetName(gf.Name), AssetFingerprint: gf.Fingerprint, Libs: outFile.Sidecars}

	return file, nil
}

// GetLatestVersion returns the latest release tag and HTML URL.
func (g *gitHub) GetLatestVersion() (string, string, error) {
	log.Debugf("Getting latest release for %s/%s", g.owner, g.repo)
	release, _, err := g.client.Repositories.GetLatestRelease(context.TODO(), g.owner, g.repo)
	if err != nil {
		return "", "", err
	}

	return release.GetTagName(), release.GetHTMLURL(), nil
}

func (g *gitHub) GetID() string {
	return "github"
}

// GetDescription returns the repository description.
func (g *gitHub) GetDescription() (string, error) {
	repo, _, err := g.client.Repositories.Get(context.TODO(), g.owner, g.repo)
	if err != nil {
		return "", err
	}
	return repo.GetDescription(), nil
}

func newGitHub(u *url.URL) (Provider, error) {
	s := strings.Split(u.Path, "/")
	if len(s) < 3 {
		return nil, fmt.Errorf("error parsing Github URL %s, can't find owner and repo", u.String())
	}

	var tag string
	if strings.Contains(u.Path, "/releases/") {
		ps := strings.Split(u.Path, "/")
		for i, p := range ps {
			if p == "releases" {
				tag = strings.Join(ps[i+2:], "/")
			}
		}

	}

	token := os.Getenv("GITHUB_AUTH_TOKEN")
	if len(token) == 0 {
		token = os.Getenv("GITHUB_TOKEN")
	}

	// Configures GitHub Enterprise Server client when environment variables are present.
	gbu := os.Getenv("GHES_BASE_URL")
	guu := os.Getenv("GHES_UPLOAD_URL")
	gau := os.Getenv("GHES_AUTH_TOKEN")

	var tc *http.Client

	if len(gbu) > 0 && len(guu) > 0 && len(gau) > 0 {
		tc = oauth2.NewClient(context.Background(), oauth2.StaticTokenSource(
			&oauth2.Token{AccessToken: gau},
		))
	} else if token != "" {
		tc = oauth2.NewClient(context.Background(), oauth2.StaticTokenSource(
			&oauth2.Token{AccessToken: token},
		))
	}

	var client *github.Client
	var err error

	if len(gbu) > 0 && len(guu) > 0 && len(gau) > 0 {
		if client, err = github.NewEnterpriseClient(gbu, guu, tc); err != nil {
			return nil, fmt.Errorf("error initializing GHES client %v", err)
		}
	} else {
		client = github.NewClient(tc)
	}

	return &gitHub{url: u, client: client, owner: s[1], repo: s[2], tag: tag, token: token}, nil
}
