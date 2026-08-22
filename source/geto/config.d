module geto.config;

import std.algorithm : canFind;
import std.array : array, split;
import std.file : DirEntry, dirEntries, exists, isDir, mkdirRecurse, readText, rename, SpanMode, write;
import std.json : JSONType, JSONValue, parseJSON, toJSON;
import std.path : baseName, buildPath, dirName, extension, stripExtension;
import std.process : environment;
import std.string : endsWith, indexOf, startsWith, stripRight;

import geto.log;
import geto.util : expandEnv, homeDir;

/// Raised for any recoverable configuration failure.
class ConfigException : Exception
{
    this(string message, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
    }
}

/// A managed binary. Reference semantics mirror the Go `*Binary`.
final class Binary
{
    string path;
    string remoteName;
    string versionText;
    string hash;
    string url;
    string provider;
    /// Upstream repository description.
    string description;
    /// Relative binary path within an archive.
    string packagePath;
    bool pinned;
    /// Organizational tiers this binary belongs to.
    string[] tags;
    /// Whether ELF patches are enabled for host compatibility.
    bool patch;
    /// Version-specific download URL; lives in state, never the manifest.
    string stateUrl;
    /// Normalized name of the chosen release asset.
    string selectedAsset;
    /// The set of installable assets seen at selection time.
    string[] assetFingerprint;
    /// The set of installable files inside the chosen archive.
    string[] packageFingerprint;

    Binary dup() const
    {
        auto copy = new Binary;
        copy.path = path;
        copy.remoteName = remoteName;
        copy.versionText = versionText;
        copy.hash = hash;
        copy.url = url;
        copy.provider = provider;
        copy.description = description;
        copy.packagePath = packagePath;
        copy.pinned = pinned;
        copy.tags = tags.dup;
        copy.patch = patch;
        copy.stateUrl = stateUrl;
        copy.selectedAsset = selectedAsset;
        copy.assetFingerprint = assetFingerprint.dup;
        copy.packageFingerprint = packageFingerprint.dup;
        return copy;
    }
}

struct Config
{
    string defaultPath;
    Binary[string] bins;
}

/// Process-local path overrides supplied by CLI flags.
struct PathOverrides
{
    string configFile;
    string stateFile;
    string defaultDir;
}

private struct StateEntry
{
    string versionText;
    string remoteName;
    string hash;
    string packagePath;
    bool pinned;
    string url;
    string description;
    string selectedAsset;
    string[] assetFingerprint;
    string[] packageFingerprint;
}

private Config cfg;
private PathOverrides overrides;

/// Overridden in tests to exercise the root/system code paths.
package int function() effectiveUid;

static this()
{
    import core.sys.posix.unistd : geteuid;

    effectiveUid = () => cast(int) geteuid();
}

void setPathOverrides(PathOverrides value)
{
    overrides = value;
}

Config* get()
{
    return &cfg;
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

private string jsonString(const JSONValue node, string key)
{
    if (node.type != JSONType.object)
        return "";
    if (auto found = key in node.objectNoRef)
        return found.type == JSONType.string ? found.str : "";
    return "";
}

private bool jsonBool(const JSONValue node, string key)
{
    if (node.type != JSONType.object)
        return false;
    if (auto found = key in node.objectNoRef)
        return found.type == JSONType.true_;
    return false;
}

private string[] jsonStrings(const JSONValue node, string key)
{
    string[] result;
    if (node.type != JSONType.object)
        return result;
    if (auto found = key in node.objectNoRef)
    {
        if (found.type != JSONType.array)
            return result;
        foreach (item; found.arrayNoRef)
            if (item.type == JSONType.string)
                result ~= item.str;
    }
    return result;
}

private JSONValue readJsonFile(string path)
{
    const text = readText(path);
    if (text.stripRight.length == 0)
        return JSONValue(cast(JSONValue[string]) null);
    return parseJSON(text);
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

/// Loads the manifest and state, running any pending migrations.
void checkAndLoad()
{
    const configPath = getConfigPath();
    const confDir = configPath.dirName;
    const systemConfig = isSystemDefaultConfig(configPath);
    prepareConfigDir(confDir, systemConfig);
    debugf("Config directory is: %s", confDir);

    cfg = Config.init;
    cfg.bins = null;
    decodeManifest(readManifest(configPath, systemConfig));

    const defaultPathChanged = ensureDefaultPath();
    const pathsChanged = normalizeManifestPaths();
    const keysChanged = normalizeManifestKeys();
    validateInstallPaths();

    // RemoteName present straight after decoding came from a legacy manifest
    // and must be rewritten into the state file.
    bool remoteNameInManifest = false;
    foreach (binary; cfg.bins)
        if (binary !is null && binary.remoteName.length > 0)
        {
            remoteNameInManifest = true;
            break;
        }

    const statePath = getStatePath(configPath);
    StateEntry[string] entries;
    string loadedStatePath;
    const loadedState = loadState(configPath, statePath, entries, loadedStatePath);
    const stateMigrationNeeded = loadedState && loadedStatePath != statePath;

    // Tag current bins "default" before merging siblings so a binary in both
    // keeps default membership and merely gains the sibling's tag.
    const preTags = normalizeTags();
    const mergeChanged = mergeSiblingManifests(configPath, entries);

    foreach (key, entry; entries)
    {
        auto binary = key in cfg.bins;
        if (binary is null || *binary is null)
            continue;
        auto b = *binary;
        b.versionText = entry.versionText;
        if (entry.remoteName.length > 0)
            b.remoteName = entry.remoteName;
        if (b.description.length == 0)
            b.description = entry.description;
        b.hash = entry.hash;
        b.packagePath = entry.packagePath;
        b.pinned = entry.pinned;
        b.stateUrl = entry.url;
        b.selectedAsset = entry.selectedAsset;
        b.assetFingerprint = entry.assetFingerprint;
        b.packageFingerprint = entry.packageFingerprint;
    }

    ensureRuntimeDirs(statePath);

    // Manifests that still carry state need splitting into the two files.
    bool needsMigration = false;
    if (cfg.bins.length > 0 && (!loadedState || entries.length == 0))
    {
        foreach (binary; cfg.bins)
        {
            if (binary is null)
                continue;
            if (binary.versionText.length > 0 || binary.hash.length > 0
                || binary.packagePath.length > 0 || binary.pinned)
            {
                needsMigration = true;
                break;
            }
        }
    }
    if (needsMigration || stateMigrationNeeded)
    {
        infof("Splitting config manifest and state into %s and %s", configPath, statePath);
        writeAll();
    }

    const tagsChanged = normalizeTags();
    const urlsChanged = normalizeManifestUrls();
    const providersChanged = normalizeProviders();
    if (urlsChanged || providersChanged || defaultPathChanged || pathsChanged
        || keysChanged || mergeChanged || preTags || tagsChanged || remoteNameInManifest)
        writeAll();

    debugf("Download path set to %s", cfg.defaultPath);
}

private void prepareConfigDir(string dir, bool systemConfig)
{
    if (systemConfig)
    {
        if (!dir.exists)
            throw new ConfigException("system config directory " ~ dir
                    ~ " does not exist; create /etc/geto/list.json or set GETO_CONFIG_FILE");
        if (!dir.isDir)
            throw new ConfigException("system config path " ~ dir ~ " is not a directory");
        return;
    }
    try
        mkdirRecurse(dir);
    catch (Exception failure)
        throw new ConfigException("error creating config directory " ~ dir ~ ": " ~ failure.msg);
}

private JSONValue readManifest(string path, bool systemConfig)
{
    if (systemConfig && !path.exists)
        throw new ConfigException("system config file " ~ path
                ~ " does not exist; create it with Nix or set GETO_CONFIG_FILE");
    if (!path.exists)
    {
        write(path, "");
        return JSONValue(cast(JSONValue[string]) null);
    }
    return readJsonFile(path);
}

private void decodeManifest(JSONValue root)
{
    cfg.defaultPath = jsonString(root, "default_path");
    if (root.type == JSONType.object)
        if (auto bins = "bins" in root.objectNoRef)
            if (bins.type == JSONType.object)
                foreach (key, node; bins.objectNoRef)
                    cfg.bins[key] = decodeBinary(node);
}

private Binary decodeBinary(const JSONValue node)
{
    auto binary = new Binary;
    binary.path = jsonString(node, "path");
    binary.remoteName = jsonString(node, "remote_name");
    binary.versionText = jsonString(node, "version");
    binary.hash = jsonString(node, "hash");
    binary.url = jsonString(node, "url");
    binary.provider = jsonString(node, "provider");
    binary.description = jsonString(node, "description");
    binary.packagePath = jsonString(node, "package_path");
    binary.pinned = jsonBool(node, "pinned");
    binary.tags = jsonStrings(node, "tags");
    binary.patch = jsonBool(node, "patch");
    return binary;
}

private bool ensureDefaultPath()
{
    string explicit;
    if (explicitDefaultPath(explicit))
    {
        const changed = cfg.defaultPath != explicit;
        cfg.defaultPath = explicit;
        return changed;
    }
    if (cfg.defaultPath.length > 0)
        return false;
    cfg.defaultPath = defaultInstallPath();
    return true;
}

private void ensureRuntimeDirs(string statePath)
{
    try
        mkdirRecurse(statePath.dirName);
    catch (Exception failure)
        throw new ConfigException("error creating state directory " ~ statePath.dirName
                ~ ": " ~ failure.msg);
    if (cfg.defaultPath.length == 0)
        return;
    auto target = isSystemMode() ? cfg.defaultPath : expandEnv(cfg.defaultPath);
    try
        mkdirRecurse(target);
    catch (Exception failure)
        throw new ConfigException("error creating default install directory " ~ target
                ~ ": " ~ failure.msg);
}

private bool loadState(string configPath, string primaryPath,
    ref StateEntry[string] entries, out string loadedPath)
{
    foreach (candidate; stateReadPaths(configPath, primaryPath))
    {
        if (!candidate.exists)
            continue;
        JSONValue root;
        try
            root = readJsonFile(candidate);
        catch (Exception failure)
        {
            warnf("Skipping state file %s: %s", candidate, failure.msg);
            continue;
        }
        if (root.type == JSONType.object)
            if (auto bins = "bins" in root.objectNoRef)
                if (bins.type == JSONType.object)
                    foreach (key, node; bins.objectNoRef)
                        entries[key] = decodeStateEntry(node);
        loadedPath = candidate;
        return true;
    }
    return false;
}

private StateEntry decodeStateEntry(const JSONValue node)
{
    StateEntry entry;
    entry.versionText = jsonString(node, "version");
    entry.remoteName = jsonString(node, "remote_name");
    entry.hash = jsonString(node, "hash");
    entry.packagePath = jsonString(node, "package_path");
    entry.pinned = jsonBool(node, "pinned");
    entry.url = jsonString(node, "url");
    entry.description = jsonString(node, "description");
    entry.selectedAsset = jsonString(node, "selected_asset");
    entry.assetFingerprint = jsonStrings(node, "asset_fingerprint");
    entry.packageFingerprint = jsonStrings(node, "package_fingerprint");
    return entry;
}

private string[] stateReadPaths(string configPath, string primaryPath)
{
    string[] candidates = [primaryPath];
    if (!hasConfigPathOverride() && !hasStatePathOverride())
        candidates ~= legacyStatePaths(configPath);

    bool[string] seen;
    string[] result;
    foreach (candidate; candidates)
    {
        if (candidate.length == 0 || candidate in seen)
            continue;
        seen[candidate] = true;
        result ~= candidate;
    }
    return result;
}

private string[] legacyStatePaths(string configPath)
{
    const base = configPath.baseName;
    const names = [base.stripExtension ~ ".state.json", "config.state.json"];
    string[] paths;

    void addNames(string dir)
    {
        foreach (name; names)
            paths ~= buildPath(dir, name);
    }

    const dataHome = environment.get("XDG_DATA_HOME", "");
    if (dataHome.length > 0)
        addNames(buildPath(dataHome, "bin"));
    const home = homeDir();
    if (home.length > 0)
        addNames(buildPath(home, ".local", "share", "bin"));
    addNames(configPath.dirName);
    return paths;
}

// ---------------------------------------------------------------------------
// Normalization
// ---------------------------------------------------------------------------

private bool normalizeManifestPaths()
{
    bool changed = false;
    foreach (key, binary; cfg.bins)
    {
        if (binary is null || binary.path.length > 0)
            continue;
        binary.path = buildPath(cfg.defaultPath, manifestEntryName(key, binary));
        changed = true;
    }
    return changed;
}

private string manifestEntryName(string key, Binary binary)
{
    if (key.length > 0 && key.indexOf('/') < 0 && key.indexOf('\\') < 0)
        return key;
    if (binary.remoteName.length > 0)
        return binary.remoteName;
    if (binary.url.length > 0)
        return defaultBinaryName(binary.url);
    const name = key.baseName;
    if (name.length == 0 || name == "." || name == "/")
        return "bin";
    return name;
}

/// Derives the on-disk binary name from an install URL.
string defaultBinaryName(string raw)
{
    string text = raw;
    foreach (prefix; ["https://", "http://", "goinstall://"])
        if (text.startsWith(prefix))
            text = text[prefix.length .. $];
    if (text.endsWith("/"))
        text = text[0 .. $ - 1];
    if (text.endsWith(".git"))
        text = text[0 .. $ - 4];
    const name = text.baseName;
    if (name.length == 0 || name == "." || name == "/")
        return "bin";
    return name;
}

private void validateInstallPaths()
{
    if (!isSystemMode())
        return;
    validateSystemPath("default_path", cfg.defaultPath);
    foreach (binary; cfg.bins)
        if (binary !is null)
            validateSystemPath("binary path", binary.path);
}

private void validateSystemPath(string label, string path)
{
    import std.path : isAbsolute;

    if (path.length == 0)
        return;
    if (path.canFind('$') || path.startsWith("~"))
        throw new ConfigException("system " ~ label
                ~ " must be absolute and must not use shell/home expansion: " ~ path);
    if (!path.isAbsolute)
        throw new ConfigException("system " ~ label ~ " must be absolute: " ~ path);
}

/// Re-keys entries so every binary is keyed by its own `path`.
private bool normalizeManifestKeys()
{
    bool changed = false;
    string[] drop;
    Binary[string] rekey;
    foreach (key, binary; cfg.bins)
    {
        if (binary is null)
        {
            drop ~= key;
            continue;
        }
        if (binary.path.length > 0 && key != binary.path)
            rekey[key] = binary;
    }
    foreach (key; drop)
    {
        cfg.bins.remove(key);
        changed = true;
    }
    foreach (key, binary; rekey)
    {
        debugf("Re-keying manifest entry %s to %s", key, binary.path);
        cfg.bins.remove(key);
        cfg.bins[binary.path] = binary;
        changed = true;
    }
    return changed;
}

private string[] addTag(string[] tags, string tag)
{
    if (tags.canFind(tag))
        return tags;
    return tags ~ tag;
}

private bool normalizeTags()
{
    bool changed = false;
    foreach (binary; cfg.bins)
        if (binary !is null && binary.tags.length == 0)
        {
            binary.tags = ["default"];
            changed = true;
        }
    return changed;
}

/// Folds legacy sibling manifests into the single config, tagging by filename.
private bool mergeSiblingManifests(string configPath, ref StateEntry[string] entries)
{
    // Explicit config paths belong to declarative integrations; their directory
    // may hold unrelated JSON, so never scan it.
    if (hasConfigPathOverride() || isSystemMode())
        return false;

    const dir = configPath.dirName;
    const mainBase = configPath.baseName;
    if (!dir.exists)
        return false;

    bool changed = false;
    DirEntry[] found;
    try
        found = dirEntries(dir, SpanMode.shallow).array;
    catch (Exception)
        return false;

    foreach (entry; found)
    {
        if (entry.isDir)
            continue;
        const name = entry.name.baseName;
        if (name == mainBase || !name.endsWith(".json") || name.endsWith(".state.json"))
            continue;
        const tag = name[0 .. $ - ".json".length];
        const sibPath = buildPath(dir, name);

        JSONValue sibling;
        try
            sibling = readJsonFile(sibPath);
        catch (Exception failure)
        {
            warnf("Skipping sibling config %s: %s", name, failure.msg);
            continue;
        }

        size_t merged = 0;
        if (sibling.type == JSONType.object)
            if (auto bins = "bins" in sibling.objectNoRef)
                if (bins.type == JSONType.object)
                    foreach (_, node; bins.objectNoRef)
                    {
                        auto binary = decodeBinary(node);
                        if (binary.path.length == 0)
                            continue;
                        if (auto existing = binary.path in cfg.bins)
                            (*existing).tags = addTag((*existing).tags, tag);
                        else
                        {
                            binary.tags = addTag(binary.tags, tag);
                            cfg.bins[binary.path] = binary;
                        }
                        merged++;
                    }

        mergeSiblingState(sibPath, entries);
        try
            rename(sibPath, sibPath ~ ".bak");
        catch (Exception failure)
            warnf("Merged %s but could not rename it: %s", name, failure.msg);
        infof("Merged %d binaries from %s as tag %s", merged, name, tag);
        changed = true;
    }
    return changed;
}

private void mergeSiblingState(string sibPath, ref StateEntry[string] entries)
{
    string siblingState;
    try
        siblingState = getStatePath(sibPath);
    catch (Exception)
        return;
    if (!siblingState.exists)
        return;
    try
    {
        auto root = readJsonFile(siblingState);
        if (root.type == JSONType.object)
            if (auto bins = "bins" in root.objectNoRef)
                if (bins.type == JSONType.object)
                    foreach (key, node; bins.objectNoRef)
                        if (key !in entries)
                            entries[key] = decodeStateEntry(node);
    }
    catch (Exception)
    {
    }
    try
        rename(siblingState, siblingState ~ ".bak");
    catch (Exception)
    {
    }
}

/// Backfills an empty provider from the URL host.
private bool normalizeProviders()
{
    bool changed = false;
    foreach (binary; cfg.bins)
    {
        if (binary is null || binary.provider.length > 0 || binary.url.length == 0)
            continue;
        const host = urlHost(binary.url);
        if (host.canFind("github"))
            binary.provider = "github";
        else if (host.canFind("gitlab"))
            binary.provider = "gitlab";
        else if (host.canFind("codeberg"))
            binary.provider = "codeberg";
        else if (host.canFind("releases.hashicorp.com"))
            binary.provider = "hashicorp";
        else
            continue;
        changed = true;
    }
    return changed;
}

/// Rewrites versioned manifest URLs back to their stable repository link.
private bool normalizeManifestUrls()
{
    bool changed = false;
    foreach (binary; cfg.bins)
    {
        if (binary is null || binary.url.length == 0)
            continue;
        const base = normalizeBaseUrl(binary.url, binary.provider);
        if (base.length > 0 && base != binary.url)
        {
            if (binary.stateUrl.length == 0)
                binary.stateUrl = binary.url;
            debugf("Normalizing manifest URL from %s to %s", binary.url, base);
            binary.url = base;
            changed = true;
        }
    }
    return changed;
}

/// The host component of a URL, or "" when it has none.
string urlHost(string raw)
{
    auto rest = raw;
    const scheme = rest.indexOf("://");
    if (scheme < 0)
        return "";
    rest = rest[scheme + 3 .. $];
    const slash = rest.indexOf('/');
    return slash < 0 ? rest : rest[0 .. slash];
}

/// The path component of a URL, including its leading slash.
string urlPath(string raw)
{
    auto rest = raw;
    const scheme = rest.indexOf("://");
    if (scheme < 0)
        return raw;
    rest = rest[scheme + 3 .. $];
    const slash = rest.indexOf('/');
    return slash < 0 ? "" : rest[slash .. $];
}

/// The scheme component of a URL, without the `://`.
string urlScheme(string raw)
{
    const scheme = raw.indexOf("://");
    return scheme < 0 ? "" : raw[0 .. scheme];
}

private string normalizeBaseUrl(string raw, string provider)
{
    const host = urlHost(raw);
    if (host.length == 0)
        return "";

    string inferred = provider;
    if (inferred.length == 0)
    {
        if (host.canFind("github"))
            inferred = "github";
        else if (host.canFind("codeberg"))
            inferred = "codeberg";
        else if (host.canFind("gitlab"))
            inferred = "gitlab";
    }

    switch (inferred)
    {
    case "github":
    case "codeberg":
    case "gitlab":
        auto parts = urlPath(raw).split('/');
        if (parts.length >= 3)
            return urlScheme(raw) ~ "://" ~ host ~ "/" ~ parts[1] ~ "/" ~ parts[2];
        return "";
    default:
        return "";
    }
}

// ---------------------------------------------------------------------------
// Mutation
// ---------------------------------------------------------------------------

/// Adds or updates a binary, preserving state-only fields the caller omitted.
void upsertBinary(Binary binary)
{
    if (binary is null)
        return;
    if (auto existing = binary.path in cfg.bins)
    {
        auto previous = *existing;
        if (binary.stateUrl.length == 0)
            binary.stateUrl = previous.stateUrl;
        if (binary.selectedAsset.length == 0)
            binary.selectedAsset = previous.selectedAsset;
        if (binary.assetFingerprint.length == 0)
            binary.assetFingerprint = previous.assetFingerprint;
        if (binary.packageFingerprint.length == 0)
            binary.packageFingerprint = previous.packageFingerprint;
        if (binary.remoteName.length == 0)
            binary.remoteName = previous.remoteName;
        // Tags live in the manifest; keep them unless the caller sets them.
        if (binary.tags.length == 0)
            binary.tags = previous.tags;
        if (binary.description.length == 0)
            binary.description = previous.description;
        if (!binary.patch)
            binary.patch = previous.patch;
    }
    if (binary.tags.length == 0)
        binary.tags = ["default"];
    cfg.bins[binary.path] = binary;
    writeAll();
}

/// Clears the remembered asset and inner-archive choices for one binary.
void forgetBinarySelection(string path)
{
    Binary binary;
    if (auto found = path in cfg.bins)
        binary = *found;
    else
    {
        const expanded = expandEnv(path);
        foreach (key, candidate; cfg.bins)
            if (candidate !is null && expandEnv(candidate.path) == expanded)
            {
                path = key;
                binary = candidate;
                break;
            }
    }
    if (binary is null)
        throw new ConfigException("binary path " ~ path ~ " not found");

    binary.remoteName = "";
    binary.packagePath = "";
    binary.selectedAsset = "";
    binary.assetFingerprint = null;
    binary.packageFingerprint = null;
    cfg.bins[path] = binary;
    writeAll();
}

void removeBinaries(const string[] paths)
{
    foreach (path; paths)
        cfg.bins.remove(path);
    writeAll();
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

void writeAll()
{
    const configPath = getConfigPath();
    const statePath = getStatePath(configPath);
    if (!isSystemDefaultConfig(configPath))
        writeManifest(configPath);
    else
        debugf("Skipping manifest write for declarative system config %s", configPath);
    writeState(statePath);
}

private void writeJsonFile(string path, JSONValue root)
{
    mkdirRecurse(path.dirName);
    write(path, toJSON(root, true) ~ "\n");
}

private void writeManifest(string manifestPath)
{
    JSONValue[string] bins;
    foreach (key, binary; cfg.bins)
    {
        if (binary is null)
            continue;
        JSONValue[string] node;
        node["path"] = binary.path;
        node["url"] = binary.url;
        node["provider"] = binary.provider;
        if (binary.description.length > 0)
            node["description"] = binary.description;
        if (binary.tags.length > 0)
            node["tags"] = JSONValue(binary.tags);
        if (binary.patch)
            node["patch"] = true;
        bins[key] = JSONValue(node);
    }
    JSONValue[string] root;
    root["default_path"] = cfg.defaultPath;
    root["bins"] = JSONValue(bins);
    writeJsonFile(manifestPath, JSONValue(root));
}

private void writeState(string statePath)
{
    JSONValue[string] bins;
    foreach (key, binary; cfg.bins)
    {
        if (binary is null)
            continue;
        JSONValue[string] node;
        node["version"] = binary.versionText;
        if (binary.remoteName.length > 0)
            node["remote_name"] = binary.remoteName;
        node["hash"] = binary.hash;
        node["package_path"] = binary.packagePath;
        node["pinned"] = binary.pinned;
        node["url"] = binary.stateUrl;
        if (binary.description.length > 0)
            node["description"] = binary.description;
        if (binary.selectedAsset.length > 0)
            node["selected_asset"] = binary.selectedAsset;
        if (binary.assetFingerprint.length > 0)
            node["asset_fingerprint"] = JSONValue(binary.assetFingerprint);
        if (binary.packageFingerprint.length > 0)
            node["package_fingerprint"] = JSONValue(binary.packageFingerprint);
        bins[key] = JSONValue(node);
    }
    JSONValue[string] root;
    root["bins"] = JSONValue(bins);
    writeJsonFile(statePath, JSONValue(root));
}

// ---------------------------------------------------------------------------
// Platform
// ---------------------------------------------------------------------------

/// The host architecture plus the aliases release assets commonly use.
string[] getArch()
{
    version (X86_64)
        return ["amd64", "x86_64", "x64", "x86-64", "intel_64", "intel64"];
    else version (AArch64)
        return ["arm64", "aarch64", "arm_64", "arm-64", "armv8"];
    else version (X86)
        return ["386", "i386", "i686", "x86"];
    else version (ARM)
        return ["arm"];
    else
        static assert(false, "unsupported architecture");
}

/// The host operating system plus its common asset aliases.
string[] getOs()
{
    version (linux)
        return ["linux"];
    else version (OSX)
        return ["darwin", "macos"];
    else version (Windows)
        return ["windows", "win"];
    else
        static assert(false, "unsupported operating system");
}

string[] getOsSpecificExtensions()
{
    version (linux)
        return ["AppImage"];
    else version (Windows)
        return ["exe"];
    else
        return null;
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

private bool explicitDefaultPath(out string path)
{
    if (overrides.defaultDir.length > 0)
    {
        path = overrides.defaultDir;
        return true;
    }
    const fromEnv = environment.get("GETO_DEFAULT_PATH", "");
    if (fromEnv.length > 0)
    {
        path = fromEnv;
        return true;
    }
    return false;
}

private string defaultInstallPath()
{
    if (isSystemMode())
        return "/usr/local/bin";
    const home = homeDir();
    if (home.length == 0)
        throw new ConfigException("cannot determine home directory");
    return buildPath(home, ".local", "bin");
}

private bool hasConfigPathOverride()
{
    return overrides.configFile.length > 0
        || environment.get("GETO_CONFIG_FILE", "").length > 0
        || environment.get("GETO_CONFIG_HOME", "").length > 0;
}

private bool hasStatePathOverride()
{
    return overrides.stateFile.length > 0
        || environment.get("GETO_STATE_FILE", "").length > 0
        || environment.get("GETO_STATE_HOME", "").length > 0;
}

bool isSystemMode()
{
    version (Windows)
        return false;
    else
        return effectiveUid() == 0;
}

private bool isSystemDefaultConfig(string configPath)
{
    return isSystemMode() && !hasConfigPathOverride() && configPath == "/etc/geto/list.json";
}

/// The manifest path, honouring overrides, root mode, XDG, and the legacy home.
string getConfigPath()
{
    if (overrides.configFile.length > 0)
        return overrides.configFile;
    const fileEnv = environment.get("GETO_CONFIG_FILE", "");
    if (fileEnv.length > 0)
        return fileEnv;
    const homeEnv = environment.get("GETO_CONFIG_HOME", "");
    if (homeEnv.length > 0)
        return buildPath(homeEnv, "list.json");
    if (isSystemMode())
        return "/etc/geto/list.json";

    const home = homeDir();
    auto configHome = environment.get("XDG_CONFIG_HOME", "");
    if (configHome.length == 0)
    {
        if (home.length == 0)
            throw new ConfigException("cannot determine home directory");
        configHome = buildPath(home, ".config");
    }
    const configPath = buildPath(configHome, "geto", "list.json");
    if (configPath.exists || home.length == 0)
        return configPath;

    const legacyPath = buildPath(home, ".geto", "list.json");
    if (legacyPath.exists)
        return legacyPath;
    return configPath;
}

/// The per-machine mutable state path.
string getStatePath(string manifestPath)
{
    if (overrides.stateFile.length > 0)
        return overrides.stateFile;
    const fileEnv = environment.get("GETO_STATE_FILE", "");
    if (fileEnv.length > 0)
        return fileEnv;
    const homeEnv = environment.get("GETO_STATE_HOME", "");
    if (homeEnv.length > 0)
        return buildPath(homeEnv, "config.state.json");
    if (isSystemMode())
        return "/var/lib/geto/config.state.json";

    const stateHome = environment.get("XDG_STATE_HOME", "");
    if (stateHome.length > 0)
        return buildPath(stateHome, "geto", "config.state.json");
    const home = homeDir();
    if (home.length == 0)
        throw new ConfigException("cannot determine home directory");
    return buildPath(home, ".local", "state", "geto", "config.state.json");
}

/// The directory holding the manifest.
string configDir()
{
    try
        return getConfigPath().dirName;
    catch (Exception)
        return "";
}

/// The directory holding mutable state learned at runtime.
string stateDir()
{
    try
        return getStatePath("").dirName;
    catch (Exception)
        return "";
}
