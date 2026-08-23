module geto.providers.goinstall;

import std.file : read;
import std.json : parseJSON;
import std.path : baseName, buildPath, buildNormalizedPath;
import std.process : Config, execute, spawnProcess, wait;
import std.string : indexOf, startsWith, strip;

import geto.http : getOrThrow;
import geto.jsonutil;
import geto.log;
import geto.providers;
import geto.util : expandEnv;

/// Installs a Go module with `go install` and adopts the resulting binary.
final class GoInstall : Provider
{
    private string repo;
    private string tag;
    private string name;
    private string latestUrl;

    this(string repo, string tag, string name, string latestUrl)
    {
        this.repo = repo;
        this.tag = tag;
        this.name = name;
        this.latestUrl = latestUrl;
    }

    private static string goPath()
    {
        auto result = execute(["go", "env", "GOPATH"]);
        if (result.status != 0)
            throw new ProviderException("command `go env GOPATH` failed: " ~ result.output);
        return result.output.strip;
    }

    File fetch(FetchOpts opts)
    {
        const root = goPath();

        if (opts.versionText.length > 0)
            tag = opts.versionText;
        if (tag.length > 0 && tag != "latest")
            debugf("Getting %s release for %s", tag, repo);
        else
        {
            debugf("Getting latest release for %s", repo);
            string url;
            latestVersion(tag, url);
        }

        auto process = spawnProcess(["go", "install", repo ~ "@" ~ tag]);
        if (process.wait() != 0)
            throw new ProviderException("failed to install package " ~ repo);

        const binaryPath = expandEnv(buildPath(root, "bin", name));
        ubyte[] data;
        try
            data = cast(ubyte[]) read(binaryPath);
        catch (Exception failure)
            throw new ProviderException("failed to open path '" ~ binaryPath ~ "': " ~ failure.msg);

        File result;
        result.data = data;
        result.name = name;
        result.versionText = tag;
        return result;
    }

    void latestVersion(out string tagName, out string url)
    {
        auto response = getOrThrow(latestUrl);
        auto payload = parseJSON(response.text);
        tagName = payload.jstr("Version");
        if (tagName.length == 0)
            throw new ProviderException("version not found in response from " ~ latestUrl);
        url = repo;
    }

    string id()
    {
        return "goinstall";
    }

    string description()
    {
        return "";
    }
}

/// Builds a `go install` provider from a `goinstall://module[@version]` URL.
Provider newGoInstall(string url)
{
    auto path = url.startsWith("goinstall://") ? url["goinstall://".length .. $] : url;

    auto repo = path;
    auto tag = "latest";
    const at = path.lastIndexOf('@');
    if (at > 0)
    {
        repo = buildNormalizedPath(path[0 .. at]);
        tag = path[at + 1 .. $];
    }

    auto name = repo.baseName;
    if (name.length == 0 || name == ".")
        name = repo;

    return new GoInstall(repo, tag, name, "https://proxy.golang.org/" ~ repo ~ "/@latest");
}

private ptrdiff_t lastIndexOf(string text, char needle)
{
    foreach_reverse (i, c; text)
        if (c == needle)
            return cast(ptrdiff_t) i;
    return -1;
}

unittest
{
    auto provider = cast(GoInstall) newGoInstall("goinstall://github.com/foo/bar@v1.2.3");
    assert(provider !is null);
    assert(provider.id() == "goinstall");
}
