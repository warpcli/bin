package cmd

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/bresilla/geto/src/pkg/config"
	"github.com/bresilla/geto/src/pkg/ui"
	"github.com/caarlos0/log"
	"github.com/fatih/color"
	"github.com/spf13/cobra"
)

type removeCmd struct {
	cmd  *cobra.Command
	opts removeOpts
}

type removeOpts struct {
	yes bool
}

func newRemoveCmd() *removeCmd {
	root := &removeCmd{}
	// nolint: dupl
	cmd := &cobra.Command{
		Use:           "remove [<name> | <paths...>]",
		Aliases:       []string{"rm", "uninstall", "delete"},
		Short:         "Removes binaries managed by geto",
		SilenceUsage:  true,
		Args:          cobra.MinimumNArgs(1),
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg := config.Get()

			// Resolve every argument to a managed binary first.
			matches := []*config.Binary{}
			for _, p := range args {
				bp, err := getBinPath(p)
				if err != nil && !errors.Is(err, os.ErrNotExist) {
					log.Debugf("could not resolve %q via PATH: %v", p, err)
				}
				var match *config.Binary
				for _, b := range cfg.Bins {
					ep := os.ExpandEnv(b.Path)
					if (bp != "" && ep == os.ExpandEnv(bp)) ||
						p == b.Path || p == ep || filepath.Base(ep) == p {
						match = b
						break
					}
				}
				if match == nil {
					log.Warnf("%s is not managed by geto, skipping", color.YellowString(p))
					continue
				}
				matches = append(matches, match)
			}

			if len(matches) == 0 {
				log.Warn("No binaries to remove")
				return nil
			}

			// Confirm before deleting anything.
			if !root.opts.yes {
				names := make([]string, len(matches))
				for i, b := range matches {
					names[i] = filepath.Base(os.ExpandEnv(b.Path))
				}
				ok, err := ui.Confirm("Remove "+strings.Join(names, ", ")+"?", false)
				if err != nil {
					return err
				}
				if !ok {
					log.Info("Aborted")
					return nil
				}
			}

			removed := 0
			for _, match := range matches {
				ep := os.ExpandEnv(match.Path)
				// TODO some providers (like docker) might download additional
				// things somewhere else, maybe we should call the provider to
				// do a cleanup here.
				if err := os.Remove(ep); err != nil && !os.IsNotExist(err) {
					return fmt.Errorf("error removing path %s: %w", ep, err)
				}
				if err := config.RemoveBinaries([]string{match.Path}); err != nil {
					return err
				}
				log.Infof("Removed %s", color.GreenString(ep))
				removed++
			}

			log.Infof("Done, removed %d binary(s)", removed)
			return nil
		},
	}

	root.cmd = cmd
	root.cmd.Flags().BoolVarP(&root.opts.yes, "yes", "y", false, "Skip the confirmation prompt")
	return root
}
