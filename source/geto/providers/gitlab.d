module geto.providers.gitlab;

import std.algorithm : sort, startsWith;
import std.array : replace;
import std.json : parseJSON;
import std.process : environment;

import geto.assets : Asset, Filter, normalizeAssetName;
import geto.config : urlHost;
import geto.http : get, getOrThrow;
import geto.jsonutil;
import geto.log;
import geto.markdown : inlineLinks;
import geto.providers;
import geto.vers : StrictVersion, compareStrict, parseStrictVersion;

/// Installs from GitLab releases, package registries and description links.
final class GitLab : Provider
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
            headers["PRIVATE-TOKEN"] = token;
        return headers;
    }

    private string projectPath()
    {
        return owner ~ "/" ~ repo;
    }

    private string projectUrl()
    {
        return apiBase ~ "/projects/" ~ urlEscape(projectPath());
    }

    File fetch(FetchOpts opts)
    {
        if (opts.versionText.length > 0)
            tag = opts.versionText;

        string wanted = tag;
        if (wanted.length == 0)
        {
            debugf("Getting latest release for %s/%s", owner, repo);
            string url;
            latestVersion(wanted, url);
        }
        else
            debugf("Getting %s release for %s/%s", wanted, owner, repo);

        auto release = parseJSON(getOrThrow(projectUrl() ~ "/releases/" ~ urlEscape(wanted),
                authHeaders()).text);
        auto project = parseJSON(getOrThrow(projectUrl(), authHeaders()).text);

        const visibility = project.jstr("visibility");
        const projectIsPublic = token.length == 0 || visibility.length == 0 || visibility == "public";
        debugf("Project is public: %s", projectIsPublic);

        Asset[] candidates;
        bool[string] seen;

        void addCandidate(string name, string displayName, string url)
        {
            if (url in seen)
                return;
            seen[url] = true;
            auto asset = new Asset(name, displayName, url);
            candidates ~= asset;
            debugf("Adding %s with URL %s", asset.toString(), url);
        }

        if (projectIsPublic || project.jbool("packages_enabled"))
            collectPackageFiles(release.jstr("tag_name"), &addCandidate);

        const uploadsPrefix = project.jstr("web_url") ~ "/uploads/";
        auto assetsNode = release.jobject("assets");
        foreach (link; assetsNode.jitems("links"))
        {
            const url = link.jstr("url");
            if (projectIsPublic || !url.startsWith(uploadsPrefix))
                addCandidate(link.jstr("name"), link.jstr("name") ~ " (asset link)", url);
        }

        foreach (link; inlineLinks(release.jstr("description")))
        {
            // The Go build keyed this off the markdown title attribute; keeping
            // that means links without one stay unnamed.
            if (projectIsPublic || !link.destination.startsWith(uploadsPrefix))
                addCandidate(link.title,
                        link.title ~ " (from release description)", link.destination);
        }

        auto filter = new Filter(toFilterOpts(opts));
        auto chosen = filter.selectReleaseAsset(repo, candidates);
        if (token.length > 0)
            chosen.extraHeaders["PRIVATE-TOKEN"] = token;

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

    /// Adds every file of the package whose version matches the release tag.
    private void collectPackageFiles(string tagName, void delegate(string,
            string, string) addCandidate)
    {
        auto response = get(projectUrl() ~ "/packages?order_by=version&sort=desc", authHeaders());
        if (response.status == 403)
            return;
        if (!response.ok)
            throw new ProviderException("GitLab package listing failed for " ~ projectPath());

        const wanted = tagName.startsWith("v") ? tagName[1 .. $] : tagName;
        foreach (packageNode; parseJSON(response.text).arrayNoRef)
        {
            auto packageVersion = packageNode.jstr("version");
            const bare = packageVersion.startsWith("v") ? packageVersion[1 .. $] : packageVersion;
            if (bare != wanted)
                continue;

            const id = packageNode.jnum("id");
            const packageType = packageNode.jstr("package_type");
            const packageName = packageNode.jstr("name");

            long page = 1;
            for (;;)
            {
                import std.conv : to;

                auto filesResponse = getOrThrow(projectUrl() ~ "/packages/"
                        ~ id.to!string ~ "/package_files?page=" ~ page.to!string, authHeaders());
                auto files = parseJSON(filesResponse.text).arrayNoRef;
                if (files.length == 0)
                    break;
                foreach (file; files)
                {
                    const fileName = file.jstr("file_name");
                    const assetUrl = apiBase ~ "/projects/" ~ urlEscape(projectPath()) ~ "/packages/"
                        ~ packageType ~ "/" ~ packageName ~ "/" ~ packageVersion ~ "/" ~ fileName;
                    addCandidate(fileName, fileName ~ " (" ~ packageType ~ " package)", assetUrl);
                }
                page++;
            }
        }
    }

    void latestVersion(out string tagName, out string url)
    {
        debugf("Getting latest release for %s/%s", owner, repo);
        auto response = getOrThrow(projectUrl() ~ "/releases?per_page=100", authHeaders());
        auto releases = parseJSON(response.text).arrayNoRef;
        if (releases.length == 0)
            throw new ProviderException("no releases found for " ~ projectPath());

        tagName = releases[0].jstr("tag_name");
        string[string] commitUrlByTag;
        foreach (release; releases)
            commitUrlByTag[release.jstr("tag_name")] = release.jobject("commit").jstr("web_url");

        StrictVersion[] parsed;
        string[string] tagByVersion;
        foreach (release; releases)
        {
            auto raw = release.jstr("tag_name");
            const bare = raw.startsWith("v") ? raw[1 .. $] : raw;
            StrictVersion candidate;
            if (!parseStrictVersion(bare, candidate))
                continue;
            if (candidate.preRelease.length == 0 && candidate.metadata.length == 0)
            {
                parsed ~= candidate;
                tagByVersion[candidate.original] = raw;
            }
        }
        if (parsed.length > 0)
        {
            parsed.sort!((a, b) => compareStrict(a, b) < 0);
            tagName = tagByVersion[parsed[$ - 1].original];
        }
        if (auto found = tagName in commitUrlByTag)
            url = *found;
    }

    string id()
    {
        return "gitlab";
    }

    string description()
    {
        auto response = getOrThrow(projectUrl(), authHeaders());
        auto payload = parseJSON(response.text);
        return payload.jstr("description").idup;
    }
}

/// Builds a GitLab provider from a repository or release URL.
Provider newGitLab(string url)
{
    string owner, repo;
    ownerAndRepo(url, "GitLab", owner, repo);
    const tag = tagFromPath(url, 1);
    const host = urlHost(url);

    auto token = environment.get("GITLAB_TOKEN", "");
    const hostSpecific = environment.get("GITLAB_TOKEN_" ~ host.replace(".", "_"), "");
    if (hostSpecific.length > 0)
        token = hostSpecific;

    return new GitLab("https://" ~ host ~ "/api/v4", owner, repo, tag, token);
}
