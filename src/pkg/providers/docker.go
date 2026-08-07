package providers

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/caarlos0/log"
	"github.com/docker/docker/api/types/image"
	"github.com/docker/docker/client"
	"github.com/docker/docker/pkg/jsonmessage"
)

type docker struct {
	client    *client.Client
	repo, tag string
}

func (d *docker) Fetch(opts *FetchOpts) (*File, error) {
	if len(opts.Version) > 0 {
		d.tag = opts.Version
	}
	log.Infof("Pulling docker image %s:%s", d.repo, d.tag)
	out, err := d.client.ImageCreate(context.Background(), fmt.Sprintf("%s:%s", d.repo, d.tag), image.CreateOptions{})
	if err != nil {
		return nil, err
	}
	defer out.Close()

	err = jsonmessage.DisplayJSONMessagesStream(
		out,
		os.Stderr,
		os.Stdout.Fd(),
		false,
		nil)
	if err != nil {
		return nil, err
	}

	return &File{
		Data:    strings.NewReader(fmt.Sprintf(sh, d.repo, d.tag)),
		Name:    getImageName(d.repo),
		Version: d.tag,
	}, nil
}

// TODO: fetch latest image tag from registry.
func (d *docker) GetLatestVersion() (string, string, error) {
	return d.tag, "", nil
}

func (d *docker) GetID() string {
	return "docker"
}

func newDocker(imageURL string) (Provider, error) {
	imageURL = strings.TrimPrefix(imageURL, "docker://")

	repo, tag := parseImage(imageURL)

	c, err := client.NewClientWithOpts(client.FromEnv)
	if err != nil {
		return nil, err
	}

	return &docker{repo: repo, tag: tag, client: c}, nil
}

// parseImage returns the repository and tag from imageURL.
func parseImage(imageURL string) (string, string) {
	image := imageURL
	tag := "latest"
	if i := strings.LastIndex(imageURL, ":"); i > -1 {
		image = imageURL[:i]
		tag = imageURL[i+1:]
	}

	if strings.Count(imageURL, "/") == 0 {
		image = "library/" + image
	}

	return image, tag
}
