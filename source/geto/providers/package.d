module geto.providers;

import std.digest.sha : SHA256, digest;
import std.string : startsWith;

import geto.assets : FilterOpts, Sidecar;
import geto.config : urlHost, urlPath;

public import geto.providers.codeberg : newCodeberg;
public import geto.providers.github : newGitHub;
public import geto.providers.gitlab : newGitLab;
public import geto.providers.goinstall : newGoInstall;
public import geto.providers.hashicorp : newHashiCorp;

/// Raised when no provider can handle a URL, or a provider request fails.
class ProviderException : Exception
{
    this(string message, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
    }
}

/// The downloaded, unpacked binary plus everything worth remembering about it.
struct File
{
    ubyte[] data;
    string name;
    string versionText;
    string packagePath;
    /// Version-normalized name of the chosen release asset.
    string selectedAsset;
    /// Normalized set of installable assets.
    string[] assetFingerprint;
    /// Normalized set of inner-archive files.
    string[] packageFingerprint;
    /// Extracted shared-library dependencies.
    Sidecar[string] libs;

    ubyte[] hash() const
    {
        return digest!SHA256(data).dup;
    }
}

/// Inputs for one fetch.
struct FetchOpts
{
    bool all;
    string packageName;
    string packagePath;
    bool skipPatchCheck;
    string versionText;
    /// Remembered asset choice.
    string selectedAsset;
    /// Remembered set of assets.
    string[] assetFingerprint;
    bool recheck;
    /// Exact asset choice.
    string wantedAsset;
    /// Exact package-path choice.
    string wantedPackagePath;
    /// Remembered inner-archive file set.
    string[] packageFingerprint;
    /// Fail rather than prompt for a selection.
    bool nonInteractive;
    /// Extract shared-library dependencies alongside the binary.
    bool collectLibs;
}

/// A release source geto can install from.
interface Provider
{
    /// Downloads and unpacks the requested release.
    File fetch(FetchOpts opts);

    /// The latest version tag and a URL describing it.
    void latestVersion(out string tag, out string url);

    /// The provider's stable identifier.
    string id();

    /// The upstream repository description, or "" when unsupported.
    string description();
}

/// Translates fetch options into the asset filter's options.
package FilterOpts toFilterOpts(FetchOpts opts)
{
    FilterOpts result;
    result.skipScoring = opts.all;
    result.packagePath = opts.packagePath;
    result.packageFingerprint = opts.packageFingerprint;
    result.skipPathCheck = opts.skipPatchCheck;
    result.packageName = opts.packageName;
    result.selectedAsset = opts.selectedAsset;
    result.assetFingerprint = opts.assetFingerprint;
    result.recheck = opts.recheck;
    result.wantedAsset = opts.wantedAsset;
    result.wantedPackagePath = opts.wantedPackagePath;
    result.nonInteractive = opts.nonInteractive;
    result.collectLibs = opts.collectLibs;
    return result;
}

/// Resolves a URL (and optional recorded provider name) to a provider.
Provider newProvider(string url, string provider)
{
    import std.algorithm : canFind;

    if (url.startsWith("goinstall://") || provider == "goinstall")
        return newGoInstall(url);

    auto target = url;
    if (!target.startsWith("http://") && !target.startsWith("https://"))
        target = "https://" ~ target;

    const host = urlHost(target);
    if (host.canFind("github") || provider == "github")
        return newGitHub(target);
    if (host.canFind("gitlab") || provider == "gitlab")
        return newGitLab(target);
    if (host.canFind("codeberg") || provider == "codeberg")
        return newCodeberg(target);
    if (host.canFind("releases.hashicorp.com") || provider == "hashicorp")
        return newHashiCorp(target);

    throw new ProviderException("can't find provider for url " ~ url);
}

/// Splits a repository URL path into owner and repo, throwing when it is short.
package void ownerAndRepo(string url, string label, out string owner, out string repo)
{
    import std.array : split;

    auto parts = urlPath(url).split('/');
    if (parts.length < 3)
        throw new ProviderException(
                "error parsing " ~ label ~ " URL " ~ url ~ ", can't find owner and repo");
    owner = parts[1];
    repo = parts[2];
}

/// Extracts a release tag embedded in a `/releases/...` URL path.
package string tagFromPath(string url, size_t skip)
{
    import std.array : join, split;

    auto path = urlPath(url);
    if (!path.canFind("/releases/"))
        return "";
    auto parts = path.split('/');
    foreach (i, part; parts)
        if (part == "releases" && i + skip < parts.length)
            return parts[i + skip .. $].join("/");
    return "";
}

private bool canFind(string haystack, string needle)
{
    import std.algorithm : canFind;

    return haystack.canFind(needle);
}

unittest
{
    string owner, repo;
    ownerAndRepo("https://github.com/sharkdp/bat", "GitHub", owner, repo);
    assert(owner == "sharkdp" && repo == "bat");

    assert(tagFromPath("https://github.com/o/r/releases/tag/v1.2.3", 2) == "v1.2.3");
    assert(tagFromPath("https://gitlab.com/o/r/releases/v1.2.3", 1) == "v1.2.3");
    assert(tagFromPath("https://github.com/o/r", 2) == "");
}
