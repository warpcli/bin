module geto.cmd.elfcheck;

import std.array : array, join, replace, split;
import std.file : DirEntry, exists, isDir, read, readText;
import std.path : baseName, buildPath, dirName, globMatch;
import std.process : environment;
import std.string : startsWith, strip;

import geto.elf : importedLibraries, looksLikeElf;
import geto.log;

/// Shared libraries the binary needs that cannot be resolved on this host.
string[] missingLibs(string path)
{
    version (linux)
    {
    }
    else
        return null;

    if (!path.exists)
        return null;

    ubyte[] data;
    try
        data = cast(ubyte[]) read(path);
    catch (Exception)
        return null;
    if (!looksLikeElf(data))
        return null;

    auto needed = importedLibraries(data);
    if (needed.length == 0)
        return null;

    const origin = path.dirName;

    string expand(string text)
    {
        return text.replace("${ORIGIN}", origin).replace("$ORIGIN", origin);
    }

    string[] splitPaths(string text)
    {
        string[] result;
        foreach (piece; text.split(':'))
        {
            const trimmed = piece.strip;
            if (trimmed.length > 0)
                result ~= expand(trimmed);
        }
        return result;
    }

    auto runpath = dynamicStringsOf(data, dtRunpath);
    auto rpath = dynamicStringsOf(data, dtRpath);

    string[] dirs;
    // DT_RPATH applies only when DT_RUNPATH is absent.
    if (runpath.length == 0)
        foreach (entry; rpath)
            dirs ~= splitPaths(entry);
    foreach (entry; runpath)
        dirs ~= splitPaths(entry);
    dirs ~= systemLibDirs();

    string[] missing;
    foreach (lib; needed)
        if (!libFound(lib, dirs))
            missing ~= lib;
    return missing;
}

private enum ulong dtRpath = 15;
private enum ulong dtRunpath = 29;

private string[] dynamicStringsOf(const(ubyte)[] data, ulong tag)
{
    import geto.elf : ElfImage;

    try
    {
        auto image = ElfImage.fromBuffer(cast(ubyte[]) data.dup);
        return image.dynamicStrings(tag);
    }
    catch (Exception)
        return null;
}

/// Host library search directories: environment, ld.so.conf, then defaults.
string[] systemLibDirs()
{
    string[] dirs;
    foreach (piece; environment.get("LD_LIBRARY_PATH", "").split(':'))
    {
        const trimmed = piece.strip;
        if (trimmed.length > 0)
            dirs ~= trimmed;
    }

    bool[string] seen;
    dirs ~= ldSoConfDirs("/etc/ld.so.conf", seen);
    dirs ~= [
        "/lib", "/usr/lib", "/lib64", "/usr/lib64",
        "/lib/x86_64-linux-gnu", "/usr/lib/x86_64-linux-gnu",
        "/lib/aarch64-linux-gnu", "/usr/lib/aarch64-linux-gnu",
    ];
    return dirs;
}

private bool libFound(string lib, const string[] dirs)
{
    foreach (dir; dirs)
    {
        if (dir.length == 0)
            continue;
        const candidate = buildPath(dir, lib);
        if (candidate.exists && !candidate.isDir)
            return true;
    }
    return false;
}

/// Reads library directories from an ld.so.conf file and its includes.
private string[] ldSoConfDirs(string path, ref bool[string] seen)
{
    import std.file : dirEntries, SpanMode;
    import std.string : splitLines;

    if (path in seen)
        return null;
    seen[path] = true;
    if (!path.exists)
        return null;

    string text;
    try
        text = readText(path);
    catch (Exception)
        return null;

    string[] dirs;
    foreach (raw; text.splitLines)
    {
        const line = raw.strip;
        if (line.length == 0 || line.startsWith("#"))
            continue;
        if (line.startsWith("include "))
        {
            const pattern = line["include ".length .. $].strip;
            foreach (match; expandGlob(pattern))
                dirs ~= ldSoConfDirs(match, seen);
            continue;
        }
        dirs ~= line;
    }
    return dirs;
}

private string[] expandGlob(string pattern)
{
    import std.file : dirEntries, SpanMode;

    const dir = pattern.dirName;
    const mask = pattern.baseName;
    if (!dir.exists || !dir.isDir)
        return null;

    string[] matches;
    try
        foreach (DirEntry entry; dirEntries(dir, SpanMode.shallow))
            if (entry.name.baseName.globMatch(mask))
                matches ~= entry.name;
    catch (Exception)
        return null;
    return matches;
}

/// Warns when a freshly installed binary has unresolvable dependencies.
void reportMissingLibs(string path)
{
    auto missing = missingLibs(path);
    if (missing.length == 0)
        return;
    warnf("%s needs shared libraries not found on your system: %s",
        path.baseName, missing.join(", "));
    warn("the release may bundle these (re-extract the full archive), or install them with your system package manager");
}
