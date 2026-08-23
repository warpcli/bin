module geto.providers.hashicorp;

import std.algorithm : sort;
import std.array : split;
import std.json : JSONType, parseJSON;

import geto.assets : Asset, Filter, normalizeAssetName;
import geto.config : urlPath;
import geto.http : getOrThrow;
import geto.jsonutil;
import geto.log;
import geto.providers;
import geto.ui.select : selectOne;
import geto.vers : StrictVersion, compareStrict, parseStrictVersion;

private enum releasesUrlBase = "https://releases.hashicorp.com";

/// Installs from the HashiCorp releases index.
final class HashiCorp : Provider
{
    private string repo;
    private string tag;

    this(string repo, string tag)
    {
        this.repo = repo;
        this.tag = tag;
    }

    private string indexUrl(string[] segments...)
    {
        auto url = releasesUrlBase;
        foreach (segment; segments)
            url ~= "/" ~ segment;
        return url ~ "/index.json";
    }

    File fetch(FetchOpts opts)
    {
        if (opts.versionText.length > 0)
            tag = opts.versionText;

        string wanted = tag;
        if (wanted.length == 0)
        {
            string url;
            latestVersion(wanted, url);
        }
        else
            debugf("Getting %s release for %s", wanted, repo);

        auto response = getOrThrow(indexUrl(repo, wanted));
        auto release = parseJSON(response.text);

        Asset[] candidates;
        foreach (build; release.jitems("builds"))
            candidates ~= new Asset(build.jstr("filename"), "", build.jstr("url"));

        auto filter = new Filter(toFilterOpts(opts));
        auto chosen = filter.selectReleaseAsset(repo, candidates);
        auto unpacked = filter.processUrl(chosen);

        File result;
        result.data = unpacked.data;
        result.name = unpacked.name;
        result.versionText = release.jstr("version");
        result.packagePath = unpacked.packagePath;
        result.packageFingerprint = unpacked.packageFingerprint;
        result.selectedAsset = normalizeAssetName(chosen.name);
        result.assetFingerprint = chosen.fingerprint;
        result.libs = unpacked.sidecars;
        return result;
    }

    void latestVersion(out string tagName, out string url)
    {
        debugf("Getting latest release for %s", repo);
        auto response = getOrThrow(indexUrl(repo));
        auto repoIndex = parseJSON(response.text);

        auto versionsNode = repoIndex.jobject("versions");
        if (versionsNode.type != JSONType.object || versionsNode.objectNoRef.length == 0)
            throw new ProviderException("no releases found for " ~ repo);

        StrictVersion[] releases;
        foreach (_, entry; versionsNode.objectNoRef)
        {
            const text = entry.jstr("version");
            StrictVersion parsed;
            if (!parseStrictVersion(text, parsed))
            {
                debugf("unable to parse %s as a semantic version", text);
                continue;
            }
            if (parsed.preRelease.length == 0 && parsed.metadata.length == 0)
                releases ~= parsed;
        }
        if (releases.length == 0)
            throw new ProviderException("no semver versions found for " ~ repo);

        releases.sort!((a, b) => compareStrict(a, b) < 0);
        auto highest = releases[$ - 1];

        // Distinct strings can compare equal (for example 1.2.3 and 1.02.3),
        // in which case the user picks.
        string[] tied;
        foreach_reverse (candidate; releases)
            if (compareStrict(candidate, highest) == 0 && !tied.contains(candidate.original))
                tied ~= candidate.original;
        if (tied.length > 1)
        {
            tied.sort();
            tagName = tied[selectOne("Select file to download:", tied)];
        }
        else
            tagName = highest.original;

        auto release = parseJSON(getOrThrow(indexUrl(repo, tagName)).text);
        tagName = release.jstr("version");
        url = indexUrl(repo, tagName);
    }

    string id()
    {
        return "hashicorp";
    }

    string description()
    {
        return "";
    }
}

private bool contains(const string[] haystack, string needle)
{
    foreach (item; haystack)
        if (item == needle)
            return true;
    return false;
}

/// Builds a HashiCorp provider from a releases URL.
Provider newHashiCorp(string url)
{
    auto parts = urlPath(url).split('/');
    if (parts.length < 2 || parts[1].length == 0)
        throw new ProviderException("error parsing HashiCorp releases URL " ~ url
                ~ ", can't find repo");
    const tag = parts.length >= 3 ? parts[2] : "";
    return new HashiCorp(parts[1], tag);
}
