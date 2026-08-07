//go:build !windows

package providers

import "strings"

const (
	// TODO: support custom mount templates and network options.
	sh = `#!/bin/sh
	termflag=$([ -t 0 ] && echo -n "-t")
	docker run --rm -i $termflag -v ${PWD}:/tmp/cmd -w /tmp/cmd %s:%s "$@"`
)

// getImageName returns the image name component from repo.
func getImageName(repo string) string {
	image := strings.Split(repo, "/")
	return image[len(image)-1]
}
