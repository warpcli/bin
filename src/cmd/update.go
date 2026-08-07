package cmd

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/bresilla/bin/src/pkg/config"
	"github.com/bresilla/bin/src/pkg/prompt"
	"github.com/bresilla/bin/src/pkg/providers"
	"github.com/caarlos0/log"
	"github.com/fatih/color"
	"github.com/hashicorp/go-version"
	"github.com/spf13/cobra"
)

type updateCmd struct {
	cmd  *cobra.Command
	opts updateOpts
}

type updateOpts struct {
	yesToUpdate     bool
	dryRun          bool
	all             bool
	skipPathCheck   bool
	continueOnError bool
	recheck         bool
}

type updateInfo struct{ version, url string }

func newUpdateCmd() *updateCmd {
	root := &updateCmd{}
	// nolint: dupl
	cmd := &cobra.Command{
		Use:           "update [binary_path]",
		Aliases:       []string{"u", "up", "upgrade"},
		Short:         "Updates one or multiple binaries managed by bin",
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			// TODO: support updating from a specific URL.
			// TODO: check for updates in parallel.

			toUpdate := map[*updateInfo]*config.Binary{}
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

			updateFailures := map[*config.Binary]error{}

			for p, b := range binsToProcess {
				if b == nil {
					log.Debugf("no config entry found for %s, skipping", p)
					continue
				}
				if b.Pinned {
					log.Infof("%s is a pinned binary", p)
					continue
				}
				p, err := providers.New(b.URL, b.Provider)
				if err != nil {
					return err
				}
				log.Debugf("Using provider '%s' for '%s'", p.GetID(), b.URL)

				if ui, err := getLatestVersion(b, p); err != nil {
					if root.opts.continueOnError {
						updateFailures[b] = fmt.Errorf("Error while getting latest version of %v: %v", b.Path, err)
						continue
					}
					return err
				} else if ui != nil {
					toUpdate[ui] = b
				}
			}

			if len(toUpdate) == 0 && len(updateFailures) == 0 {
				log.Infof("All binaries are up to date")
				return nil
			}

			if root.opts.dryRun {
				return wrapErrorWithCode(fmt.Errorf("Updates found, exit (dry-run mode)."), 3, "")
			}

			if len(toUpdate) > 0 && !root.opts.yesToUpdate {
				for _, err := range updateFailures {
					log.Warnf("%v", err)
				}
				updateFailures = map[*config.Binary]error{}

				err := prompt.Confirm("Do you want to continue?")
				if err != nil {
					return err
				}
			}

			// TODO	:S code smell here, this pretty much does
			// the same thing as install logic. Refactor to
			// use the same code in both places
			for ui, b := range toUpdate {

				sep()
				stepHeader(filepath.Base(os.ExpandEnv(b.Path)), "updating · "+repoShort(b.URL))

				p, err := providers.New(ui.url, b.Provider)
				if err != nil {
					return err
				}
				log.Debugf("Using provider '%s' for '%s'", p.GetID(), ui.url)

				pResult, err := p.Fetch(&providers.FetchOpts{All: root.opts.all, PackagePath: b.PackagePath, SkipPatchCheck: root.opts.skipPathCheck, PackageName: b.RemoteName, SelectedAsset: b.SelectedAsset, AssetFingerprint: b.AssetFingerprint, PackageFingerprint: b.PackageFingerprint, Recheck: root.opts.recheck, CollectLibs: b.Patch})
				if err != nil {
					if root.opts.continueOnError {
						updateFailures[b] = fmt.Errorf("Error while fetching %v: %w", ui.url, err)
						continue
					}
					return err
				}

				hash, err := saveToDisk(pResult, b.Path, true)
				if err != nil {
					return fmt.Errorf("error installing binary: %w", err)
				}

				// Re-apply host patches (interpreter + bundled libs) if wanted.
				hash, _ = applyHostPatches(b.Path, pResult.Libs, b.Patch, hash)

				err = config.UpsertBinary(&config.Binary{
					RemoteName:         pResult.Name,
					Path:               b.Path,
					Version:            pResult.Version,
					Hash:               fmt.Sprintf("%x", hash),
					URL:                b.URL,
					Provider:           p.GetID(),
					PackagePath:        pResult.PackagePath,
					StateURL:           ui.url,
					SelectedAsset:      pResult.SelectedAsset,
					AssetFingerprint:   pResult.AssetFingerprint,
					PackageFingerprint: pResult.PackageFingerprint,
					Patch:              b.Patch,
				})

				if err != nil {
					return err
				}

				stepDone("updated", filepath.Base(os.ExpandEnv(b.Path)), ui.version)
			}
			sep()
			for _, err := range updateFailures {
				log.Warnf("%v", err)
			}
			// TODO: Return wrapping error with specific exit code if len(updateFailures) > 0?
			return nil
		},
	}

	root.cmd = cmd
	root.cmd.Flags().BoolVarP(&root.opts.dryRun, "dry-run", "", false, "Only show status, don't prompt for update")
	root.cmd.Flags().BoolVarP(&root.opts.yesToUpdate, "yes", "y", false, "Assume yes to update prompt")
	root.cmd.Flags().BoolVarP(&root.opts.all, "all", "a", false, "Show all possible download options (skip scoring & filtering)")
	root.cmd.Flags().BoolVarP(&root.opts.skipPathCheck, "skip-path-check", "p", false, "Skips path checking when looking into packages")
	root.cmd.Flags().BoolVarP(&root.opts.continueOnError, "continue-on-error", "c", false, "Continues to update next package if an error is encountered")
	root.cmd.Flags().BoolVarP(&root.opts.recheck, "recheck", "r", false, "Re-prompt for asset selection instead of reusing the remembered choice")
	return root
}

func getLatestVersion(b *config.Binary, p providers.Provider) (*updateInfo, error) {
	log.Debugf("Checking updates for %s", b.Path)
	v, u, err := p.GetLatestVersion()
	if err != nil {
		return nil, fmt.Errorf("Error checking updates for %s, %w", b.Path, err)
	}

	if b.Version == v {
		return nil, nil
	}

	bSemver, bSemverErr := version.NewVersion(b.Version)
	vSemver, vSemverErr := version.NewVersion(v)
	if bSemverErr == nil && vSemverErr == nil && vSemver.LessThanOrEqual(bSemver) {
		return nil, nil
	}

	log.Debugf("Found new version %s for %s at %s", v, b.Path, u)
	log.Infof("%s %s -> %s (%s)", b.Path, color.YellowString(b.Version), color.GreenString(v), u)
	return &updateInfo{v, u}, nil
}
