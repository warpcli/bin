package elfpatch

import (
	"debug/elf"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func readInterp(t *testing.T, p string) string {
	t.Helper()
	f, err := elf.Open(p)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	for _, pr := range f.Progs {
		if pr.Type == elf.PT_INTERP {
			b := make([]byte, pr.Filesz)
			_, _ = pr.ReadAt(b, 0)
			return strings.TrimRight(string(b), "\x00")
		}
	}
	return ""
}

func copyFile(t *testing.T, src, dst string) {
	t.Helper()
	in, err := os.Open(src)
	if err != nil {
		t.Fatal(err)
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.Copy(out, in); err != nil {
		t.Fatal(err)
	}
	out.Close()
}

func findDynamicELF() string {
	for _, c := range []string{"/bin/cat", "/usr/bin/cat", "/bin/true", "/usr/bin/env"} {
		if f, err := elf.Open(c); err == nil {
			for _, pr := range f.Progs {
				if pr.Type == elf.PT_INTERP {
					f.Close()
					return c
				}
			}
			f.Close()
		}
	}
	return ""
}

func TestSetInterpreterInPlace(t *testing.T) {
	src := findDynamicELF()
	if src == "" {
		t.Skip("no dynamically-linked ELF found to test against")
	}
	dst := t.TempDir() + "/copy"
	copyFile(t, src, dst)

	if err := SetInterpreter(dst, "/x/ld.so"); err != nil {
		t.Fatalf("SetInterpreter: %v", err)
	}
	if got := readInterp(t, dst); got != "/x/ld.so" {
		t.Fatalf("interp = %q, want /x/ld.so", got)
	}
	// must remain a parseable ELF
	if f, err := elf.Open(dst); err != nil {
		t.Fatalf("patched file is no longer a valid ELF: %v", err)
	} else {
		f.Close()
	}

	// a longer value is now handled by the grow path (append at EOF).
	long := "/" + strings.Repeat("a", 200)
	if err := SetInterpreter(dst, long); err != nil {
		t.Fatalf("grow SetInterpreter: %v", err)
	}
	if got, _ := Interpreter(dst); got != long {
		t.Fatalf("after grow interp = %q, want %q", got, long)
	}
	if f, err := elf.Open(dst); err != nil {
		t.Fatalf("grown file no longer valid ELF: %v", err)
	} else {
		f.Close()
	}
}

func TestSetInterpreterGrowAndExec(t *testing.T) {
	src := findDynamicELF()
	if src == "" {
		t.Skip("no dynamic ELF found")
	}
	interp, err := Interpreter(src)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(interp); err != nil {
		t.Skipf("loader %q not present, can't exec-test", interp)
	}

	dir := t.TempDir()
	longdir := dir + "/" + strings.Repeat("x", 48)
	if err := os.MkdirAll(longdir, 0o755); err != nil {
		t.Fatal(err)
	}
	longld := longdir + "/ld.so" // a much longer path -> forces the grow path
	if err := os.Symlink(interp, longld); err != nil {
		t.Fatal(err)
	}
	if len(longld) <= len(interp) {
		t.Skip("symlink not longer than original interp")
	}

	cp := filepath.Join(dir, filepath.Base(src))
	copyFile(t, src, cp)
	_ = os.Chmod(cp, 0o755)

	if err := SetInterpreter(cp, longld); err != nil {
		t.Fatalf("SetInterpreter(grow): %v", err)
	}
	if got, _ := Interpreter(cp); got != longld {
		t.Fatalf("interp = %q, want %q", got, longld)
	}
	// the real proof: the patched binary still executes via the new interpreter
	out, err := exec.Command(cp, "--version").CombinedOutput()
	if err != nil {
		t.Fatalf("patched binary failed to run: %v\n%s", err, out)
	}
	t.Logf("grow-patched binary ran OK: %s", strings.SplitN(string(out), "\n", 2)[0])
}

func TestSetRunpathGrowAndExec(t *testing.T) {
	src := findDynamicELF()
	if src == "" {
		t.Skip("no dynamic ELF found")
	}
	interp, err := Interpreter(src)
	if err != nil || interp == "" {
		t.Skip("no interpreter")
	}
	if _, err := os.Stat(interp); err != nil {
		t.Skipf("loader %q absent", interp)
	}

	dir := t.TempDir()
	cp := filepath.Join(dir, filepath.Base(src))
	copyFile(t, src, cp)
	_ = os.Chmod(cp, 0o755)

	// a long rpath that won't fit any existing slot -> forces the grow path
	want := "/opt/" + strings.Repeat("z", 300) + "/lib"
	if err := SetRunpath(cp, want); err != nil {
		t.Fatalf("SetRunpath(grow): %v", err)
	}
	// read back via debug/elf (proves DT_STRTAB + .dynstr section are consistent)
	got, err := Runpath(cp)
	if err != nil || len(got) == 0 || got[0] != want {
		t.Fatalf("Runpath after grow = %v (err %v), want %q", got, err, want)
	}
	// still a valid ELF and still runs
	if f, e := elf.Open(cp); e != nil {
		t.Fatalf("grown file invalid: %v", e)
	} else {
		f.Close()
	}
	out, err := exec.Command(cp, "--version").CombinedOutput()
	if err != nil {
		t.Fatalf("rpath-grown binary failed to run: %v\n%s", err, out)
	}
	t.Logf("rpath grow OK, runpath=%q, ran: %s", got[0][:12]+"…", strings.SplitN(string(out), "\n", 2)[0])
}
