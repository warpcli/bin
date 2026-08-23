module geto.providers.github;

import std.json : parseJSON;
import std.process : environment;

import geto.assets : Asset, Filter, normalizeAssetName;
import geto.http : get, getOrThrow;
import geto.jsonutil;
import geto.log;
import geto.providers;

/// Installs from GitHub releases, including GitHub Enterprise Server.
final class GitHub : Provider
{
    private string url;
    private string apiBase;
    private string owner;
    private string repo;
    private string tag;
    private string token;

    this(string url, string apiBase, string owner, string repo, string tag, string token)
    {
        this.url = url;
        this.apiBase = apiBase;
        this.owner = owner;
        this.repo = repo;
        this.tag = tag;
        this.token = token;
    }

    private string[string] authHeaders()
    {
        string[string] headers = ["Accept": "application/vnd.github+json"];
        if (token.length > 0)
            headers["Authorization"] = "token " ~ token;
        return headers;
    }

    private string repoUrl()
    {
        return apiBase ~ "/repos/" ~ owner ~ "/" ~ repo;
    }

    File fetch(FetchOpts opts)
    {
        if (opts.versionText.length > 0)
            tag = opts.versionText;

        string endpoint;
        if (tag.length > 0)
        {
            debugf("Getting %s release for %s/%s", tag, owner, repo);
            endpoint = repoUrl() ~ "/releases/tags/" ~ tag;
        }
        else
        {
            debugf("Getting latest release for %s/%s", owner, repo);
            endpoint = repoUrl() ~ "/releases/latest";
        }

        auto response = get(endpoint, authHeaders());
        if (response.status == 404)
            throw new ProviderException("repository " ~ owner ~ "/" ~ repo
                    ~ " does not have releases");
        if (!response.ok)
            throw new ProviderException("GitHub returned " ~ response.status.stringOf
                    ~ " for " ~ endpoint);

        auto release = parseJSON(response.text);
        Asset[] candidates;
        foreach (asset; release.jitems("assets"))
            candidates ~= new Asset(asset.jstr("name"), "", asset.jstr("url"));

        auto filter = new Filter(toFilterOpts(opts));
        auto chosen = filter.selectReleaseAsset(repo, candidates);

        chosen.extraHeaders = ["Accept": "application/octet-stream"];
        if (token.length > 0)
            chosen.extraHeaders["Authorization"] = "token " ~ token;

        auto unpacked = filter.processUrl(chosen);

        File result;
        result.data = unpacked.data;
        result.name = unpacked.name;
        result.versionText = release.jstr("tag_name");
        result.packagePath = unpacked.packagePath;
        result.packageFingerprint = unpacked.packageFingerprint;
        result.selectedAsset = normalizeAssetName(chosen.name);
        result.assetFingerprint = chosen.fingerprint;
        result.libs = unpacked.sidecars;
        return result;
    }

    void latestVersion(out string tagName, out string htmlUrl)
    {
        debugf("Getting latest release for %s/%s", owner, repo);
        auto response = getOrThrow(repoUrl() ~ "/releases/latest", authHeaders());
        auto release = parseJSON(response.text);
        tagName = release.jstr("tag_name");
        htmlUrl = release.jstr("html_url");
    }

    string id()
    {
        return "github";
    }

    string description()
    {
        auto response = getOrThrow(repoUrl(), authHeaders());
        auto payload = parseJSON(response.text);
        return payload.jstr("description").idup;
    }
}

private string stringOf(ushort value)
{
    import std.conv : to;

    return value.to!string;
}

/// Builds a GitHub provider from a repository or release URL.
Provider newGitHub(string url)
{
    string owner, repo;
    ownerAndRepo(url, "GitHub", owner, repo);
    const tag = tagFromPath(url, 2);

    auto token = environment.get("GITHUB_AUTH_TOKEN", "");
    if (token.length == 0)
        token = environment.get("GITHUB_TOKEN", "");

    // GitHub Enterprise Server is configured entirely through the environment.
    const enterpriseBase = environment.get("GHES_BASE_URL", "");
    const enterpriseUpload = environment.get("GHES_UPLOAD_URL", "");
    const enterpriseToken = environment.get("GHES_AUTH_TOKEN", "");

    string apiBase = "https://api.github.com";
    if (enterpriseBase.length > 0 && enterpriseUpload.length > 0 && enterpriseToken.length > 0)
    {
        apiBase = enterpriseBase.length > 0 && enterpriseBase[$ - 1] == '/'
            ? enterpriseBase[0 .. $ - 1] : enterpriseBase;
        token = enterpriseToken;
    }

    return new GitHub(url, apiBase, owner, repo, tag, token);
}
