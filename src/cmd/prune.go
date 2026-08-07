package cmd

import (
	"os"

	"github.com/bresilla/geto/src/pkg/config"
	"github.com/bresilla/geto/src/pkg/prompt"
	"github.com/caarlos0/log"
	"github.com/spf13/cobra"
)

type pruneCmd struct {
	cmd  *cobra.Command
	opts pruneOpts
}

type pruneOpts struct {
	force bool
}

func newPruneCmd() *pruneCmd {
	root := &pruneCmd{}
	// nolint: dupl
	cmd := &cobra.Command{
		Use:           "prune",
		Aliases:       []string{"clean", "gc"},
		Short:         "Prunes binaries that no longer exist in the system",
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg := config.Get()

			pathsToDel := []string{}
			for _, b := range selectByTag(cfg.Bins) {
				ep := os.ExpandEnv(b.Path)
				if _, err := os.Stat(ep); os.IsNotExist(err) {
					log.Infof("%s not found removing", ep)
					pathsToDel = append(pathsToDel, b.Path)
				}
			}

			if len(pathsToDel) == 0 {
				log.Info("Nothing to prune, all binaries exist")
				return nil
			}

			if !root.opts.force {
				err := prompt.Confirm("The following paths will be removed. Continue?")
				if err != nil {
					return err
				}
			}

			if err := config.RemoveBinaries(pathsToDel); err != nil {
				return err
			}

			log.Infof("Done, pruned %d binary(s)", len(pathsToDel))
			return nil
		},
	}

	root.cmd = cmd
	root.cmd.Flags().BoolVarP(&root.opts.force, "force", "f", false, "Bypass confirmation prompt")
	return root
}
