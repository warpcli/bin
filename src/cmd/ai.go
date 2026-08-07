package cmd

import (
	"errors"
	"os"

	"github.com/bresilla/geto/src/pkg/ai"
	"github.com/bresilla/geto/src/pkg/assets"
	"github.com/bresilla/geto/src/pkg/prompt"
	"github.com/caarlos0/log"
	"github.com/spf13/cobra"
)

type aiCmd struct {
	cmd  *cobra.Command
	opts aiOpts
}

type aiOpts struct {
	force bool
}

func newAICmd() *aiCmd {
	root := &aiCmd{}

	cmd := &cobra.Command{
		Use:   "ai",
		Short: "Inspect or reset the learned asset-selection model",
		Long: `Shows the model bin learns from your answers to "Multiple matches found".

When several release assets score identically, bin asks which one you want and
remembers the answer. Once it has learned from enough choices it resolves such
ties on its own instead of asking. It never overrides a better-scoring asset —
only equally-scored ones.

Set GETO_NO_AI=1 to turn the whole thing off.`,
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			dir := assets.AIModelDir()
			if dir == "" {
				log.Info("Asset-selection learning is off (GETO_NO_AI)")
				return nil
			}

			log.Infof("Model directory: %s", dir)

			engine := ai.NewEngine()
			if engine.Seeded() {
				log.Info("Built-in seed model: loaded")
			} else {
				log.Info("Built-in seed model: unavailable")
			}

			switch err := engine.Load(dir); {
			case errors.Is(err, os.ErrNotExist):
				log.Info("Your own choices: none recorded yet")
			case err != nil:
				log.Infof("Your own choices: ignoring an unusable model (%v)", err)
			default:
				log.Infof("Your own choices: learned from %d selection(s)", engine.Selections())
			}

			if engine.Trained() {
				log.Info("Clear-cut ties are resolved without asking; anything close still prompts")
			} else {
				log.Info("Every tie is resolved by asking you")
			}
			return nil
		},
	}

	reset := &cobra.Command{
		Use:           "reset",
		Short:         "Forget everything learned about asset selection",
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			dir := assets.AIModelDir()
			if dir == "" {
				log.Info("Asset-selection learning is off (GETO_NO_AI); nothing to reset")
				return nil
			}
			if !root.opts.force {
				if err := prompt.Confirm("Discard the learned asset-selection model?"); err != nil {
					return err
				}
			}
			removed, err := ai.Reset(dir)
			if err != nil {
				return err
			}
			if !removed {
				log.Info("Nothing learned yet; nothing to reset")
				return nil
			}
			log.Info("Learned asset-selection model discarded")
			return nil
		},
	}
	reset.Flags().BoolVarP(&root.opts.force, "force", "f", false, "Bypass confirmation prompt")
	cmd.AddCommand(reset)

	root.cmd = cmd
	return root
}
