package prompt

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/bresilla/bin/src/pkg/ui"
	"golang.org/x/term"
)

var stdin io.Reader = os.Stdin

// Confirm prompts for user confirmation.
func Confirm(message string) error {
	if term.IsTerminal(int(os.Stdin.Fd())) && term.IsTerminal(int(os.Stdout.Fd())) {
		ok, err := ui.Confirm(message, true)
		if err != nil {
			return err
		}
		if !ok {
			return fmt.Errorf("command aborted")
		}
		return nil
	}

	fmt.Printf("\n%s [Y/n] ", message)
	reader := bufio.NewReader(stdin)
	response, err := reader.ReadString('\n')
	if err != nil {
		return fmt.Errorf("invalid input")
	}
	switch strings.ToLower(strings.TrimSpace(response)) {
	case "", "y", "yes":
	default:
		return fmt.Errorf("command aborted")
	}
	return nil
}
