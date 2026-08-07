package providers

import (
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"

	"code.gitea.io/sdk/gitea"
	"github.com/bresilla/bin/src/pkg/assets"
	"github.com/caarlos0/log"
)

type codeberg struct {
	url    *url.URL
	client *gitea.Client
	owner  string
	repo   string
	tag    string
	token  string
}

func (c *codeberg) Fetch(opts *FetchOpts) (*File, error) {
	var release *gitea.Release

	var err error
	var resp *gitea.Response
	if len(c.tag) > 0 || len(opts.Version) > 0 {
		if len(opts.Version) > 0 {
			c.tag = opts.Version
		}
		log.Debugf("Getting %s release for %s/%s", c.tag, c.owner, c.repo)
		release, _, err = c.client.GetReleaseByTag(c.owner, c.repo, c.tag)
	} else {
		log.Debugf("Getting latest release for %s/%s", c.owner, c.repo)
		release, resp, err = c.client.GetLatestRelease(c.owner, c.repo)
		if resp != nil && resp.StatusCode == http.StatusNotFound {
			err = fmt.Errorf("repository %s/%s does not have releases", c.owner, c.repo)
		}
	}

	if err != nil {
		return nil, err
	}

	candidates := []*assets.Asset{}
	for _, a := range release.Attachments {
		candidates = append(candidates, &assets.Asset{Name: a.Name, URL: a.DownloadURL})
	}
	f := assets.NewFilter(&assets.FilterOpts{SkipScoring: opts.All, PackagePath: opts.PackagePath, PackageFingerprint: opts.PackageFingerprint, SkipPathCheck: opts.SkipPatchCheck, PackageName: opts.PackageName, SelectedAsset: opts.SelectedAsset, AssetFingerprint: opts.AssetFingerprint, Recheck: opts.Recheck, WantedAsset: opts.WantedAsset, WantedPackagePath: opts.WantedPackagePath, NonInteractive: opts.NonInteractive, CollectLibs: opts.CollectLibs})

	gf, err := f.SelectReleaseAsset(c.repo, candidates)
	if err != nil {
		return nil, err
	}

	gf.ExtraHeaders = map[string]string{"Accept": "application/octet-stream"}
	if c.token != "" {
		gf.ExtraHeaders["Authorization"] = fmt.Sprintf("token %s", c.token)
	}

	outFile, err := f.ProcessURL(gf)
	if err != nil {
		return nil, err
	}

	version := release.TagName

	// TODO: calculate and verify release asset SHA256 checksum.
	file := &File{Data: outFile.Source, Name: outFile.Name, Version: version, PackagePath: outFile.PackagePath, PackageFingerprint: outFile.PackageFingerprint, SelectedAsset: assets.NormalizeAssetName(gf.Name), AssetFingerprint: gf.Fingerprint, Libs: outFile.Sidecars}

	return file, nil
}

// GetDescription returns the repository description.
func (c *codeberg) GetDescription() (string, error) {
	repo, _, err := c.client.GetRepo(c.owner, c.repo)
	if err != nil {
		return "", err
	}
	return repo.Description, nil
}

// GetLatestVersion returns the latest release tag and HTML URL.
func (c *codeberg) GetLatestVersion() (string, string, error) {
	log.Debugf("Getting latest release for %s/%s", c.owner, c.repo)
	release, _, err := c.client.GetLatestRelease(c.owner, c.repo)
	if err != nil {
		return "", "", err
	}

	return release.TagName, release.HTMLURL, nil
}

func (c *codeberg) GetID() string {
	return "codeberg"
}

func newCodeberg(u *url.URL) (Provider, error) {
	s := strings.Split(u.Path, "/")
	if len(s) < 3 {
		return nil, fmt.Errorf("error parsing Codeberg URL %s, can't find owner and repo", u.String())
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

	token := os.Getenv("CODEBERG_TOKEN")

	baseURL := fmt.Sprintf("https://%s/", u.Hostname())

	var client *gitea.Client
	var err error

	if token != "" {
		client, err = gitea.NewClient(baseURL, gitea.SetToken(token))
	} else {
		client, err = gitea.NewClient(baseURL)
	}

	if err != nil {
		return nil, fmt.Errorf("error initializing Codeberg client %v", err)
	}

	return &codeberg{url: u, client: client, owner: s[1], repo: s[2], tag: tag, token: token}, nil
}
