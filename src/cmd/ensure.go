package cmd

import (
	"crypto/sha256"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/bresilla/geto/src/pkg/config"
	"github.com/bresilla/geto/src/pkg/providers"
	"github.com/bresilla/geto/src/pkg/ui"
	"github.com/caarlos0/log"
	"github.com/spf13/cobra"
)

type ensureCmd struct {
	cmd *cobra.Command
}

func newEnsureCmd() *ensureCmd {
	root := &ensureCmd{}
	// nolint: dupl
	cmd := &cobra.Command{
		Use:           "ensure [binary_path]...",
		Aliases:       []string{"e", "sync"},
		Short:         "Ensures that all binaries listed in the configuration are present",
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg := config.Get()
			binsToProcess := map[string]*config.Binary{}

			if len(args) > 0 {
				for _, a := range args {
					bin, err := getBinPath(a)
					if err != nil {
						return err
					}
					binsToProcess[bin] = cfg.Bins[bin]
				}
			} else {
				binsToProcess = selectByTag(cfg.Bins)
			}

			// TODO: refactor to share installation logic.
			ensured := 0
			for _, binCfg := range binsToProcess {
				if binCfg.Description == "" {
					if desc := fetchDescription(binCfg); desc != "" {
						binCfg.Description = desc
						if err := config.UpsertBinary(binCfg); err != nil {
							return err
						}
					}
				}

				ep := os.ExpandEnv(binCfg.Path)
				_, err := os.Stat(ep)

				reason := "missing, installing"
				if err == nil {
					f, err := os.Open(ep)
					if err != nil {
						return err
					}

					h := sha256.New()
					if _, err := io.Copy(h, f); err != nil {
						return err
					}
					f.Close()

					if fmt.Sprintf("%x", h.Sum(nil)) == binCfg.Hash {
						continue
					}
					reason = "hash mismatch, reinstalling"
				} else if !os.IsNotExist(err) {
					continue
				}

				sep()
				stepHeader(filepath.Base(ep), reason+" · "+ui.RepoShort(binCfg.URL))

				p, err := providers.New(binCfg.URL, binCfg.Provider)
				if err != nil {
					return err
				}
				log.Debugf("Using provider '%s' for '%s'", p.GetID(), binCfg.URL)

				packageName := binCfg.RemoteName
				if packageName == "" {
					packageName = filepath.Base(ep)
				}
				pResult, err := p.Fetch(&providers.FetchOpts{Version: binCfg.Version, PackagePath: binCfg.PackagePath, PackageName: packageName, SelectedAsset: binCfg.SelectedAsset, AssetFingerprint: binCfg.AssetFingerprint, PackageFingerprint: binCfg.PackageFingerprint, NonInteractive: envBool("GETO_NONINTERACTIVE"), CollectLibs: binCfg.Patch})
				if err != nil {
					return err
				}

				hash, err := saveToDisk(pResult, ep, true)
				if err != nil {
					return fmt.Errorf("error installing binary: %w", err)
				}

				// Re-applies host patches for interpreter and libraries.
				hash, _ = applyHostPatches(ep, pResult.Libs, binCfg.Patch, hash)

				err = config.UpsertBinary(&config.Binary{
					RemoteName:         pResult.Name,
					Path:               binCfg.Path,
					Version:            pResult.Version,
					Hash:               fmt.Sprintf("%x", hash),
					URL:                binCfg.URL,
					Provider:           p.GetID(),
					PackagePath:        pResult.PackagePath,
					SelectedAsset:      pResult.SelectedAsset,
					AssetFingerprint:   pResult.AssetFingerprint,
					PackageFingerprint: pResult.PackageFingerprint,
					Patch:              binCfg.Patch,
				})
				if err != nil {
					return err
				}
				stepDone("ensured", filepath.Base(ep), pResult.Version)
				ensured++
			}

			if ensured == 0 {
				log.Info("All binaries present and up to date")
			} else {
				sep()
			}
			return nil
		},
	}

	root.cmd = cmd
	return root
}

func envBool(name string) bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(name))) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}
