package cmd

import (
	"fmt"

	"github.com/bresilla/geto/src/pkg/ui"
)

// sep prints a full-width separator line.
func sep() { fmt.Println(ui.Rule()) }

// stepHeader prints a styled action header.
func stepHeader(name, detail string) {
	fmt.Printf("%s %s  %s\n",
		ui.AccentStyle.Render("▸"),
		ui.AccentStyle.Render(name),
		ui.MutedStyle.Render(detail),
	)
}

// stepDone prints a styled success indicator for a completed action.
func stepDone(verb, name, version string) {
	fmt.Printf("  %s %s %s %s\n",
		ui.OKStyle.Render("✓"),
		ui.MutedStyle.Render(verb),
		name,
		ui.AccentStyle.Render(version),
	)
}
