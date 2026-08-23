module geto.assets;

import std.algorithm : canFind, filter, map, sort;
import std.array : array, join, split;
import std.conv : to;
import std.format : format;
import std.path : baseName, buildPath, extension;
import std.regex : Regex, matchFirst, regex, replaceAll, splitter;
import std.string : endsWith, indexOf, startsWith, toLower;

import geto.ai.engine : Engine, resetModel;
import geto.archive;
import geto.config : getArch, getOs, getOsSpecificExtensions, stateDir;
import geto.elf : importedLibraries, isBinaryImage;
import geto.filetype : FileKind, detect, isCompressedKind, kindForExtension;
import geto.http : download;
import geto.log;
import geto.ui.select : selectOne;
import geto.util : containsAny, envBool;

/// Raised when no compatible asset can be selected.
class AssetException : Exception
{
    this(string message, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
    }
}

/// Suppresses the download progress bar.
bool quiet;

/// Platform lookup, indirected so tests can pretend to be another host.
struct PlatformResolver
{
    string[]delegate() os;
    string[]delegate() arch;
    string[]delegate() osExtensions;
}

private PlatformResolver resolver;

shared static this()
{
    resetResolver();
}

/// Restores the real host platform.
void resetResolver()
{
    resolver = PlatformResolver(() => getOs(), () => getArch(), () => getOsSpecificExtensions());
}

/// Overrides the platform, for tests.
void setResolver(PlatformResolver value)
{
    resolver = value;
}

// ---------------------------------------------------------------------------
// Learned asset selection
// ---------------------------------------------------------------------------

private Engine cachedEngine;
private bool engineResolved;

/// Directory holding the learned asset-selection model.
string aiModelDir()
{
    if (aiDisabled())
        return "";
    const dir = stateDir();
    return dir.length == 0 ? "" : buildPath(dir, "ai");
}

/// Whether `GETO_NO_AI` opts out of asset-selection learning.
bool aiDisabled()
{
    return envBool("GETO_NO_AI");
}

private Engine aiEngine()
{
    if (engineResolved)
        return cachedEngine;
    engineResolved = true;

    const dir = aiModelDir();
    if (dir.length == 0)
    {
        debugf("Asset-selection learning is disabled");
        return null;
    }
    auto engine = Engine.create();
    try
    {
        engine.load(dir);
        debugf("Loaded asset-selection model from %s (%d selections)", dir, engine.selections);
    }
    catch (Exception failure)
        debugf("No usable asset-selection model in %s (%s); starting fresh", dir, failure.msg);
    cachedEngine = engine;
    return cachedEngine;
}

/// Lets the model break a tie between equally scored candidates.
private FilteredAsset aiPick(string repoName, FilteredAsset[] matches)
{
    auto engine = aiEngine();
    if (engine is null || !engine.trained)
        return null;

    string[] names;
    foreach (match; matches)
        names ~= match.name;

    string best;
    if (!engine.decide(names, repoName, best))
        return null;
    foreach (match; matches)
        if (match.name == best)
            return match;
    return null;
}

/// Describes where an automatic choice came from.
private string aiBasis()
{
    auto engine = aiEngine();
    if (engine is null)
        return "";
    const count = engine.selections;
    if (count == 0)
        return "using geto's built-in defaults";
    if (engine.seeded)
        return format("using geto's built-in defaults and your %d past choice(s)", count);
    return format("based on your %d past choice(s)", count);
}

private void aiLearn(string repoName, FilteredAsset chosen, FilteredAsset[] matches)
{
    auto engine = aiEngine();
    if (engine is null || chosen is null || matches.length <= 1)
        return;

    string[] rejected;
    foreach (match; matches)
        if (match !is chosen)
            rejected ~= match.name;

    engine.observe(chosen.name, rejected, repoName);
    const dir = aiModelDir();
    if (dir.length == 0)
        return;
    try
        engine.save(dir);
    catch (Exception failure)
        debugf("Failed to save asset-selection model: %s", failure.msg);
}

/// Clears the learned model, reporting whether files were removed.
bool resetLearning()
{
    const dir = aiModelDir();
    if (dir.length == 0)
        throw new AssetException("asset-selection learning is disabled");
    return resetModel(dir);
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// A release asset as published upstream.
final class Asset
{
    string name;
    string displayName;
    string url;

    this(string name, string displayName = "", string url = "")
    {
        this.name = name;
        this.displayName = displayName;
        this.url = url;
    }

    override string toString() const
    {
        return displayName.length > 0 ? displayName : name;
    }
}

/// A shared library shipped alongside the selected binary.
struct Sidecar
{
    ubyte[] data;
    string link;
}

/// A release asset that survived filtering.
final class FilteredAsset
{
    string repoName;
    string name;
    string displayName;
    string url;
    int score;
    string[string] extraHeaders;
    string[] fingerprint;
    ubyte[] data;
    Sidecar[string] sidecars;

    override string toString() const
    {
        return displayName.length > 0 ? displayName : name;
    }
}

/// The binary geto will install, after unpacking.
struct FinalFile
{
    ubyte[] data;
    string name;
    string packagePath;
    string[] packageFingerprint;
    Sidecar[string] sidecars;
}

/// Inputs controlling one selection pass.
struct FilterOpts
{
    bool skipScoring;
    bool skipPathCheck;
    string packageName;
    string prevPackagePath;

    string packagePath;
    string[] packageFingerprint;

    string selectedAsset;
    string[] assetFingerprint;
    bool recheck;

    string wantedAsset;
    string wantedPackagePath;

    bool nonInteractive;
    bool collectLibs;
}

// ---------------------------------------------------------------------------
// Name normalization
// ---------------------------------------------------------------------------

/// Matches version-like number groups so they can be collapsed.
private Regex!char assetVersionRe;
private Regex!char assetTokenRe;

shared static this()
{
    assetVersionRe = regex(`[0-9]+(\.[0-9]+)*`);
    assetTokenRe = regex(`[^a-z0-9]+`);
}

/// Lowercases an asset name and replaces version-like groups with `#`, so the
/// same asset across releases compares equal.
string normalizeAssetName(string name)
{
    return name.toLower.replaceAll(assetVersionRe, "#");
}

/// Sorted, version-normalized names, used to spot layout changes.
string[] fingerprint(Asset[] assets)
{
    string[] result;
    foreach (asset; assets)
        result ~= normalizeAssetName(asset.name);
    result.sort();
    return result;
}

// ---------------------------------------------------------------------------
// Usability filtering
// ---------------------------------------------------------------------------

/// Archive and compression formats geto can unpack.
private immutable string[] installableSuffixes = [
    ".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz2", ".tbz",
    ".tar.zst", ".tzst", ".tar", ".zip", ".gz", ".xz", ".bz2", ".zst",
];

/// Extensions that are never an installable binary.
private immutable bool[string] ignoredExts;

shared static this()
{
    bool[string] ignored;
    foreach (name; [
        "sha256", "sha512", "sha1", "md5", "sum", "checksum", "sig", "sigstore",
        "asc", "gpg", "pem", "pub", "crt", "cert", "minisig", "sbom", "spdx",
        "cdx", "intoto", "jsonl", "json", "txt", "md", "yaml", "yml", "deb",
        "rpm", "msi", "pkg", "dmg", "apk", "snap", "flatpak", "whl", "ps1",
        // libraries and object files are never the CLI binary we want.
        "a", "o", "so", "dll", "dylib", "lib"
    ])
        ignored[name] = true;
    ignoredExts = cast(immutable) ignored;
}

private immutable string[] ignoredNameSuffixes = [
    "-update", "_update", ".update"
];

private immutable string[][] archAliasGroups = [
    ["amd64", "x86_64", "x86-64", "x64", "intel_64", "intel64"],
    ["arm64", "aarch64", "arm_64", "arm-64", "armv8"],
    ["386", "i386", "i686", "x86"],
    // Bare "arm" is deliberately absent: it matches inside "arm64" and would
    // mark 64-bit builds as foreign on an arm64 host.
    ["armv6", "armv7", "armv7l", "armhf", "armel"],
    ["ppc64le", "ppc64", "powerpc64", "powerpc", "ppc"], ["s390x"],
    ["riscv64", "riscv"],
    ["mips64le", "mips64el", "mips64", "mipsle", "mipsel", "mips"],
    ["loong64", "loongarch64"],
];

/// Checksum manifests are regularly published with no extension at all
/// (SHA256SUMS, sha512sums, MD5SUMS), so the extension table never sees them
/// and they read as extensionless raw binaries.
private bool isChecksumManifest(string lower)
{
    import std.path : stripExtension;

    const base = lower.stripExtension;
    if (base.endsWith("checksum") || base.endsWith("checksums"))
        return true;
    if (!base.endsWith("sum") && !base.endsWith("sums"))
        return false;
    // Require a digest name too, so a binary that merely ends in "sum" stays.
    foreach (digest; ["sha", "md5", "blake2", "blake3", "b2", "b3"])
        if (base.canFind(digest))
            return true;
    return false;
}

/// Whether an asset could be something geto can install. Keeps supported
/// archives, OS-appropriate single files, and raw binaries (often extensionless
/// but carrying dots from a version), rejecting only known non-binary types.
bool isUsableAsset(string name)
{
    const lower = name.toLower;
    foreach (suffix; ignoredNameSuffixes)
        if (lower.endsWith(suffix))
            return false;
    if (isChecksumManifest(lower))
        return false;

    foreach (suffix; installableSuffixes)
        if (lower.endsWith(suffix))
            return true;
    foreach (ext; resolver.osExtensions())
        if (lower.endsWith("." ~ ext.toLower))
            return true;

    auto ext = lower.extension;
    if (ext.startsWith("."))
        ext = ext[1 .. $];
    if (ext.length > 0)
    {
        if (ext in ignoredExts)
            return false;
        if (ext == "exe" || ext == "appimage" || ext == "dmg") // Executables for another OS; the current-OS ones were kept above.
            return false;
    }
    // Everything else stays; scoring decides the best match.
    return true;
}

private bool[string] archAliasSet(const string[] aliases)
{
    bool[string] result;
    foreach (alias_; aliases)
        result[alias_.toLower] = true;
    return result;
}

private const(string[]) currentArchGroup()
{
    auto current = archAliasSet(resolver.arch());
    foreach (group; archAliasGroups)
        foreach (alias_; group)
            if (alias_.toLower in current)
                return group;
    return resolver.arch();
}

/// True when `needle` occurs in `text` without a letter directly before it.
/// Plain substring matching made the short arch aliases fire inside longer
/// words — "x64" matches inside "linux64", so `jq-linux64` scored as an
/// explicit amd64 build and tied with the real `jq-linux-amd64`.
package bool containsToken(string text, string needle)
{
    import std.ascii : isAlpha;

    if (needle.length == 0)
        return false;
    size_t from = 0;
    while (from + needle.length <= text.length)
    {
        const at = text[from .. $].indexOf(needle);
        if (at < 0)
            return false;
        const start = from + at;
        if (start == 0 || !text[start - 1].isAlpha)
            return true;
        from = start + 1;
    }
    return false;
}

private bool containsArchAlias(string name, const string[] aliases)
{
    const lower = name.toLower;
    foreach (alias_; aliases)
        if (lower.containsToken(alias_.toLower))
            return true;
    return false;
}

private bool hasNativeArch(string name)
{
    return containsArchAlias(name, currentArchGroup());
}

private bool hasForeignArch(string name)
{
    auto native = archAliasSet(currentArchGroup());
    foreach (group; archAliasGroups)
    {
        bool isNativeGroup = false;
        foreach (alias_; group)
            if (alias_.toLower in native)
            {
                isNativeGroup = true;
                break;
            }
        if (isNativeGroup)
            continue;
        if (containsArchAlias(name, group))
            return true;
    }
    return false;
}

/// Tokens that mark an asset as built for a particular operating system.
private immutable string[][] osAliasGroups = [
    ["linux"], ["windows", "win32", "win64", "win", "msvc", "mingw"],
    ["darwin", "macos", "osx", "apple", "mac"], ["freebsd"], ["openbsd"],
    ["netbsd"], ["dragonfly"], ["solaris"], ["illumos"], ["android"], ["ios"],
];

private const(string[]) currentOsGroup()
{
    auto current = archAliasSet(resolver.os());
    foreach (group; osAliasGroups)
        foreach (alias_; group)
            if (alias_.toLower in current)
                return group;
    return resolver.os();
}

/// True when the name names an operating system that is not this one. Assets
/// that name no OS at all are not foreign — plenty of releases ship a bare
/// `tool_x86_64` that runs here.
bool hasForeignOs(string name)
{
    auto native = archAliasSet(currentOsGroup());
    const lower = name.toLower;
    foreach (group; osAliasGroups)
    {
        bool isNativeGroup = false;
        foreach (alias_; group)
            if (alias_.toLower in native)
            {
                isNativeGroup = true;
                break;
            }
        if (isNativeGroup)
            continue;
        foreach (alias_; group)
            if (lower.containsToken(alias_))
                return true;
    }
    return false;
}

/// Drops assets built for another operating system. Without this a release
/// that ships no Linux build still scored its Windows zip on the architecture
/// alone — espanso installed `Espanso-Win-Portable-x86_64.zip`, then offered
/// its DLLs as the binary to install.
Asset[] preferNativeOs(Asset[] assets)
{
    Asset[] result;
    foreach (asset; assets)
        if (!hasForeignOs(asset.name))
            result ~= asset;
    return result.length > 0 ? result : assets;
}

/// True when every candidate targets another operating system.
bool allForeignOs(Asset[] assets)
{
    if (assets.length == 0)
        return false;
    foreach (asset; assets)
        if (!hasForeignOs(asset.name))
            return false;
    return true;
}

/// Drops foreign-architecture assets once a native one is present. Releases
/// with no native match keep their full set so a manual choice stays possible.
Asset[] preferNativeArch(Asset[] assets)
{
    Asset[] result;
    foreach (asset; assets)
        if (hasNativeArch(asset.name) || !hasForeignArch(asset.name))
            result ~= asset;
    // Everything names a foreign architecture, so keep the list intact and let
    // the user decide rather than offering nothing.
    return result.length > 0 ? result : assets;
}

/// Collapses libc-flavor twins, keeping musl when both are offered.
/// Removes `tokens` from a name and collapses the separators left behind, so
/// `tool-x64` and `tool-x64-static` land in the same group.
private string collapseTokens(string name, const string[] tokens)
{
    import std.array : appender, replace;
    import std.ascii : isAlphaNum;

    auto lower = name.toLower;
    foreach (token; tokens)
        lower = lower.replace(token, "");

    auto output = appender!string;
    bool pendingSeparator = false;
    foreach (c; lower)
    {
        if (c.isAlphaNum)
        {
            if (pendingSeparator && output.data.length > 0)
                output ~= '-';
            pendingSeparator = false;
            output ~= c;
        }
        else
            pendingSeparator = true;
    }
    return output.data;
}

Asset[] preferMusl(Asset[] assets)
{
    static string stem(string name)
    {
        // "gcc" marks a glibc build just as "gnu" does; without it vopono's
        // `_gcc` and `_musl` builds never grouped together.
        return collapseTokens(name, ["musl", "glibc", "gnu", "gcc"]);
    }

    Asset[][string] groups;
    string[] order;
    foreach (asset; assets)
    {
        const key = stem(asset.name);
        if (key !in groups)
            order ~= key;
        groups[key] ~= asset;
    }

    Asset[] result;
    foreach (key; order)
    {
        auto group = groups[key];
        bool hasMusl = false;
        foreach (asset; group)
            if (asset.name.toLower.canFind("musl"))
            {
                hasMusl = true;
                break;
            }
        foreach (asset; group)
        {
            const lower = asset.name.toLower;
            // Everything in this group is the same build bar its libc, so
            // once a musl variant exists the others go — including the one
            // that names no libc at all, which is the dynamic glibc build.
            if (hasMusl && !lower.containsToken("musl"))
                continue;
            result ~= asset;
        }
    }
    return result;
}

/// Drops source archives, install scripts and distribution packages when a
/// plain artifact is on offer.
/// `hck` ships `hck-linux-amd64` beside `hck-linux-amd64-src.tar.gz`, and
/// `flawz` ships a `flawz-installer.sh`; only the built binary is something
/// geto can install and run.
Asset[] preferBuilt(Asset[] assets)
{
    static bool isSource(string name)
    {
        auto tokens = assetTokens(name);
        foreach (token; [
            "src", "source", "sources", "installer", "package", "pkg",
            "debian", "ubuntu", "fedora", "centos", "rhel"
        ])
            if (tokens.canFind(token))
                return true;
        return false;
    }

    Asset[] result;
    foreach (asset; assets)
        if (!isSource(asset.name))
            result ~= asset;
    return result.length > 0 ? result : assets;
}

/// Keeps the statically linked twin when a release ships both, the same way
/// musl wins over glibc. ffsend ships `linux-x64` and `linux-x64-static`.
Asset[] preferStatic(Asset[] assets)
{
    Asset[][string] groups;
    string[] order;
    foreach (asset; assets)
    {
        const key = collapseTokens(asset.name, ["static"]);
        if (key !in groups)
            order ~= key;
        groups[key] ~= asset;
    }

    Asset[] result;
    foreach (key; order)
    {
        auto group = groups[key];
        bool hasStatic = false;
        foreach (asset; group)
            if (asset.name.toLower.containsToken("static"))
            {
                hasStatic = true;
                break;
            }
        foreach (asset; group)
            if (!hasStatic || asset.name.toLower.containsToken("static"))
                result ~= asset;
    }
    return result;
}

/// Tokens marking a build that is not the one most people want: accelerator
/// flavours, debug artefacts and alternate front-ends.
private immutable string[] variantTokens = [
    "mlx", "rocm", "cuda", "vulkan", "jetpack", "jetpack5", "jetpack6", "fips",
    "baseline", "profile", "debug", "dbg", "symbols", "syms", "gui", "desktop",
];

/// Drops accelerator and debug variants when a plain build is also offered.
/// ollama ships `-mlx` and `-rocm` beside the ordinary archive, and opencode
/// ships `-baseline` twins; neither is the default choice.
Asset[] preferPlainBuild(Asset[] assets)
{
    static bool isVariant(string name)
    {
        auto tokens = assetTokens(name);
        foreach (token; variantTokens)
            if (tokens.canFind(token))
                return true;
        return false;
    }

    Asset[] result;
    foreach (asset; assets)
        if (!isVariant(asset.name))
            result ~= asset;
    return result.length > 0 ? result : assets;
}

/// Picks one compression among otherwise identical tar siblings. goose ships
/// the same build as .tar.bz2 and .tar.gz; there is nothing to choose between
/// them, so take the most widely supported.
private Asset[] bestCompression(Asset[] tars)
{
    if (tars.length <= 1)
        return tars;
    static immutable order = [
        ".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.zst", ".tzst", ".tar.bz2",
        ".tbz2", ".tbz", ".tar"
    ];
    foreach (suffix; order)
    {
        Asset[] matching;
        foreach (asset; tars)
            if (asset.name.toLower.endsWith(suffix))
                matching ~= asset;
        if (matching.length > 0)
            return matching;
    }
    return tars;
}

private immutable string[] tarSuffixes = [
    ".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz2", ".tbz",
    ".tar.zst", ".tzst", ".tar",
];

/// The asset name without its archive suffix, plus which family it was.
private string archiveStem(string name, out bool isTar, out bool isZip)
{
    const lower = name.toLower;
    foreach (suffix; tarSuffixes)
        if (lower.endsWith(suffix))
        {
            isTar = true;
            return lower[0 .. $ - suffix.length];
        }
    if (lower.endsWith(".zip"))
    {
        isZip = true;
        return lower[0 .. $ - ".zip".length];
    }
    // A bare .zst or .gz holds the same payload as the .tar.gz beside it, so
    // strip it too and let them share a group.
    foreach (suffix; [".gz", ".xz", ".bz2", ".zst"])
        if (lower.endsWith(suffix))
            return lower[0 .. $ - suffix.length];
    return lower;
}

/// Collapses tar-vs-zip twins, keeping the format preferred for this OS.
Asset[] preferArchiveType(Asset[] assets)
{
    bool preferTar = false;
    foreach (name; resolver.os()) switch (name)
    {
    case "linux":
    case "freebsd":
    case "openbsd":
    case "netbsd":
    case "dragonfly":
        preferTar = true;
        break;
    default:
        break;
    }

    static struct Group
    {
        Asset[] tar;
        Asset[] zip;
        Asset[] other;
    }

    Group[string] groups;
    string[] order;
    foreach (asset; assets)
    {
        bool isTar, isZip;
        const key = archiveStem(asset.name, isTar, isZip);
        if (key !in groups)
        {
            groups[key] = Group.init;
            order ~= key;
        }
        if (isTar)
            groups[key].tar ~= asset;
        else if (isZip)
            groups[key].zip ~= asset;
        else
            groups[key].other ~= asset;
    }

    Asset[] result;
    foreach (key; order)
    {
        auto group = groups[key];
        Asset[] archives;
        if (group.tar.length > 0 && group.zip.length > 0)
            archives = preferTar ? bestCompression(group.tar) : group.zip;
        else
            archives = bestCompression(group.tar) ~ group.zip;

        result ~= archives;
        // A bare blob beside an archive of the same name is the same payload,
        // so only offer it when no archive exists.
        if (archives.length == 0)
            result ~= group.other;
    }
    return result;
}

/// Narrows a release to the assets that suit this machine. Order matters:
/// drop non-artifacts and variant builds first, then container format, libc,
/// architecture, operating system, and finally static twins.
Asset[] narrowToPlatform(Asset[] assets)
{
    auto result = preferBuilt(assets);
    result = preferPlainBuild(result);
    result = preferArchiveType(result);
    result = preferMusl(result);
    result = preferNativeArch(result);
    result = preferNativeOs(result);
    result = preferStatic(result);
    return result;
}

private Asset[] filterUsableAssets(Asset[] assets)
{
    Asset[] result;
    foreach (asset; assets)
    {
        if (isUsableAsset(asset.name))
            result ~= asset;
        else
            debugf("Ignoring asset %s (not an installable archive/binary)", asset.name);
    }
    return result;
}

/// Runs the selection pipeline over asset names without downloading anything.
/// Returns the auto-selected name, or the candidates a user would be asked
/// about; both empty means the release has no build for this platform.
void preview(string repoName, const string[] names, out string chosen, out string[] options)
{
    Asset[] assets;
    foreach (name; names)
        assets ~= new Asset(name);

    auto usable = filterUsableAssets(assets);
    if (usable.length == 0)
        usable = assets;
    // No compatible build: report nothing rather than a foreign-platform pick.
    if (allForeignOs(preferBuilt(usable)))
        return;
    usable = narrowToPlatform(usable);

    // The real install path ranks against the package name, so preview must
    // too or it reports prompts that never actually happen.
    FilterOpts options_;
    options_.packageName = repoName;
    auto filter_ = new Filter(options_);
    auto matches = filter_.scoredMatches(repoName, usable);
    if (matches.length == 1)
    {
        chosen = matches[0].name;
        return;
    }
    foreach (match; matches)
        options ~= match.name;
}

// ---------------------------------------------------------------------------
// Filter
// ---------------------------------------------------------------------------

private bool matchesAnyToken(string text, const string[] needles)
{
    foreach (needle; needles)
        if (text.containsToken(needle))
            return true;
    return false;
}

/// Selects which release asset to install and unpacks it.
final class Filter
{
    private FilterOpts opts;
    private string repoName;
    private string name;
    private string packagePath;
    private string[] packageFingerprint;
    private Sidecar[string] sidecars;

    this(FilterOpts opts)
    {
        this.opts = opts;
    }

    /// Chooses a release asset, reusing the remembered choice when the set of
    /// installable files is unchanged.
    FilteredAsset selectReleaseAsset(string repoName, Asset[] assets)
    {
        auto usable = filterUsableAssets(assets);
        if (usable.length == 0)
        {
            // Nothing recognizable; offer the full list rather than failing.
            debugf("No installable assets after filtering; falling back to full list");
            usable = assets;
        }
        // Source archives and install scripts go first: a release whose only
        // non-foreign entries are those still has no build for this platform.
        // --all keeps the raw list, so none of this runs.
        if (!opts.skipScoring && allForeignOs(preferBuilt(usable)))
            throw new AssetException("this release has no build for " ~ resolver.os()[0] ~ "/" ~ resolver.arch()[0]
                    ~ "; run with --all to pick from every asset");
        usable = narrowToPlatform(usable);

        auto marks = fingerprint(usable);

        // --all shows everything, including filtered-out files, and always prompts.
        auto selectFrom = opts.skipScoring ? assets : usable;

        if (!opts.skipScoring && opts.wantedAsset.length > 0)
        {
            const wanted = normalizeAssetName(opts.wantedAsset);
            foreach (asset; usable)
                if (asset.name == opts.wantedAsset || normalizeAssetName(asset.name) == wanted)
                {
                    debugf("Using requested asset %s", asset.name);
                    return makeFiltered(repoName, asset, marks);
                }
            throw new AssetException(
                    "requested asset " ~ opts.wantedAsset
                    ~ " not found in compatible release assets");
        }

        if (!opts.recheck && !opts.skipScoring && opts.selectedAsset.length > 0)
        {
            if (marks == opts.assetFingerprint)
            {
                foreach (asset; usable)
                    if (normalizeAssetName(asset.name) == opts.selectedAsset)
                    {
                        debugf("Reusing remembered asset %s (release layout unchanged)", asset.name);
                        return makeFiltered(repoName, asset, marks);
                    }
                debugf("Remembered asset %s no longer present; re-prompting", opts.selectedAsset);
            }
            else
                infof("Release assets changed since last update; please re-select");
        }

        auto chosen = filterAssets(repoName, selectFrom);
        chosen.fingerprint = marks;
        return chosen;
    }

    private static FilteredAsset makeFiltered(string repoName, Asset asset, string[] marks)
    {
        auto result = new FilteredAsset;
        result.repoName = repoName;
        result.name = asset.name;
        result.displayName = asset.displayName;
        result.url = asset.url;
        result.fingerprint = marks;
        return result;
    }

    /// Scores candidates by OS, arch and repository name, returning the
    /// highest-scoring subset — the set a user would be prompted with.
    private FilteredAsset[] scoredMatches(string repoName, Asset[] assets)
    {
        FilteredAsset[] matches;
        if (assets.length == 1)
            return [makeFiltered(repoName, assets[0], null)];

        if (opts.skipScoring)
        {
            debugf("--all flag was supplied, skipping scoring");
            foreach (asset; assets)
                matches ~= makeFiltered(repoName, asset, null);
            return matches;
        }

        int[string] scores;
        if (repoName.length > 0)
            scores[repoName] = 1;
        foreach (name; resolver.os())
            scores[name] = 10;
        foreach (name; resolver.arch())
            scores[name] = 5;

        string[] scoreKeys;
        foreach (key; scores.keys)
            scoreKeys ~= key.toLower;

        foreach (asset; assets)
        {
            auto candidate = makeFiltered(repoName, asset, null);
            int total = 0;
            if (matchesAnyToken(asset.name.toLower, scoreKeys) && isSupportedExt(asset.name))
            {
                foreach (key, value; scores)
                    if (asset.name.toLower.containsToken(key.toLower))
                    {
                        debugf("Candidate %s contains %s. Adding score %d", asset.name, key, value);
                        total += value;
                    }
                // The learned model deliberately stays out of this score: it
                // only breaks ties between equally scored candidates, in
                // filterAssets. Folding it in here would make exact ties
                // impossible and suppress the prompt it learns from.
                candidate.score = total;
            }
            if (candidate.score > 0)
                matches ~= candidate;
        }

        int highest = 0;
        foreach (match; matches)
            if (match.score > highest)
                highest = match.score;
        matches = matches.filter!(match => match.score >= highest).array;
        matches = preferPackageName(matches, opts.packageName);

        // AppImage is a GUI-app fallback; when a regular binary or archive
        // scored as high, prefer the CLI build. AppImage-only releases keep it.
        static bool isAppImage(string name)
        {
            return name.toLower.endsWith(".appimage");
        }

        bool hasOther = false;
        foreach (match; matches)
            if (!isAppImage(match.name))
            {
                hasOther = true;
                break;
            }
        if (hasOther)
            matches = matches.filter!(match => !isAppImage(match.name)).array;
        return matches;
    }

    /// Selects the asset, prompting when no single best match exists.
    FilteredAsset filterAssets(string repoName, Asset[] assets)
    {
        auto matches = scoredMatches(repoName, assets);

        if (matches.length == 0)
            throw new AssetException("could not find any compatible files");
        if (matches.length == 1)
            return matches[0];

        matches.sort!((a, b) => a.toString() < b.toString());

        // A model trained on enough past selections can resolve the tie itself.
        // This runs before the non-interactive bail-out on purpose: it lets the
        // TUI through an ambiguous release it would otherwise have to fail.
        if (auto chosen = aiPick(repoName, matches))
        {
            infof("Selected %s from %d equally-scored assets %s; run `geto update -r %s` to change it",
                    chosen.name, matches.length, aiBasis(), repoName);
            return chosen;
        }

        if (opts.nonInteractive)
            throw new AssetException(
                    "multiple matching assets and running non-interactively; run `geto update -r "
                    ~ repoName ~ "` to choose");

        string[] labels;
        foreach (match; matches)
            labels ~= match.toString();
        const index = selectOne("Multiple matches found, please select one:", labels);
        auto chosen = matches[index];
        aiLearn(repoName, chosen, matches);
        return chosen;
    }

    // -----------------------------------------------------------------------
    // Download and unpacking
    // -----------------------------------------------------------------------

    /// Downloads the asset and unwraps it down to the installable binary.
    FinalFile processUrl(FilteredAsset asset)
    {
        repoName = asset.repoName;
        name = asset.name;

        // The whole file is buffered so the user can be prompted about the
        // files inside an archive.
        auto data = download(asset.url, asset.extraHeaders, asset.toString(), quiet);
        return processBuffer(data);
    }

    /// Unwraps one layer at a time until a plain file is left.
    FinalFile processBuffer(ubyte[] data)
    {
        const head = data.length > 8192 ? data[0 .. 8192] : data;
        const kind = detect(head);

        ubyte[] next;
        switch (kind)
        {
        case FileKind.gz:
            string storedName;
            next = gunzip(data, storedName);
            name = storedName;
            break;
        case FileKind.tar:
            next = processTar(data);
            break;
        case FileKind.xz:
            next = unxz(data);
            name = repoName;
            break;
        case FileKind.bz2:
            next = unbzip2(data);
            name = repoName;
            break;
        case FileKind.zst:
            next = unzstd(data);
            name = repoName;
            break;
        case FileKind.zip:
            next = processZip(data);
            break;
        default:
            return FinalFile(data, name, packagePath, packageFingerprint, sidecars);
        }
        // A .tar.gz needs the uncompressed archive processed in turn.
        return processBuffer(next);
    }

    private ubyte[] processTar(ubyte[] data)
    {
        auto entries = readTar(data);
        ubyte[][string] files;
        string[string] links;
        if (opts.packagePath.length > 0)
            debugf("Processing tar with package path %s", opts.packagePath);

        foreach (entry; entries)
        {
            if (entry.isSymlink)
                links[entry.path] = entry.linkTarget;
            else
                files[entry.path] = entry.data;
        }
        if (files.length == 0)
            throw new AssetException("no files found in tar archive");

        const selected = pickArchiveFile(repoName, files);
        auto payload = files[selected];
        name = selected.baseName;
        packagePath = selected;
        if (opts.collectLibs)
            sidecars = collectLibClosure(payload, files, links);
        return payload;
    }

    private ubyte[] processZip(ubyte[] data)
    {
        auto entries = readZip(data);
        ubyte[][string] files;
        if (opts.packagePath.length > 0)
            debugf("Processing zip with package path %s", opts.packagePath);

        foreach (entry; entries)
            if (!entry.isSymlink)
                files[entry.path] = entry.data;
        if (files.length == 0)
            throw new AssetException("no files found in zip archive");

        const selected = pickArchiveFile(repoName, files);
        // Archives usually nest the binary in a folder; keep only the basename.
        name = selected.baseName;
        packagePath = selected;
        return files[selected];
    }

    /// Decides which file inside an archive to extract, mirroring the
    /// release-asset logic one level down: keep installable files, reuse the
    /// remembered choice when only versions changed, re-prompt when the layout
    /// changed, and auto-select when only one candidate remains.
    private string pickArchiveFile(string repoName, ubyte[][string] files)
    {
        auto usable = preferNativeArch(installableCandidates(files));
        auto marks = fingerprint(usable);
        packageFingerprint = marks;

        if (opts.wantedPackagePath.length > 0)
        {
            const wanted = normalizeAssetName(opts.wantedPackagePath);
            foreach (asset; usable)
                if (asset.name == opts.wantedPackagePath || normalizeAssetName(asset.name) == wanted)
                {
                    debugf("Using requested package path %s", asset.name);
                    return asset.name;
                }
            throw new AssetException(
                    "requested package path " ~ opts.wantedPackagePath ~ " not found in archive");
        }

        if (!opts.recheck && !opts.skipPathCheck && opts.packagePath.length > 0)
        {
            const wanted = normalizeAssetName(opts.packagePath);
            if (marks == opts.packageFingerprint)
            {
                foreach (asset; usable)
                    if (normalizeAssetName(asset.name) == wanted)
                    {
                        debugf("Reusing remembered package %s as %s (layout unchanged)",
                                opts.packagePath, asset.name);
                        return asset.name;
                    }
                debugf("Remembered package %s not found; re-selecting", opts.packagePath);
            }
            else
                infof("Archive contents changed since last update; please re-select");
        }

        return filterAssets(repoName, usable).toString();
    }
}

// ---------------------------------------------------------------------------
// Archive introspection
// ---------------------------------------------------------------------------

/// Whether a path looks like a shared object (`.so` or `.so.N…`).
private bool isSharedLib(string path)
{
    const base = path.baseName;
    return base.endsWith(".so") || base.canFind(".so.");
}

/// Resolves the transitive DT_NEEDED closure of `binary` against the shared
/// libraries in the same archive, following symlinks. System libraries that
/// the archive does not ship are skipped.
Sidecar[string] collectLibClosure(ubyte[] binary, ubyte[][string] files, const string[string] links)
{
    ubyte[][string] fileByBase;
    foreach (path, data; files)
        if (isSharedLib(path))
            fileByBase[path.baseName] = data;
    string[string] linkByBase;
    foreach (path, target; links)
        if (isSharedLib(path))
            linkByBase[path.baseName] = target.baseName;

    Sidecar[string] result;
    bool[string] seen;
    string[] queue = importedLibraries(binary);

    while (queue.length > 0)
    {
        const base = queue[0];
        queue = queue[1 .. $];
        if (base.length == 0 || base in seen)
            continue;
        seen[base] = true;

        if (auto target = base in linkByBase)
        {
            result[base] = Sidecar(null, *target);
            queue ~= *target; // resolve the link target too
            continue;
        }
        if (auto data = base in fileByBase)
        {
            result[base] = Sidecar(*data, null);
            queue ~= importedLibraries(*data);
        }
        // Otherwise it is a system library not in the archive; skip it.
    }
    return result;
}

/// Whether the buffer is an executable object file.
bool isBinaryFile(const(ubyte)[] data)
{
    return isBinaryImage(data);
}

/// Whether the buffer is a supported archive or compression wrapper, so nested
/// archives stay selectable.
bool isCompressedFile(const(ubyte)[] data)
{
    return isCompressedKind(detect(data.length > 8192 ? data[0 .. 8192] : data));
}

/// Files geto can install from an archive — executables or nested archives.
/// Falls back to every file when nothing qualifies.
Asset[] installableCandidates(ubyte[][string] files)
{
    Asset[] keep;
    Asset[] all;
    foreach (name, data; files)
    {
        all ~= new Asset(name);
        if (isBinaryFile(data) || isCompressedFile(data))
            keep ~= new Asset(name);
    }
    return keep.length > 0 ? keep : all;
}

/// Whether geto can deal with this file extension.
bool isSupportedExt(string filename)
{
    auto ext = filename.extension;
    if (ext.startsWith("."))
        ext = ext[1 .. $];
    if (ext.length == 0)
        return true;

    // AppImage is installable here (isUsableAsset keeps it), so it has to be
    // scoreable too. Without this espanso's X11 AppImage was silently ignored
    // and its Windows zip won by default.
    foreach (native; resolver.osExtensions())
        if (ext == native.toLower)
            return true;

    switch (kindForExtension(ext))
    {
    case FileKind.msi:
    case FileKind.deb:
    case FileKind.rpm:
    case FileKind.asc:
        debugf("Filename %s doesn't have a supported extension", filename);
        return false;
    case FileKind.gz:
    case FileKind.unknown:
    case FileKind.zip:
    case FileKind.xz:
    case FileKind.tar:
    case FileKind.bz2:
    case FileKind.zst:
    case FileKind.exe:
        return true;
    default:
        debugf("Filename %s doesn't have a supported extension", filename);
        return false;
    }
}

// ---------------------------------------------------------------------------
// Package-name ranking
// ---------------------------------------------------------------------------

private FilteredAsset[] preferPackageName(FilteredAsset[] matches, string packageName)
{
    int best = 0;
    foreach (match; matches)
    {
        const rank = packageNameRank(match.name, packageName);
        if (rank > best)
            best = rank;
    }
    if (best == 0)
        return matches;
    return matches.filter!(match => packageNameRank(match.name, packageName) == best).array;
}

private int packageNameRank(string assetName, string packageName)
{
    auto nameTokens = assetTokens(assetName);
    auto packageTokens = assetTokens(packageName);
    if (packageTokens.length == 0 || nameTokens.length < packageTokens.length)
        return 0;

    foreach (i; 0 .. nameTokens.length - packageTokens.length + 1)
    {
        if (nameTokens[i .. i + packageTokens.length] != packageTokens)
            continue;
        if (i == 0)
        {
            if (nameTokens.length == packageTokens.length
                    || isPlatformOrVersionToken(nameTokens[packageTokens.length]))
                return 3;
            return 2;
        }
        return 1;
    }
    return 0;
}

private string[] assetTokens(string name)
{
    auto lower = name.toLower;
    bool isTar, isZip;
    const stem = archiveStem(lower, isTar, isZip);
    if (isTar || isZip)
        lower = stem;
    else
        foreach (suffix; [".appimage", ".exe"])
            if (lower.endsWith(suffix))
            {
                lower = lower[0 .. $ - suffix.length];
                break;
            }

    string[] result;
    foreach (token; lower.splitter(assetTokenRe))
        if (token.length > 0)
            result ~= token.to!string;
    return result;
}

/// True when the token is entirely a version, e.g. "1", "v2", "1.2.3".
private bool isVersionToken(string token)
{
    import std.ascii : isDigit;

    auto rest = token;
    if (rest.length > 1 && (rest[0] == 'v' || rest[0] == 'V'))
        rest = rest[1 .. $];
    if (rest.length == 0)
        return false;
    foreach (c; rest)
        if (!(c.isDigit || c == '.'))
            return false;
    return true;
}

private bool isPlatformOrVersionToken(string token)
{
    if (token.length == 0)
        return false;
    // The whole token has to look like a version. Matching anywhere inside it
    // made "pkcs11" read as one, so restish's pkcs11 build ranked level with
    // the plain binary instead of losing to it.
    if (isVersionToken(token))
        return true;
    switch (token)
    {
    case "linux", "windows", "win", "freebsd", "openbsd", "netbsd", "dragonfly", "unknown",
            "musl", "gnu", "glibc", "static", "amd64", "x86", "x64", "intel",
            "arm64", "aarch64", "arm", "386", "i386", "i686":
            return true;
    default:
        return false;
    }
}

// ---------------------------------------------------------------------------
// Naming
// ---------------------------------------------------------------------------

/// Strips OS, architecture and version noise out of a downloaded file name.
string sanitizeName(string name, string versionText)
{
    import std.array : replace;

    auto result = name.toLower;
    string[] pairs;

    bool firstPass = true;
    foreach (osName; resolver.os())
    {
        foreach (archName; resolver.arch())
        {
            pairs ~= [
                "_" ~ osName ~ archName, "-" ~ osName ~ archName,
                "." ~ osName ~ archName
            ];
            if (firstPass)
                pairs ~= ["_" ~ archName, "-" ~ archName, "." ~ archName];
        }
        pairs ~= ["_" ~ osName, "-" ~ osName, "." ~ osName];
        firstPass = false;
    }

    auto bare = versionText.startsWith("v") ? versionText[1 .. $] : versionText;
    pairs ~= ["_" ~ versionText, "_" ~ bare, "-" ~ versionText, "-" ~ bare];

    foreach (needle; pairs)
        if (needle.length > 1)
            result = result.replace(needle, "");
    return result;
}

version (unittest)
{
    private PlatformResolver fakeResolver(string[] os, string[] arch, string[] extensions)
    {
        return PlatformResolver(() => os, () => arch, () => extensions);
    }

    private auto linuxAmd64()
    {
        return fakeResolver(["linux"], ["amd64", "x86_64", "x64", "64"], [
            "AppImage"
        ]);
    }

    private auto linuxArm64()
    {
        return fakeResolver(["linux"], [
            "arm64", "aarch64", "arm_64", "arm-64", "armv8"
        ], ["AppImage"]);
    }

    /// What geto's own release publishes, so its naming stays self-installable.
    private Asset[] getoAssets()
    {
        return assetsNamed([
            "SHA256SUMS", "geto_linux_amd64.tar.gz", "geto_linux_arm64.tar.gz",
        ]);
    }

    private auto windowsAmd64()
    {
        return fakeResolver(["windows", "win"], ["amd64", "x86_64", "x64", "64"], [
            "exe"
        ]);
    }

    private Asset[] assetsNamed(const string[] names)
    {
        Asset[] result;
        foreach (name; names)
            result ~= new Asset(name, "", "https://example/" ~ name);
        return result;
    }

    /// The openai/codex release layout, which stresses the sibling-artifact rules.
    private Asset[] codexAssets(string versionText)
    {
        return assetsNamed([
            "codex-app-server-package-x86_64-unknown-linux-musl.tar.gz",
            "codex-app-server-x86_64-unknown-linux-musl.sigstore",
            "codex-app-server-x86_64-unknown-linux-musl.tar.gz",
            "codex-npm-linux-x64-" ~ versionText ~ ".tgz",
            "codex-package-x86_64-unknown-linux-musl.tar.gz",
            "codex-responses-api-proxy-x86_64-unknown-linux-musl.sigstore",
            "codex-responses-api-proxy-x86_64-unknown-linux-musl.tar.gz",
            "codex-symbols-x86_64-unknown-linux-musl-app-server.tar.gz",
            "codex-symbols-x86_64-unknown-linux-musl.tar.gz",
            "codex-x86_64-unknown-linux-musl.sigstore",
            "codex-x86_64-unknown-linux-musl.tar.gz",
            "codex-zsh-x86_64-unknown-linux-musl.tar.gz",
            "openai_codex_cli_bin-" ~ versionText ~ "-py3-none-manylinux_2_17_x86_64.whl",
        ]);
    }
}

unittest
{
    scope (exit)
        resetResolver();

    // --- name normalization -------------------------------------------------
    assert(normalizeAssetName("bat-v0.24.0-x86_64-linux.tar.gz") == "bat-v#-x#_#-linux.tar.gz");
    assert(fingerprint([new Asset("b.tar.gz"), new Asset("a.zip")]) == [
        "a.zip", "b.tar.gz"
    ]);

    // Same asset across releases must normalize equal.
    assert(normalizeAssetName("codex-npm-linux-x64-0.140.0.tgz") == normalizeAssetName(
            "codex-npm-linux-x64-0.141.0.tgz"));
    assert(normalizeAssetName("tool-v1.2.3-linux") == normalizeAssetName("tool-v9.0.0-linux"));
    assert(normalizeAssetName("codex-x86_64-unknown-linux-musl.tar.gz") != normalizeAssetName(
            "codex-zsh-x86_64-unknown-linux-musl.tar.gz"));

    // --- usability ----------------------------------------------------------
    setResolver(linuxAmd64());
    foreach (name; [
        "codex-x86_64-unknown-linux-musl.tar.gz",
        "codex-npm-linux-x64-0.140.0.tgz", "jq-linux64", "tool-v0.140.0",
        "Ultimaker_Cura-4.8.0.AppImage",
    ])
        assert(isUsableAsset(name), name);
    foreach (name; [
        "codex-x86_64-unknown-linux-musl.sigstore",
        "openai_codex_cli_bin-0.140.0-py3-none-manylinux_2_17_x86_64.whl",
        "checksums.txt", "codex.tar.gz.sha256", "release.sbom.json", "pkg.deb",
        "tool-update", "SHA256SUMS", "sha512sums", "MD5SUMS", "checksums",
        "blake3sums",
    ])
        assert(!isUsableAsset(name), name);

    // --- geto installs itself ------------------------------------------------
    // The release publishes one archive per architecture next to a checksum
    // file. Each host has to land on its own archive with nothing left to ask
    // the user about, or `geto install termworks/geto` would stop to prompt.
    setResolver(linuxAmd64());
    auto ownAmd64 = narrowToPlatform(filterUsableAssets(getoAssets()));
    assert(ownAmd64.length == 1 && ownAmd64[0].name == "geto_linux_amd64.tar.gz",
            fingerprint(ownAmd64).join(", "));

    setResolver(linuxArm64());
    auto ownArm64 = narrowToPlatform(filterUsableAssets(getoAssets()));
    assert(ownArm64.length == 1 && ownArm64[0].name == "geto_linux_arm64.tar.gz",
            fingerprint(ownArm64).join(", "));

    setResolver(linuxAmd64());
    assert(isSupportedExt("tool.tar.gz"));
    assert(!isSupportedExt("tool.deb"));
    assert(!isSupportedExt("tool.png"));

    bool isTar, isZip;
    assert(archiveStem("Tool.TAR.GZ", isTar, isZip) == "tool" && isTar);

    // --- preference rules ---------------------------------------------------
    assert(preferMusl(assetsNamed([
        "tool-linux-amd64-musl.tar.gz", "tool-linux-amd64-gnu.tar.gz"
    ])).length == 1);

    assert(packageNameRank("bat-v0.24.0-x86_64-linux.tar.gz", "bat") == 3);
    assert(packageNameRank("ripgrep.tar.gz", "bat") == 0);
}

unittest
{
    scope (exit)
        resetResolver();

    // Scoring must land on the host's asset without prompting.
    static struct Case
    {
        string repo;
        string[] names;
        string expected;
        bool windows;
    }

    const cases = [
        Case("bin", [
            "bin_0.0.1_Linux_x86_64", "bin_0.0.1_Linux_i386",
            "bin_0.0.1_Darwin_x86_64"
        ], "bin_0.0.1_Linux_x86_64", false),
        Case("gitlab-runner", [
            "gitlab-runner-windows-amd64", "gitlab-runner-linux-amd64",
            "gitlab-runner-darwin-amd64"
        ], "gitlab-runner-linux-amd64", false),
        Case("yq", [
            "yq_freebsd_amd64", "yq_linux_amd64", "yq_windows_amd64.exe"
        ], "yq_linux_amd64", false),
        Case("jq", ["jq-win64.exe", "jq-linux64", "jq-osx-amd64"], "jq-linux64", false),
        Case("tezos", ["x86_64-linux-tezos-binaries.tar.gz"],
                "x86_64-linux-tezos-binaries.tar.gz", false),
        Case("launchpad", ["launchpad-linux-x64", "launchpad-win-x64.exe"],
                "launchpad-linux-x64", false),
        Case("usql", [
            "usql-0.8.2-darwin-amd64.tar.bz2",
            "usql-0.8.2-linux-amd64.tar.bz2", "usql-0.8.2-windows-amd64.zip"
        ], "usql-0.8.2-linux-amd64.tar.bz2", false),
        Case("cli", ["dapr"], "dapr", false),
        Case("launchpad", ["launchpad-linux-x64", "launchpad-win-x64.exe"],
                "launchpad-win-x64.exe", true),
        Case("bin", [
            "bin_0.0.1_Windows_x86_64.exe", "bin_0.1.0_Linux_x86_64",
            "bin_0.1.0_Darwin_x86_64"
        ], "bin_0.0.1_Windows_x86_64.exe", true),
        Case("usql", [
            "usql-0.8.2-darwin-amd64.tar.bz2",
            "usql-0.8.2-linux-amd64.tar.bz2", "usql-0.8.2-windows-amd64.zip"
        ], "usql-0.8.2-windows-amd64.zip", true),
    ];

    foreach (testCase; cases)
    {
        setResolver(testCase.windows ? windowsAmd64() : linuxAmd64());
        auto filter = new Filter(FilterOpts.init);
        auto chosen = filter.filterAssets(testCase.repo, assetsNamed(testCase.names));
        assert(chosen.name == testCase.expected,
                testCase.repo ~ ": got " ~ chosen.name ~ ", want " ~ testCase.expected);
    }
}

unittest
{
    scope (exit)
        resetResolver();
    setResolver(linuxAmd64());

    const chosen = "codex-app-server-x86_64-unknown-linux-musl.tar.gz";
    // The fingerprint has to come off the same narrowed set selectReleaseAsset
    // records, or a pure version bump looks like a layout change.
    auto marks = fingerprint(narrowToPlatform(filterUsableAssets(codexAssets("0.140.0"))));

    // A pure version bump keeps the layout, so the remembered choice is reused
    // and the user is never prompted.
    FilterOpts opts;
    opts.selectedAsset = normalizeAssetName(chosen);
    opts.assetFingerprint = marks;
    auto filter = new Filter(opts);
    assert(filter.selectReleaseAsset("codex", codexAssets("0.141.0")).name == chosen);

    // A genuinely new installable file changes the fingerprint, which is what
    // forces the re-prompt.
    auto extended = codexAssets("0.141.0") ~ new Asset(
            "codex-extra-x86_64-unknown-linux-musl.tar.gz");
    assert(fingerprint(narrowToPlatform(filterUsableAssets(extended))) != marks);
}

unittest
{
    scope (exit)
        resetResolver();

    setResolver(linuxAmd64());
    assert(sanitizeName("bin_amd64_linux", "v0.0.1") == "bin");
    assert(sanitizeName("bin_0.0.1_amd64_linux", "0.0.1") == "bin");
    assert(sanitizeName("bin_0.0.1_amd64_linux", "v0.0.1") == "bin");
    assert(sanitizeName("gitlab-runner-linux-amd64", "v13.2.1") == "gitlab-runner");
    assert(sanitizeName("jq-linux64", "jq-1.5") == "jq");
    assert(sanitizeName("launchpad-linux-x64", "1.2.0-rc.1") == "launchpad");

    setResolver(windowsAmd64());
    assert(sanitizeName("launchpad-win-x64.exe", "1.2.0-rc.1") == "launchpad.exe");
    assert(sanitizeName("bin_0.0.1_Windows_x86_64.exe", "0.0.1") == "bin.exe");
}

unittest
{
    // Word-boundary matching: the short arch aliases must not fire inside a
    // longer word, which is what made "linux64" read as an explicit x64 build.
    assert("jq-linux-amd64".containsToken("amd64"));
    assert("ffsend-linux-x64".containsToken("x64"));
    assert(!"jq-linux64".containsToken("x64"));
    assert("jq-linux64".containsToken("linux"));
    assert("tool-x86_64".containsToken("x86_64"));

    // A version token has to be a version all the way through; "pkcs11" is not.
    assert(isVersionToken("1") && isVersionToken("v2") && isVersionToken("1.2.3"));
    assert(!isVersionToken("pkcs11") && !isVersionToken("armv7") && !isVersionToken(""));
}

unittest
{
    scope (exit)
        resetResolver();
    setResolver(linuxAmd64());

    // Foreign operating systems are recognised by name, and an asset that
    // names none at all counts as usable here.
    assert(hasForeignOs("Espanso-Win-Portable-x86_64.zip"));
    assert(hasForeignOs("flawz-x86_64-apple-darwin.tar.xz"));
    assert(!hasForeignOs("Espanso-X11.AppImage"));
    assert(!hasForeignOs("mprober_x86_64"));
    assert(allForeignOs(assetsNamed([
        "flawz-x86_64-apple-darwin.tar.xz", "flawz-x86_64-pc-windows-msvc.zip"
    ])));
    assert(!allForeignOs(assetsNamed(["tool-linux-amd64", "tool-windows.zip"])));

    // An AppImage is installable on Linux, so it has to be scoreable too.
    assert(isSupportedExt("Espanso-X11.AppImage"));
}

unittest
{
    scope (exit)
        resetResolver();
    setResolver(linuxAmd64());

    static struct Case
    {
        string repo;
        string[] assets;
        string expected;
    }

    // Real releases that the Go build either mis-picked or had to ask about.
    const cases = [
        // Picked the Windows zip because nothing penalised a foreign OS and
        // the AppImage was excluded from scoring.
        Case("espanso", [
            "espanso-debian-wayland-amd64.deb", "espanso-debian-x11-amd64.deb",
            "Espanso-Mac-Universal.dmg", "Espanso-Win-Installer-x86_64.exe",
            "Espanso-Win-Portable-x86_64.zip", "Espanso-X11.AppImage"
        ], "Espanso-X11.AppImage"),
        // "linux64" contained the x64 alias, so it tied with the real amd64 build.
        Case("jq", [
            "jq-linux-amd64", "jq-linux64", "jq-linux-arm64", "jq-macos-amd64",
            "jq-win64.exe", "sha256sum.txt"
        ], "jq-linux-amd64"),
        // The source archive scored level with the binary.
        Case("hck", [
            "hck-linux-amd64", "hck-linux-amd64-src.tar.gz",
            "hck-linux-amd64.deb", "hck-macos-amd64", "hck-windows-amd64.exe"
        ], "hck-linux-amd64"),
        // Static and dynamic twins tied.
        Case("ffsend", [
            "ffsend-v0.2.77-linux-x64", "ffsend-v0.2.77-linux-x64-static"
        ], "ffsend-v0.2.77-linux-x64-static"),
        // "gcc" marks a glibc build, so it never grouped against the musl one.
        Case("vopono", [
            "vopono-gui_0.10.22_linux_x86-64_gcc", "vopono_0.10.22_amd64.deb",
            "vopono_0.10.22_linux_aarch64", "vopono_0.10.22_linux_x86-64_gcc",
            "vopono_0.10.22_linux_x86-64_musl"
        ], "vopono_0.10.22_linux_x86-64_musl"),
        // "pkcs11" was read as a version, ranking the plugin build level with
        // the plain binary.
        Case("restish", [
            "restish-2.3.0-linux-amd64.tar.gz",
            "restish-bulk-2.3.0-linux-amd64.tar.gz",
            "restish-pkcs11-2.3.0-linux-amd64.tar.gz",
            "restish-2.3.0-darwin-amd64.tar.gz", "restish-2.3.0-windows-amd64.zip"
        ], "restish-2.3.0-linux-amd64.tar.gz"),
        // Releases that already worked must keep working.
        Case("bat", [
            "bat-v0.26.1-x86_64-unknown-linux-musl.tar.gz",
            "bat-v0.26.1-x86_64-unknown-linux-gnu.tar.gz",
            "bat-v0.26.1-x86_64-apple-darwin.tar.gz",
            "bat-v0.26.1-x86_64-pc-windows-msvc.zip", "bat_0.26.1_amd64.deb"
        ], "bat-v0.26.1-x86_64-unknown-linux-musl.tar.gz"),
        Case("syncthing", [
            "syncthing-linux-amd64-v2.1.3.tar.gz",
            "syncthing-linux-arm64-v2.1.3.tar.gz",
            "syncthing-macos-universal-v2.1.3.zip",
            "syncthing-windows-amd64-v2.1.3.zip"
        ], "syncthing-linux-amd64-v2.1.3.tar.gz"),
        Case("mprober", ["mprober_x86_64", "mprober_aarch64"], "mprober_x86_64"),
    ];

    foreach (testCase; cases)
    {
        string chosen;
        string[] options;
        preview(testCase.repo, testCase.assets, chosen, options);
        assert(chosen == testCase.expected, testCase.repo ~ ": chose " ~ (chosen.length
                ? chosen : "<prompt>") ~ ", want " ~ testCase.expected);
    }

    // A release with no build for this platform reports nothing at all rather
    // than offering a macOS or Windows artefact.
    string chosen;
    string[] options;
    preview("flawz", [
        "flawz-aarch64-apple-darwin.tar.xz", "flawz-x86_64-apple-darwin.tar.xz",
        "flawz-x86_64-pc-windows-msvc.zip", "flawz-x86_64-pc-windows-msvc.msi",
        "flawz-installer.sh", "flawz-installer.ps1", "source.tar.gz"
    ], chosen, options);
    assert(chosen.length == 0 && options.length == 0);
}

unittest
{
    scope (exit)
        resetResolver();
    setResolver(linuxAmd64());

    static struct Case
    {
        string repo;
        string[] assets;
        string expected;
        string why;
    }

    const cases = [
        // Accelerator flavours are not the default build.
        Case("ollama", [
            "ollama-linux-amd64.tar.zst", "ollama-linux-amd64-mlx.tar.zst",
            "ollama-linux-amd64-rocm.tar.zst"
        ], "ollama-linux-amd64.tar.zst", "variant builds lose to the plain one"),
        // musl wins even when the sibling names no libc at all.
        Case("opencode", [
            "opencode-linux-x64-musl.tar.gz", "opencode-linux-x64.tar.gz",
            "opencode-linux-x64-baseline-musl.tar.gz",
            "opencode-linux-x64-baseline.tar.gz"
        ], "opencode-linux-x64-musl.tar.gz", "musl beats an unmarked sibling"),
        // Architectures beyond x86/arm are recognised as foreign.
        Case("micromamba", [
            "micromamba-linux-64.tar.bz2", "micromamba-linux-aarch64.tar.bz2",
            "micromamba-linux-ppc64le.tar.bz2"
        ], "micromamba-linux-64.tar.bz2", "ppc64le is a foreign architecture"),
        // A bare compressed blob is the same payload as the tar beside it.
        Case("codex", [
            "codex-x86_64-unknown-linux-musl.tar.gz",
            "codex-x86_64-unknown-linux-musl.zst"
        ], "codex-x86_64-unknown-linux-musl.tar.gz", "tar wins over a bare blob"),
        // Identical builds in two compressions need no question.
        Case("goose", [
            "goose-x86_64-unknown-linux-musl.tar.bz2",
            "goose-x86_64-unknown-linux-musl.tar.gz"
        ], "goose-x86_64-unknown-linux-musl.tar.gz", "gz is the common choice"),
        // Distribution packages are not standalone binaries.
        Case("git-town", [
            "git-town_linux_intel_64.pkg.tar.zst",
            "git-town_linux_intel_64.tar.gz"
        ], "git-town_linux_intel_64.tar.gz", "an Arch package is not a binary"),
    ];

    foreach (testCase; cases)
    {
        string chosen;
        string[] options;
        preview(testCase.repo, testCase.assets, chosen, options);
        assert(chosen == testCase.expected, testCase.repo ~ " (" ~ testCase.why ~ "): chose " ~ (chosen.length
                ? chosen : "<prompt>") ~ ", want " ~ testCase.expected);
    }

    // Genuinely different builds still deserve a question.
    string chosen;
    string[] options;
    preview("spotifyd", [
        "spotifyd-linux-x86_64-default.tar.gz",
        "spotifyd-linux-x86_64-full.tar.gz", "spotifyd-linux-x86_64-slim.tar.gz"
    ], chosen, options);
    assert(chosen.length == 0 && options.length == 3);
}
