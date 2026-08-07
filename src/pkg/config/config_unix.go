//go:build !windows

package config

import (
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/bresilla/bin/src/pkg/options"
	"github.com/caarlos0/log"
	"golang.org/x/sys/unix"
)

// getDefaultPath returns a writable directory from PATH.
// TODO: support selecting from multiple valid PATH entries.
func getDefaultPath() (string, error) {
	penv := os.Getenv("PATH")
	log.Debugf("User PATH is [%s]", penv)
	opts := map[fmt.Stringer]struct{}{}
	for _, p := range strings.Split(penv, ":") {
		log.Debugf("Checking path %s", p)

		err := checkDirExistsAndWritable(p)
		if err != nil {
			log.Debugf("Error [%s] checking path", err)
			continue
		}

		log.Debugf("%s seems to be a dir and writable, adding option.", p)
		opts[options.LiteralStringer(p)] = struct{}{}

	}

	// TODO: move path selection logic to config.go.
	if len(opts) == 0 {
		return "", errors.New("Automatic path detection didn't return any results")
	}

	sopts := []fmt.Stringer{}
	for k := range opts {
		sopts = append(sopts, k)
	}

	choice, err := options.SelectCustom("Pick a default download dir: ", sopts)
	if err != nil {
		return "", err
	}
	return choice.(fmt.Stringer).String(), nil
}

func checkDirExistsAndWritable(dir string) error {
	if fi, err := os.Stat(dir); err != nil {
		return fmt.Errorf("Error setting download path [%w]", err)
	} else if !fi.IsDir() {
		return errors.New("Download path is not a directory")
	}
	// TODO: support non-Unix platforms in checkDirExistsAndWritable.
	err := unix.Access(dir, unix.W_OK)
	return err
}
