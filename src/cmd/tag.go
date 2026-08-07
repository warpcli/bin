package cmd

import (
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/bresilla/geto/src/pkg/config"
	"github.com/caarlos0/log"
	"github.com/fatih/color"
	"github.com/spf13/cobra"
)

type tagCmd struct {
	cmd *cobra.Command
}

func newTagCmd() *tagCmd {
	root := &tagCmd{}
	cmd := &cobra.Command{
		Use:           "tag",
		Short:         "Manage tags (tiers) for managed binaries",
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	cmd.AddCommand(
		newTagLsCmd(),
		newTagShowCmd(),
		newTagAddCmd(),
		newTagRmCmd(),
	)
	root.cmd = cmd
	return root
}

// resolveBins maps name/path arguments to their managed binaries.
func resolveBins(args []string) (map[string]*config.Binary, error) {
	cfg := config.Get()
	out := map[string]*config.Binary{}
	for _, a := range args {
		key, err := getBinPath(a)
		if err != nil {
			return nil, fmt.Errorf("%q is not managed by geto: %w", a, err)
		}
		b := cfg.Bins[key]
		if b == nil {
			return nil, fmt.Errorf("%q is not managed by geto", a)
		}
		out[key] = b
	}
	return out, nil
}

func newTagLsCmd() *cobra.Command {
	return &cobra.Command{
		Use:           "ls",
		Aliases:       []string{"list"},
		Short:         "List all tags and how many binaries each has",
		Args:          cobra.NoArgs,
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			counts := map[string]int{}
			for _, b := range config.Get().Bins {
				if b == nil {
					continue
				}
				for _, t := range binTags(b) {
					counts[t]++
				}
			}
			if len(counts) == 0 {
				log.Info("No binaries installed")
				return nil
			}
			tags := make([]string, 0, len(counts))
			for t := range counts {
				tags = append(tags, t)
			}
			sort.Strings(tags)
			for _, t := range tags {
				fmt.Printf("%s (%d)\n", t, counts[t])
			}
			return nil
		},
	}
}

func newTagShowCmd() *cobra.Command {
	return &cobra.Command{
		Use:           "show <name|path>...",
		Short:         "Show the tags of the given binaries",
		Args:          cobra.MinimumNArgs(1),
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			bins, err := resolveBins(args)
			if err != nil {
				return err
			}
			for _, b := range bins {
				fmt.Printf("%s: %s\n", os.ExpandEnv(b.Path), strings.Join(binTags(b), ", "))
			}
			return nil
		},
	}
}

func newTagAddCmd() *cobra.Command {
	return &cobra.Command{
		Use:           "add <tag> <name|path>...",
		Short:         "Add a tag to one or more binaries",
		Args:          cobra.MinimumNArgs(2),
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			tag := args[0]
			bins, err := resolveBins(args[1:])
			if err != nil {
				return err
			}
			for _, b := range bins {
				if !binHasAnyTag(b, []string{tag}) {
					b.Tags = append(binTags(b), tag)
				}
				if err := config.UpsertBinary(b); err != nil {
					return err
				}
				log.Infof("Tagged %s with %s (now: %s)", os.ExpandEnv(b.Path), color.GreenString(tag), strings.Join(b.Tags, ", "))
			}
			return nil
		},
	}
}

func newTagRmCmd() *cobra.Command {
	return &cobra.Command{
		Use:           "rm <tag> <name|path>...",
		Aliases:       []string{"remove"},
		Short:         "Remove a tag from one or more binaries",
		Args:          cobra.MinimumNArgs(2),
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			tag := args[0]
			bins, err := resolveBins(args[1:])
			if err != nil {
				return err
			}
			for _, b := range bins {
				newTags := []string{}
				for _, t := range binTags(b) {
					if t != tag {
						newTags = append(newTags, t)
					}
				}
				// A binary always belongs to at least "default".
				if len(newTags) == 0 {
					newTags = []string{"default"}
				}
				b.Tags = newTags
				if err := config.UpsertBinary(b); err != nil {
					return err
				}
				log.Infof("Removed tag %s from %s (now: %s)", color.YellowString(tag), os.ExpandEnv(b.Path), strings.Join(b.Tags, ", "))
			}
			return nil
		},
	}
}
