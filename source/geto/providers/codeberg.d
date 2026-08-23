module geto.providers.codeberg;

import std.json : parseJSON;
import std.process : environment;

import geto.assets : Asset, Filter, normalizeAssetName;
import geto.config : urlHost;
import geto.http : get, getOrThrow;
import geto.jsonutil;
import geto.log;
import geto.providers;

/// Installs from a Gitea-compatible forge such as Codeberg.
final class Codeberg : Provider
{
    private string apiBase;
    private string owner;
    private string repo;
    private string tag;
    private string token;

    this(string apiBase, string owner, string repo, string tag, string token)
    {
        this.apiBase = apiBase;
        this.owner = owner;
        this.repo = repo;
        this.tag = tag;
        this.token = token;
    }

    private string[string] authHeaders()
    {
        string[string] headers;
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
            throw new ProviderException("Codeberg request failed for " ~ endpoint);

        auto release = parseJSON(response.text);
        Asset[] candidates;
        foreach (attachment; release.jitems("assets"))
            candidates ~= new Asset(attachment.jstr("name"), "",
                    attachment.jstr("browser_download_url"));

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
        return "codeberg";
    }

    string description()
    {
        auto response = getOrThrow(repoUrl(), authHeaders());
        auto payload = parseJSON(response.text);
        return payload.jstr("description").idup;
    }
}

/// Builds a Codeberg provider from a repository or release URL.
Provider newCodeberg(string url)
{
    string owner, repo;
    ownerAndRepo(url, "Codeberg", owner, repo);
    const tag = tagFromPath(url, 2);
    const token = environment.get("CODEBERG_TOKEN", "");
    const apiBase = "https://" ~ urlHost(url) ~ "/api/v1";
    return new Codeberg(apiBase, owner, repo, tag, token);
}
