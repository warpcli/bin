module geto.cmd.support;

import std.algorithm : canFind;
import std.array : array, join, split;
import std.conv : octal;
import std.digest : toHexString;
import std.digest.sha : SHA256, digest;
import std.file : FileException, exists, isDir, mkdirRecurse, read, remove, setAttributes, write;
import std.path : absolutePath, baseName, dirName, isAbsolute;
import std.process : environment;
import std.stdio : writefln, writeln;
import std.string : startsWith, toLower;

import mochafizz.style : render;

import geto.config : Binary, Config, get;
import geto.log;
import geto.providers : File;
import geto.ui.styles : accentStyle, mutedStyle, okStyle, repoShort, rule;
import geto.util : expandEnv;

/// Raised when a command cannot complete.
class CommandException : Exception
{
    int code = 1;

    this(string message, int code = 1, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
        this.code = code;
    }
}

/// The persistent `--tag` selection.
string[] activeTags;

/// Requested tags, defaulting to "default".
string[] wantedTags()
{
    return activeTags.length == 0 ? ["default"] : activeTags;
}

/// Whether every binary was requested regardless of tag.
bool tagFilterAll()
{
    return activeTags.canFind("all");
}

/// A binary's tags, defaulting to "default".
string[] binTags(Binary binary)
{
    return binary.tags.length == 0 ? ["default"] : binary.tags;
}

/// Whether a binary carries any of the given tags.
bool binHasAnyTag(Binary binary, const string[] tags)
{
    foreach (wanted; tags)
        foreach (have; binTags(binary))
            if (have == wanted)
                return true;
    return false;
}

/// The binaries matching the active tag filter.
Binary[string] selectByTag(Binary[string] bins)
{
    if (tagFilterAll())
        return bins;
    const wanted = wantedTags();
    Binary[string] result;
    foreach (key, binary; bins)
        if (binary !is null && binHasAnyTag(binary, wanted))
            result[key] = binary;
    return result;
}

/// Resolves a name or path to the key of a managed binary.
string getBinPath(string name)
{
    auto cfg = get();
    const resolved = lookupInPath(name);
    if (resolved.length == 0)
    {
        debugf("binary %s not found in PATH", name);
        if (!name.canFind("/"))
            foreach (binary; cfg.bins)
                if (binary !is null && expandEnv(binary.path).baseName == name)
                    return binary.path;
        throw new CommandException("binary " ~ name ~ " not found");
    }

    foreach (binary; cfg.bins)
        if (binary !is null && expandEnv(binary.path) == resolved)
            return binary.path;
    throw new CommandException("binary path " ~ resolved ~ " not found");
}

/// Finds an executable on `$PATH`, returning "" when absent.
string lookupInPath(string name)
{
    import std.path : buildPath;

    if (name.canFind("/"))
        return name.exists ? absolutePath(name) : "";
    foreach (dir; environment.get("PATH", "").split(':'))
    {
        if (dir.length == 0)
            continue;
        const candidate = buildPath(dir, name);
        if (candidate.exists && !candidate.isDir)
            return candidate;
    }
    return "";
}

/// The repository name derived from an install URL.
string defaultBinName(string raw)
{
    auto text = raw;
    foreach (prefix; ["https://", "http://", "goinstall://"])
        if (text.startsWith(prefix))
        {
            text = text[prefix.length .. $];
            break;
        }
    if (text.length > 0 && text[$ - 1] == '/')
        text = text[0 .. $ - 1];
    if (text.length > 4 && text[$ - 4 .. $] == ".git")
        text = text[0 .. $ - 4];
    auto parts = text.split('/');
    const name = parts[$ - 1];
    return name.length == 0 ? "bin" : name;
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

/// Prints a full-width separator.
void sep()
{
    writeln(rule());
}

/// Prints a styled action header.
void stepHeader(string name, string detail)
{
    writefln("%s %s  %s", accentStyle.render("▸"), accentStyle.render(name),
        mutedStyle.render(detail));
}

/// Prints a styled success line for a completed action.
void stepDone(string verb, string name, string versionText)
{
    writefln("  %s %s %s %s", okStyle.render("✓"), mutedStyle.render(verb), name,
        accentStyle.render(versionText));
}

// ---------------------------------------------------------------------------
// Installation
// ---------------------------------------------------------------------------

/// Resolves the destination path, appending `fileName` when it names a directory.
string checkFinalPath(string path, string fileName)
{
    import std.path : buildPath;

    const expanded = expandEnv(path);
    if (expanded.exists && expanded.isDir)
        return buildPath(path, fileName);
    return path;
}

/// Writes the fetched binary to disk and returns its SHA256 digest.
ubyte[] saveToDisk(File file, string path, bool overwrite)
{
    const target = expandEnv(path);
    mkdirRecurse(target.dirName);

    if (overwrite)
    {
        debugf("Overwrite flag set, removing file %s", target);
        if (target.exists)
            remove(target);
    }
    else if (target.exists)
        throw new CommandException("file already exists: " ~ target);

    debugf("Copying for %s@%s into %s", file.name, file.versionText, target);
    write(target, file.data);
    setAttributes(target, octal!"766");

    warnMissingLibs(target);
    return digest!SHA256(file.data).dup;
}

/// Lowercase hex encoding, matching the Go build's `%x` formatting.
string hexDigest(const ubyte[] digestBytes)
{
    return digestBytes.toHexString.idup.toLower;
}

/// The SHA256 of a file on disk, as lowercase hex.
string fileSha256(string path)
{
    return hexDigest(digest!SHA256(cast(const(ubyte)[]) read(path)));
}

// Defined in geto.cmd.elfcheck; declared here to keep saveToDisk self-contained.
private void warnMissingLibs(string path)
{
    import geto.cmd.elfcheck : reportMissingLibs;

    reportMissingLibs(path);
}

unittest
{
    assert(defaultBinName("https://github.com/sharkdp/bat") == "bat");
    assert(defaultBinName("github.com/sharkdp/bat.git") == "bat");
    assert(defaultBinName("goinstall://golang.org/x/tools/cmd/goimports") == "goimports");
    assert(hexDigest([0xDE, 0xAD, 0xBE, 0xEF]) == "deadbeef");

    activeTags = null;
    assert(wantedTags() == ["default"]);
    activeTags = ["all"];
    assert(tagFilterAll());
    activeTags = null;
}
