package cmd

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/bresilla/bin/src/pkg/config"
	"github.com/bresilla/bin/src/pkg/ui"
	"github.com/caarlos0/log"
	"github.com/fatih/color"
	"github.com/mattn/go-isatty"
	"github.com/spf13/cobra"
)

func Execute(version string, exit func(int), args []string) {
	// enable colored output on travis
	if os.Getenv("CI") != "" {
		color.NoColor = false
	}

	// fmt.Println()
	// defer fmt.Println()
	newRootCmd(version, exit).Execute(args)
}

func (cmd *rootCmd) Execute(args []string) {
	cmd.cmd.SetArgs(args)

	switch {
	case len(args) == 0:
		// Bare `bin` launches the interactive TUI on a real terminal, and
		// falls back to `list` when output is piped/redirected.
		if isInteractive() {
			cmd.cmd.SetArgs([]string{"tui"})
		} else {
			cmd.cmd.SetArgs([]string{"list"})
		}
	case defaultCommand(cmd.cmd, args):
		cmd.cmd.SetArgs(append([]string{"list"}, args...))
	}

	if err := cmd.cmd.Execute(); err != nil {
		code := 1
		msg := "command failed"
		if eerr, ok := err.(*exitError); ok {
			code = eerr.code
			if eerr.details != "" {
				msg = eerr.details
			}
		}
		log.WithError(err).Error(msg)
		cmd.exit(code)
	}
}

type rootCmd struct {
	cmd         *cobra.Command
	debug       bool
	tags        []string
	configFile  string
	stateFile   string
	defaultPath string
	exit        func(int)
}

// activeTags holds the value of the persistent --tag flag for the current
// invocation. Empty means "default".
var activeTags []string

// wantedTags returns the tags to act on, defaulting to "default".
func wantedTags() []string {
	if len(activeTags) == 0 {
		return []string{"default"}
	}
	return activeTags
}

// tagFilterAll reports whether the user asked for every binary regardless of
// tag (via --tag all).
func tagFilterAll() bool {
	for _, t := range activeTags {
		if t == "all" {
			return true
		}
	}
	return false
}

// binTags returns a binary's tags, treating an untagged binary as "default".
func binTags(b *config.Binary) []string {
	if len(b.Tags) == 0 {
		return []string{"default"}
	}
	return b.Tags
}

// binHasAnyTag reports whether b carries at least one of the given tags.
func binHasAnyTag(b *config.Binary, tags []string) bool {
	for _, want := range tags {
		for _, have := range binTags(b) {
			if have == want {
				return true
			}
		}
	}
	return false
}

// selectByTag returns the subset of cfg.Bins matching the active tag filter.
func selectByTag(bins map[string]*config.Binary) map[string]*config.Binary {
	if tagFilterAll() {
		return bins
	}
	want := wantedTags()
	out := map[string]*config.Binary{}
	for k, b := range bins {
		if b != nil && binHasAnyTag(b, want) {
			out[k] = b
		}
	}
	return out
}

func newRootCmd(version string, exit func(int)) *rootCmd {
	root := &rootCmd{
		exit: exit,
	}
	cmd := &cobra.Command{
		Use:           "bin",
		Short:         "Effortless binary manager",
		Version:       version,
		SilenceUsage:  true,
		SilenceErrors: true,
		PersistentPreRun: func(cmd *cobra.Command, args []string) {
			if root.debug {
				log.SetLevel(log.DebugLevel)
				log.Debugf("debug logs enabled, version: %s\n", version)
			}

			activeTags = root.tags
			config.SetPathOverrides(config.PathOverrides{
				ConfigFile: root.configFile,
				StateFile:  root.stateFile,
				DefaultDir: root.defaultPath,
			})

			// check and load config after handlers are configured
			err := config.CheckAndLoad()
			if err != nil {
				log.Fatalf("Error loading config file %v", err)
			}

			// Load (or create) the TUI color theme from the config file.
			ui.EnsureTheme(filepath.Join(config.ConfigDir(), "config"))
		},
	}

	cmd.PersistentFlags().BoolVar(&root.debug, "debug", false, "Enable debug mode")
	cmd.PersistentFlags().StringSliceVarP(&root.tags, "tag", "t", nil, "Tag context: which tier to act on (default \"default\", \"all\" for every binary)")
	cmd.PersistentFlags().StringVar(&root.configFile, "config-file", "", "Path to bin manifest (env BIN_CONFIG_FILE)")
	cmd.PersistentFlags().StringVar(&root.stateFile, "state-file", "", "Path to mutable state file (env BIN_STATE_FILE)")
	cmd.PersistentFlags().StringVar(&root.defaultPath, "default-path", "", "Default install directory (env BIN_DEFAULT_PATH)")
	cmd.AddCommand(
		newInstallCmd().cmd,
		newEnsureCmd().cmd,
		newUpdateCmd().cmd,
		newPinCmd().cmd,
		newUnpinCmd().cmd,
		newRemoveCmd().cmd,
		newApplyCmd().cmd,
		newListCmd().cmd,
		newPruneCmd().cmd,
		newTagCmd().cmd,
		newDescribeCmd().cmd,
		newAICmd().cmd,
		newTuiCmd().cmd,
	)

	cobra.AddTemplateFunc("hdr", func(s string) string { return ui.AccentStyle.Render(s) })
	cobra.AddTemplateFunc("cmdName", func(s string) string { return ui.TagStyle.Render(s) })
	cobra.AddTemplateFunc("muted", func(s string) string { return ui.MutedStyle.Render(s) })
	cmd.SetUsageTemplate(usageTemplate)

	root.cmd = cmd
	return root
}

// usageTemplate is a colorized version of cobra's default usage template.
const usageTemplate = `{{hdr "Usage:"}}{{if .Runnable}}
  {{.UseLine}}{{end}}{{if .HasAvailableSubCommands}}
  {{.CommandPath}} [command]{{end}}{{if gt (len .Aliases) 0}}

{{hdr "Aliases:"}}
  {{.NameAndAliases}}{{end}}{{if .HasExample}}

{{hdr "Examples:"}}
{{.Example}}{{end}}{{if .HasAvailableSubCommands}}

{{hdr "Available Commands:"}}{{range .Commands}}{{if (or .IsAvailableCommand (eq .Name "help"))}}
  {{rpad .Name .NamePadding | cmdName}} {{.Short | muted}}{{end}}{{end}}{{end}}{{if .HasAvailableLocalFlags}}

{{hdr "Flags:"}}
{{.LocalFlags.FlagUsages | trimTrailingWhitespaces}}{{end}}{{if .HasAvailableInheritedFlags}}

{{hdr "Global Flags:"}}
{{.InheritedFlags.FlagUsages | trimTrailingWhitespaces}}{{end}}{{if .HasHelpSubCommands}}

{{hdr "Additional help topics:"}}{{range .Commands}}{{if .IsAdditionalHelpTopicCommand}}
  {{rpad .CommandPath .CommandPathPadding | cmdName}} {{.Short | muted}}{{end}}{{end}}{{end}}{{if .HasAvailableSubCommands}}

{{muted "Use"}} "{{.CommandPath}} [command] --help" {{muted "for more information about a command."}}{{end}}
`

// isInteractive reports whether we're attached to a real terminal on both
// stdin and stdout, so it's safe to launch the full-screen TUI.
func isInteractive() bool {
	return isatty.IsTerminal(os.Stdout.Fd()) && isatty.IsTerminal(os.Stdin.Fd())
}

func defaultCommand(cmd *cobra.Command, args []string) bool {
	// find current cmd, if its not root, it means the user actively
	// set a command, so let it go
	xmd, _, _ := cmd.Find(args)
	if xmd != cmd {
		return false
	}

	// special case for cobra's default completion command
	// ref: https://github.com/kubernetes/kubectl/blob/04af20f5a9d2b56d910a36fec84f21164df65d32/pkg/cmd/cmd.go#L132
	if len(args) > 0 &&
		(args[0] == "completion" ||
			args[0] == cobra.ShellCompRequestCmd ||
			args[0] == cobra.ShellCompNoDescRequestCmd) {
		return false
	}

	// if we have == 0 args, assume its a ls
	if len(args) == 0 {
		return true
	}

	// given that its 1, check if its one of the valid standalone flags
	// for the root cmd
	for _, s := range []string{"-h", "--help", "-v", "--version", "help"} {
		if s == args[0] {
			// if it is, we should run the root cmd
			return false
		}
	}

	// otherwise, we should probably prepend ls
	return true
}

func getBinPath(name string) (string, error) {
	var f string
	f, err := exec.LookPath(name)
	cfg := config.Get()
	if err != nil {
		log.Log.Debugf("binary %s not found in PATH %v", name, err)
		if !strings.Contains(name, "/") {
			for _, b := range cfg.Bins {
				if filepath.Base(b.Path) == name {
					return b.Path, nil
				}
			}
		}
		return "", err
	}

	for _, bin := range cfg.Bins {
		if os.ExpandEnv(bin.Path) == f {
			return bin.Path, nil
		}
	}

	return "", fmt.Errorf("binary path %s not found", f)
}
