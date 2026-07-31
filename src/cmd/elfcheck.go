package cmd

import (
	"bufio"
	"debug/elf"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/caarlos0/log"
)

// missingLibs returns the NEEDED shared libraries of an ELF binary that can't be
// resolved through the standard dynamic-linker search paths. It replicates
// glibc's lookup order in pure Go — no ldd, no executing the binary.
func missingLibs(path string) []string {
	if runtime.GOOS != "linux" {
		return nil
	}
	ef, err := elf.Open(path)
	if err != nil {
		return nil // not an ELF (e.g. a Windows build) or unreadable
	}
	defer ef.Close()

	needed, err := ef.ImportedLibraries()
	if err != nil || len(needed) == 0 {
		return nil // statically linked or no dynamic deps
	}

	origin := filepath.Dir(path)
	expand := func(p string) string {
		p = strings.ReplaceAll(p, "${ORIGIN}", origin)
		return strings.ReplaceAll(p, "$ORIGIN", origin)
	}
	split := func(s string) []string {
		var out []string
		for _, p := range strings.Split(s, ":") {
			if p = strings.TrimSpace(p); p != "" {
				out = append(out, expand(p))
			}
		}
		return out
	}

	runpath, _ := ef.DynString(elf.DT_RUNPATH)
	rpath, _ := ef.DynString(elf.DT_RPATH)

	var dirs []string
	// DT_RPATH is only consulted by glibc when DT_RUNPATH is absent.
	if len(runpath) == 0 {
		for _, r := range rpath {
			dirs = append(dirs, split(r)...)
		}
	}
	for _, r := range runpath {
		dirs = append(dirs, split(r)...)
	}
	dirs = append(dirs, systemLibDirs()...)

	var missing []string
	for _, lib := range needed {
		if !libFound(lib, dirs) {
			missing = append(missing, lib)
		}
	}
	return missing
}

// systemLibDirs returns the host's library search directories that aren't
// specific to a particular binary (env vars, ld.so.conf, and the defaults).
func systemLibDirs() []string {
	var dirs []string
	for _, p := range strings.Split(os.Getenv("LD_LIBRARY_PATH"), ":") {
		if p = strings.TrimSpace(p); p != "" {
			dirs = append(dirs, p)
		}
	}
	dirs = append(dirs, ldSoConfDirs("/etc/ld.so.conf", map[string]bool{})...)
	dirs = append(dirs,
		"/lib", "/usr/lib", "/lib64", "/usr/lib64",
		"/lib/x86_64-linux-gnu", "/usr/lib/x86_64-linux-gnu",
		"/lib/aarch64-linux-gnu", "/usr/lib/aarch64-linux-gnu",
	)
	return dirs
}

func libFound(lib string, dirs []string) bool {
	for _, d := range dirs {
		if d == "" {
			continue
		}
		if fi, err := os.Stat(filepath.Join(d, lib)); err == nil && !fi.IsDir() {
			return true
		}
	}
	return false
}

// ldSoConfDirs reads library directories from /etc/ld.so.conf and its includes
// (the text source the binary ld.so.cache is built from).
func ldSoConfDirs(path string, seen map[string]bool) []string {
	if seen[path] {
		return nil
	}
	seen[path] = true

	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	var dirs []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if rest, ok := strings.CutPrefix(line, "include "); ok {
			matches, _ := filepath.Glob(strings.TrimSpace(rest))
			for _, m := range matches {
				dirs = append(dirs, ldSoConfDirs(m, seen)...)
			}
			continue
		}
		dirs = append(dirs, line)
	}
	return dirs
}

// warnMissingLibs prints a warning when an installed binary has shared-library
// dependencies that aren't resolvable on this system.
func warnMissingLibs(path string) {
	miss := missingLibs(path)
	if len(miss) == 0 {
		return
	}
	log.Warnf("%s needs shared libraries not found on your system: %s",
		filepath.Base(path), strings.Join(miss, ", "))
	log.Warn("the release may bundle these (re-extract the full archive), or install them with your system package manager")
}
