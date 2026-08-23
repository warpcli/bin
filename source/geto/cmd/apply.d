module geto.cmd.apply;

import std.file : exists, mkdirRecurse, readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath, dirName;
import std.string : strip;

import geto.assets : normalizeAssetName;
import geto.cli : Command, boolFlag;
import geto.cmd.patch : applyHostPatches;
import geto.cmd.support;
import geto.config;
import geto.jsonutil;
import geto.providers;
import geto.util : expandEnv;

private struct ApplyOpts
{
    bool nonInteractive;
    bool force;
    bool refresh;
}

private ApplyOpts applyOpts;

/// One entry of a declarative manifest. Absent fields stay unset so existing
/// state can supply them.
private struct ApplySpec
{
    string url;
    string name;
    bool hasName;
    string path;
    bool hasPath;
    string provider;
    string versionText;
    string asset;
    string packagePath;
    string description;
    string[] tags;
    bool patch;
    bool hasPatch;
    bool force;
    bool refresh;
}

Command applyCommand()
{
    auto command = new Command("apply", "Apply a declarative binary manifest",
        "<desired.json>");
    command.withFlags(
        boolFlag(&applyOpts.nonInteractive, "non-interactive", "",
            "fail instead of prompting when a choice is ambiguous"),
        boolFlag(&applyOpts.force, "force", "f", "reinstall every declared binary"),
        boolFlag(&applyOpts.refresh, "refresh", "",
            "resolve latest versions instead of reusing existing pinned state"),
    );
    command.withAction(&runApply);
    return command;
}

private void runApply(string[] args)
{
    if (args.length != 1)
        throw new CommandException("apply needs exactly one manifest path");

    auto root = parseJSON(readText(args[0]));
    auto binsNode = root.jobject("bins");
    if (binsNode.type != JSONType.object || binsNode.objectNoRef.length == 0)
        return;

    auto cfg = get();
    const declaredPath = root.jstr("default_path");
    if (declaredPath.length > 0)
        cfg.defaultPath = declaredPath;
    if (cfg.defaultPath.length == 0)
        throw new CommandException(
            "desired manifest needs default_path or an existing geto default path");
    mkdirRecurse(expandEnv(cfg.defaultPath));

    foreach (key, node; binsNode.objectNoRef)
    {
        try
            applyOne(key, readSpec(node));
        catch (Exception failure)
            throw new CommandException(key ~ ": " ~ failure.msg);
    }
}

private ApplySpec readSpec(const JSONValue node)
{
    ApplySpec spec;
    spec.url = node.jstr("url");
    spec.name = node.jstr("name");
    spec.hasName = node.type == JSONType.object && ("name" in node.objectNoRef) !is null;
    spec.path = node.jstr("path");
    spec.hasPath = node.type == JSONType.object && ("path" in node.objectNoRef) !is null;
    spec.provider = node.jstr("provider");
    spec.versionText = node.jstr("version");
    spec.asset = node.jstr("asset");
    spec.packagePath = node.jstr("package_path");
    spec.description = node.jstr("description");
    foreach (tag; node.jitems("tags"))
        if (tag.type == JSONType.string)
            spec.tags ~= tag.str;
    spec.hasPatch = node.type == JSONType.object && ("patch" in node.objectNoRef) !is null;
    spec.patch = node.jbool("patch");
    spec.force = node.jbool("force");
    spec.refresh = node.jbool("refresh");
    return spec;
}

private void applyOne(string key, ApplySpec spec)
{
    if (spec.url.strip.length == 0)
        throw new CommandException("url is required");

    auto name = spec.hasName ? spec.name : key;
    if (name.length == 0)
        name = defaultBinName(spec.url);
    auto path = spec.hasPath ? spec.path : buildPath(get().defaultPath, name);
    path = expandEnv(path);
    mkdirRecurse(path.dirName);

    auto existing = existingApplyBinary(path);
    const force = applyOpts.force || spec.force;
    const refresh = applyOpts.refresh || spec.refresh;

    if (!force && !refresh && existing !is null && existingMatches(path, existing, spec))
        return;

    auto provider = newProvider(spec.url, spec.provider);

    auto versionText = spec.versionText;
    if (versionText.length == 0 && existing !is null && !refresh)
        versionText = existing.versionText;

    bool patch = true;
    if (spec.hasPatch)
        patch = spec.patch;
    else if (existing !is null)
        patch = existing.patch;

    FetchOpts fetchOpts;
    fetchOpts.packageName = name;
    fetchOpts.versionText = versionText;
    fetchOpts.nonInteractive = applyOpts.nonInteractive;
    fetchOpts.collectLibs = patch;
    fetchOpts.wantedAsset = spec.asset;
    fetchOpts.wantedPackagePath = spec.packagePath;
    if (existing !is null && !refresh)
    {
        fetchOpts.packagePath = existing.packagePath;
        fetchOpts.packageFingerprint = existing.packageFingerprint;
        fetchOpts.selectedAsset = existing.selectedAsset;
        fetchOpts.assetFingerprint = existing.assetFingerprint;
    }

    auto result = provider.fetch(fetchOpts);

    auto hash = saveToDisk(result, path, true);
    bool patched;
    hash = applyHostPatches(path, result.libs, patch, hash, patched);

    auto tags = spec.tags;
    if (tags.length == 0 && existing !is null)
        tags = existing.tags;
    if (tags.length == 0)
        tags = ["nix"];

    auto description = spec.description;
    if (description.length == 0 && existing !is null)
        description = existing.description;

    auto binary = new Binary;
    binary.remoteName = result.name;
    binary.path = path;
    binary.versionText = result.versionText;
    binary.hash = hexDigest(hash);
    binary.url = spec.url;
    binary.provider = provider.id();
    binary.description = description;
    binary.packagePath = result.packagePath;
    binary.stateUrl = spec.url;
    binary.selectedAsset = result.selectedAsset;
    binary.assetFingerprint = result.assetFingerprint;
    binary.packageFingerprint = result.packageFingerprint;
    binary.tags = tags;
    binary.patch = patch || patched;
    upsertBinary(binary);
}

private Binary existingApplyBinary(string path)
{
    auto cfg = get();
    if (auto found = path in cfg.bins)
        return *found;
    foreach (binary; cfg.bins)
        if (binary !is null && expandEnv(binary.path) == path)
            return binary;
    return null;
}

private bool existingMatches(string path, Binary binary, ApplySpec spec)
{
    if (binary is null || binary.url != spec.url)
        return false;
    if (spec.provider.length > 0 && binary.provider != spec.provider)
        return false;
    if (spec.versionText.length > 0 && binary.versionText != spec.versionText)
        return false;
    if (spec.asset.length > 0 && binary.selectedAsset != normalizeAssetName(spec.asset))
        return false;
    if (spec.packagePath.length > 0 && binary.packagePath != spec.packagePath)
        return false;
    if (binary.hash.length == 0 || !path.exists)
        return false;
    try
        return fileSha256(path) == binary.hash;
    catch (Exception)
        return false;
}
