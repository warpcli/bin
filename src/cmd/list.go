package cmd

import (
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/bresilla/geto/src/pkg/config"
	"github.com/bresilla/geto/src/pkg/ui"
	"github.com/spf13/cobra"
)

type listCmd struct {
	cmd *cobra.Command
}

func newListCmd() *listCmd {
	root := &listCmd{}
	// nolint: dupl
	cmd := &cobra.Command{
		Use:           "list",
		Aliases:       []string{"ls", "l"},
		Short:         "List binaries managed by geto",
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg := config.Get()
			bins := selectByTag(cfg.Bins)

			binPaths := make([]string, 0, len(bins))
			for k := range bins {
				binPaths = append(binPaths, k)
			}
			sort.Strings(binPaths)

			rows := make([]ui.ListRow, 0, len(binPaths))
			for _, k := range binPaths {
				b := bins[k]
				p := os.ExpandEnv(b.Path)
				_, statErr := os.Stat(p)
				rows = append(rows, ui.ListRow{
					Path:    p,
					Version: b.Version,
					Tags:    binTags(b),
					URL:     b.URL,
					OK:      statErr == nil,
					Pinned:  b.Pinned,
				})
			}

			scope := "default"
			if tagFilterAll() {
				scope = "all"
			} else {
				scope = strings.Join(wantedTags(), ",")
			}
			fmt.Printf("\n%s  %s\n\n",
				ui.Banner(" bin "),
				ui.MutedStyle.Render(fmt.Sprintf("%d binaries · tag: %s", len(rows), scope)),
			)

			if len(rows) == 0 {
				fmt.Printf("%s\n\n", ui.MutedStyle.Render("nothing here — try a different --tag, or `bin install <url>`"))
				return nil
			}

			fmt.Println(ui.ListTable(rows, ui.TerminalWidth()))
			fmt.Println()
			return nil
		},
	}

	root.cmd = cmd
	return root
}
