package cmd

import (
	"crypto/sha256"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/bresilla/geto/src/pkg/assets"
	"github.com/bresilla/geto/src/pkg/elfpatch"
	"github.com/caarlos0/log"
)

// hostLoader returns the host system's dynamic loader path or an empty string.
func hostLoader() string {
	for _, ref := range []string{
		"/bin/sh", "/usr/bin/env", "/bin/ls", "/usr/bin/ls",
	} {
		if interp, err := elfpatch.Interpreter(ref); err == nil && interp != "" {
			if _, e := os.Stat(interp); e == nil {
				return interp
			}
		}
	}
	return ""
}

// patchForHost rewrites the ELF interpreter of the binary at path to match hostLoader.
func patchForHost(path string) (bool, error) {
	cur, err := elfpatch.Interpreter(path)
	if err != nil {
		return false, nil
	}
	if _, err := os.Stat(cur); err == nil {
		return false, nil
	}
	loader := hostLoader()
	if loader == "" {
		log.Warn("could not determine host dynamic loader; skipping patch")
		return false, nil
	}
	if cur == loader {
		return false, nil
	}
	if err := elfpatch.SetInterpreter(path, loader); err != nil {
		return false, err
	}
	log.Infof("patched interpreter: %s → %s", cur, loader)
	return true, nil
}

// applyHostPatches rewrites the interpreter and installs missing library sidecars for path.
func applyHostPatches(path string, libs map[string]*assets.Sidecar, want bool, currentHash []byte) ([]byte, bool) {
	if !want {
		return currentHash, false
	}
	epath := os.ExpandEnv(path)
	changed := false

	if c, err := patchForHost(epath); err != nil {
		log.Warnf("interpreter patch failed: %v", err)
	} else if c {
		changed = true
	}

	if c, err := makeRunnable(epath, libs); err != nil {
		log.Warnf("library resolution failed: %v", err)
	} else if c {
		changed = true
	}

	if changed {
		if h, err := hashFile(epath); err == nil {
			return h, true
		}
	}
	return currentHash, changed
}

// makeRunnable installs missing archive sidecar libraries and updates DT_RUNPATH.
func makeRunnable(binPath string, libs map[string]*assets.Sidecar) (bool, error) {
	missing := missingLibs(binPath)
	if len(missing) == 0 {
		return false, nil
	}

	var extraDirs []string
	seen := map[string]bool{}
	add := func(d string) {
		if d != "" && !seen[d] {
			seen[d] = true
			extraDirs = append(extraDirs, d)
		}
	}

	// 1. libraries bundled in the archive -> install next to the binary
	archiveHas := false
	for _, m := range missing {
		if libs[m] != nil {
			archiveHas = true
			break
		}
	}
	if archiveHas {
		libDir := filepath.Clean(filepath.Join(filepath.Dir(binPath), "..", "lib", filepath.Base(binPath)))
		if err := writeSidecars(libDir, libs); err != nil {
			return false, err
		}
		add(libDir)
		log.Infof("installed %d bundled libs → %s", len(libs), libDir)
	}

	// 2. system libraries not in the archive -> locate them on the host
	for _, m := range missing {
		if libs[m] != nil {
			continue // handled above
		}
		if d := findSystemLibDir(m); d != "" {
			add(d)
			log.Infof("resolved %s in %s", m, d)
		}
	}

	if len(extraDirs) == 0 {
		log.Warnf("%s missing (couldn't locate): %s", filepath.Base(binPath), strings.Join(missing, ", "))
		return false, nil
	}

	// 3. add all the directories to RUNPATH in one shot
	newRP := strings.Join(extraDirs, ":")
	if cur, _ := elfpatch.Runpath(binPath); len(cur) > 0 && cur[0] != "" {
		newRP = cur[0] + ":" + newRP
	}
	if err := elfpatch.SetRunpath(binPath, newRP); err != nil {
		return false, err
	}

	if still := missingLibs(binPath); len(still) > 0 {
		log.Warnf("%s still missing (not found): %s", filepath.Base(binPath), strings.Join(still, ", "))
	} else {
		log.Infof("%s: all libraries resolved", filepath.Base(binPath))
	}
	return true, nil
}

// writeSidecars writes the archive's shared-library closure into dir, recreating
// symlinks.
func writeSidecars(dir string, libs map[string]*assets.Sidecar) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	for name, sc := range libs {
		dst := filepath.Join(dir, name)
		_ = os.Remove(dst)
		if sc.Link != "" {
			if err := os.Symlink(sc.Link, dst); err != nil {
				return err
			}
			continue
		}
		if err := os.WriteFile(dst, sc.Data, 0o755); err != nil {
			return err
		}
	}
	return nil
}

// findSystemLibDir locates a directory containing the named shared library in
// the host's standard library search paths (env, ld.so.conf, defaults like
// /usr/lib/x86_64-linux-gnu). Returns "" if not found — install the providing
// package with your system package manager.
func findSystemLibDir(name string) string {
	for _, d := range systemLibDirs() {
		if d == "" {
			continue
		}
		if fi, err := os.Stat(filepath.Join(d, name)); err == nil && !fi.IsDir() {
			return d
		}
	}
	return ""
}

func hashFile(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return nil, err
	}
	return h.Sum(nil), nil
}
