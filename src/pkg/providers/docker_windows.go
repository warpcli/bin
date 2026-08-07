package providers

import "strings"

const (
	// TODO: support custom mount templates and network options.
	sh = `@echo off
docker run --rm -i -t -v %%cd%%:/tmp/cmd -w /tmp/cmd %s:%s %%*
`
)

// getImageName returns the image name component from repo.
func getImageName(repo string) string {
	image := strings.Split(repo, "/")
	return image[len(image)-1] + ".cmd"
}
