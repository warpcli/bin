package cmd

import (
	"path/filepath"
	"strings"

	"github.com/bresilla/geto/src/pkg/config"
	"github.com/bresilla/geto/src/pkg/providers"
	"github.com/bresilla/geto/src/pkg/ui"
	"github.com/caarlos0/log"
	"github.com/spf13/cobra"
)

// fetchDescription returns the upstream repository's description or an empty string on error.
func fetchDescription(b *config.Binary) string {
	p, err := providers.New(b.URL, b.Provider)
	if err != nil {
		return ""
	}
	d, ok := p.(providers.Describer)
	if !ok {
		return ""
	}
	s, err := d.GetDescription()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(s)
}

type describeCmd struct {
	cmd  *cobra.Command
	opts describeOpts
}

type describeOpts struct {
	force bool
}

func newDescribeCmd() *describeCmd {
	root := &describeCmd{}
	cmd := &cobra.Command{
		Use:           "describe [<name> | <paths...>]",
		Aliases:       []string{"desc"},
		Short:         "Fetch and store repository descriptions",
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg := config.Get()

			targets := map[string]*config.Binary{}
			if len(args) > 0 {
				for _, a := range args {
					k, err := getBinPath(a)
					if err != nil {
						return err
					}
					targets[k] = cfg.Bins[k]
				}
			} else {
				targets = selectByTag(cfg.Bins)
			}

			done, skipped := 0, 0
			for _, b := range targets {
				if b == nil {
					continue
				}
				if b.Description != "" && !root.opts.force {
					skipped++
					continue
				}
				desc := fetchDescription(b)
				if desc == "" {
					log.Warnf("no description for %s", filepath.Base(b.Path))
					continue
				}
				b.Description = desc
				if err := config.UpsertBinary(b); err != nil {
					return err
				}
				log.Infof("%s — %s", filepath.Base(b.Path), ui.MutedStyle.Render(desc))
				done++
			}
			log.Infof("Done: %d described, %d already had one", done, skipped)
			return nil
		},
	}

	root.cmd = cmd
	root.cmd.Flags().BoolVarP(&root.opts.force, "force", "f", false, "Refetch even if a description already exists")
	return root
}
