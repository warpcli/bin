package cmd

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/bresilla/geto/src/pkg/assets"
	"github.com/bresilla/geto/src/pkg/config"
	"github.com/bresilla/geto/src/pkg/providers"
	"github.com/spf13/cobra"
)

type applyCmd struct {
	cmd  *cobra.Command
	opts applyOpts
}

type applyOpts struct {
	nonInteractive bool
	force          bool
	refresh        bool
}

type applyFile struct {
	DefaultPath string                 `json:"default_path"`
	Bins        map[string]applyBinary `json:"bins"`
}

type applyBinary struct {
	URL         string   `json:"url"`
	Name        *string  `json:"name,omitempty"`
	Path        *string  `json:"path,omitempty"`
	Provider    *string  `json:"provider,omitempty"`
	Version     *string  `json:"version,omitempty"`
	Asset       *string  `json:"asset,omitempty"`
	PackagePath *string  `json:"package_path,omitempty"`
	Description *string  `json:"description,omitempty"`
	Tags        []string `json:"tags,omitempty"`
	Patch       *bool    `json:"patch,omitempty"`
	Force       bool     `json:"force,omitempty"`
	Refresh     bool     `json:"refresh,omitempty"`
}

func newApplyCmd() *applyCmd {
	root := &applyCmd{}
	cmd := &cobra.Command{
		Use:           "apply <desired.json>",
		Short:         "Apply a declarative binary manifest",
		SilenceUsage:  true,
		SilenceErrors: true,
		Args:          cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return root.run(args[0])
		},
	}
	root.cmd = cmd
	root.cmd.Flags().BoolVar(&root.opts.nonInteractive, "non-interactive", false, "fail instead of prompting when a choice is ambiguous")
	root.cmd.Flags().BoolVarP(&root.opts.force, "force", "f", false, "reinstall every declared binary")
	root.cmd.Flags().BoolVar(&root.opts.refresh, "refresh", false, "resolve latest versions instead of reusing existing pinned state")
	return root
}

func (c *applyCmd) run(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var desired applyFile
	if err := json.Unmarshal(data, &desired); err != nil {
		return err
	}
	if len(desired.Bins) == 0 {
		return nil
	}

	if desired.DefaultPath != "" {
		config.Get().DefaultPath = desired.DefaultPath
	}
	if config.Get().DefaultPath == "" {
		return fmt.Errorf("desired manifest needs default_path or an existing bin default path")
	}
	if err := os.MkdirAll(os.ExpandEnv(config.Get().DefaultPath), 0o755); err != nil {
		return err
	}

	for key, spec := range desired.Bins {
		if err := c.applyOne(key, spec); err != nil {
			return fmt.Errorf("%s: %w", key, err)
		}
	}
	return nil
}

func (c *applyCmd) applyOne(key string, spec applyBinary) error {
	if strings.TrimSpace(spec.URL) == "" {
		return fmt.Errorf("url is required")
	}

	name := applyString(spec.Name, key)
	if name == "" {
		name = defaultBinName(spec.URL)
	}
	path := applyString(spec.Path, filepath.Join(config.Get().DefaultPath, name))
	path = os.ExpandEnv(path)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}

	providerID := applyString(spec.Provider, "")
	existing := existingApplyBinary(path)
	force := c.opts.force || spec.Force
	refresh := c.opts.refresh || spec.Refresh

	if !force && !refresh && existing != nil && existingMatches(path, existing, spec) {
		return nil
	}

	p, err := providers.New(spec.URL, providerID)
	if err != nil {
		return err
	}

	version := applyString(spec.Version, "")
	if version == "" && existing != nil && !refresh {
		version = existing.Version
	}

	patch := true
	if spec.Patch != nil {
		patch = *spec.Patch
	} else if existing != nil {
		patch = existing.Patch
	}

	fetch := &providers.FetchOpts{
		PackageName:       name,
		Version:           version,
		NonInteractive:    c.opts.nonInteractive,
		CollectLibs:       patch,
		WantedAsset:       applyString(spec.Asset, ""),
		WantedPackagePath: applyString(spec.PackagePath, ""),
	}
	if existing != nil && !refresh {
		fetch.PackagePath = existing.PackagePath
		fetch.PackageFingerprint = existing.PackageFingerprint
		fetch.SelectedAsset = existing.SelectedAsset
		fetch.AssetFingerprint = existing.AssetFingerprint
	}

	res, err := p.Fetch(fetch)
	if err != nil {
		return err
	}

	hash, err := saveToDisk(res, path, true)
	if err != nil {
		return fmt.Errorf("error installing binary: %w", err)
	}
	hash, patched := applyHostPatches(path, res.Libs, patch, hash)

	tags := spec.Tags
	if len(tags) == 0 && existing != nil {
		tags = existing.Tags
	}
	if len(tags) == 0 {
		tags = []string{"nix"}
	}

	description := applyString(spec.Description, "")
	if description == "" && existing != nil {
		description = existing.Description
	}

	return config.UpsertBinary(&config.Binary{
		RemoteName:         res.Name,
		Path:               path,
		Version:            res.Version,
		Hash:               fmt.Sprintf("%x", hash),
		URL:                spec.URL,
		Provider:           p.GetID(),
		Description:        description,
		PackagePath:        res.PackagePath,
		StateURL:           spec.URL,
		SelectedAsset:      res.SelectedAsset,
		AssetFingerprint:   res.AssetFingerprint,
		PackageFingerprint: res.PackageFingerprint,
		Tags:               tags,
		Patch:              patch || patched,
	})
}

func applyString(v *string, fallback string) string {
	if v == nil {
		return fallback
	}
	return *v
}

func existingApplyBinary(path string) *config.Binary {
	if b := config.Get().Bins[path]; b != nil {
		return b
	}
	for _, b := range config.Get().Bins {
		if b != nil && os.ExpandEnv(b.Path) == path {
			return b
		}
	}
	return nil
}

func existingMatches(path string, b *config.Binary, spec applyBinary) bool {
	if b == nil || b.URL != spec.URL {
		return false
	}
	if provider := applyString(spec.Provider, ""); provider != "" && b.Provider != provider {
		return false
	}
	if version := applyString(spec.Version, ""); version != "" && b.Version != version {
		return false
	}
	if asset := applyString(spec.Asset, ""); asset != "" && b.SelectedAsset != assets.NormalizeAssetName(asset) {
		return false
	}
	if packagePath := applyString(spec.PackagePath, ""); packagePath != "" && b.PackagePath != packagePath {
		return false
	}
	if b.Hash == "" {
		return false
	}
	got, err := fileSHA256(path)
	return err == nil && got == b.Hash
}

func fileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
