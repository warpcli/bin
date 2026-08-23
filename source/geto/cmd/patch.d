module geto.cmd.patch;

import std.array : join;
import std.conv : octal;
import std.digest.sha : SHA256, digest;
import std.file : exists, isDir, mkdirRecurse, read, remove, setAttributes, symlink, write;
import std.path : baseName, buildNormalizedPath, buildPath, dirName;

import geto.assets : Sidecar;
import geto.cmd.elfcheck : missingLibs, systemLibDirs;
import geto.elf : interpreter, runpath, setInterpreter, setRunpath;
import geto.log;
import geto.util : expandEnv;

/// The host's dynamic loader path, or "" when it cannot be determined.
string hostLoader()
{
    foreach (reference; ["/bin/sh", "/usr/bin/env", "/bin/ls", "/usr/bin/ls"])
    {
        if (!reference.exists)
            continue;
        try
        {
            const interp = interpreter(reference);
            if (interp.length > 0 && interp.exists)
                return interp;
        }
        catch (Exception)
        {
        }
    }
    return "";
}

/// Rewrites the ELF interpreter to match the host when the current one is missing.
bool patchForHost(string path)
{
    string current;
    try
        current = interpreter(path);
    catch (Exception)
        return false;

    if (current.exists)
        return false;

    const loader = hostLoader();
    if (loader.length == 0)
    {
        warn("could not determine host dynamic loader; skipping patch");
        return false;
    }
    if (current == loader)
        return false;

    setInterpreter(path, loader);
    infof("patched interpreter: %s → %s", current, loader);
    return true;
}

/// Applies interpreter and library fixes, returning the resulting hash.
ubyte[] applyHostPatches(string path, Sidecar[string] libs, bool wanted,
    ubyte[] currentHash, out bool changed)
{
    changed = false;
    if (!wanted)
        return currentHash;

    const target = expandEnv(path);

    try
    {
        if (patchForHost(target))
            changed = true;
    }
    catch (Exception failure)
        warnf("interpreter patch failed: %s", failure.msg);

    try
    {
        if (makeRunnable(target, libs))
            changed = true;
    }
    catch (Exception failure)
        warnf("library resolution failed: %s", failure.msg);

    if (changed)
    {
        try
            return digest!SHA256(cast(const(ubyte)[]) read(target)).dup;
        catch (Exception)
        {
        }
    }
    return currentHash;
}

/// Installs missing bundled libraries and points DT_RUNPATH at them.
bool makeRunnable(string binaryPath, Sidecar[string] libs)
{
    auto missing = missingLibs(binaryPath);
    if (missing.length == 0)
        return false;

    string[] extraDirs;
    bool[string] seen;

    void addDir(string dir)
    {
        if (dir.length > 0 && dir !in seen)
        {
            seen[dir] = true;
            extraDirs ~= dir;
        }
    }

    // Libraries bundled in the archive are installed next to the binary.
    bool archiveHas = false;
    foreach (name; missing)
        if (name in libs)
        {
            archiveHas = true;
            break;
        }
    if (archiveHas)
    {
        const libDir = buildNormalizedPath(buildPath(binaryPath.dirName, "..", "lib",
                binaryPath.baseName));
        writeSidecars(libDir, libs);
        addDir(libDir);
        infof("installed %d bundled libs → %s", libs.length, libDir);
    }

    // Anything the archive does not ship is looked up on the host.
    foreach (name; missing)
    {
        if (name in libs)
            continue;
        const dir = findSystemLibDir(name);
        if (dir.length > 0)
        {
            addDir(dir);
            infof("resolved %s in %s", name, dir);
        }
    }

    if (extraDirs.length == 0)
    {
        warnf("%s missing (couldn't locate): %s", binaryPath.baseName, missing.join(", "));
        return false;
    }

    auto combined = extraDirs.join(":");
    auto current = runpath(binaryPath);
    if (current.length > 0 && current[0].length > 0)
        combined = current[0] ~ ":" ~ combined;
    setRunpath(binaryPath, combined);

    auto still = missingLibs(binaryPath);
    if (still.length > 0)
        warnf("%s still missing (not found): %s", binaryPath.baseName, still.join(", "));
    else
        infof("%s: all libraries resolved", binaryPath.baseName);
    return true;
}

/// Writes the archive's shared-library closure into `dir`, recreating symlinks.
void writeSidecars(string dir, Sidecar[string] libs)
{
    mkdirRecurse(dir);
    foreach (name, sidecar; libs)
    {
        const target = buildPath(dir, name);
        if (target.exists)
            remove(target);
        if (sidecar.link.length > 0)
        {
            symlink(sidecar.link, target);
            continue;
        }
        write(target, sidecar.data);
        setAttributes(target, octal!"755");
    }
}

/// Locates a directory on the host containing the named shared library.
string findSystemLibDir(string name)
{
    foreach (dir; systemLibDirs())
    {
        if (dir.length == 0)
            continue;
        const candidate = buildPath(dir, name);
        if (candidate.exists && !candidate.isDir)
            return dir;
    }
    return "";
}
