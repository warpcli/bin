module geto.cmd.commands;

import std.algorithm : canFind, sort;
import std.array : array, join;
import std.file : exists, isDir, read;
import std.format : format;
import std.path : absolutePath, baseName, buildPath, dirName, isAbsolute;
import std.stdio : writefln, writeln;

import mochafizz.style : render;

import geto.ai.engine : Engine;
import geto.assets : aiModelDir, resetLearning, sanitizeName;
import geto.cli : Command, boolFlag, textFlag;
import geto.cmd.patch : applyHostPatches;
import geto.cmd.support;
import geto.config;
import geto.log;
import geto.providers;
import geto.ui.select : askString, confirm, confirmOrAbort;
import geto.ui.styles : accentStyle, banner, listTable, ListRow, mutedStyle,
    okStyle, repoShort, terminalWidth, warnStyle;
import geto.util : envBool, expandEnv;
import geto.vers : isNotNewer;

// ---------------------------------------------------------------------------
// install
// ---------------------------------------------------------------------------

private struct InstallOpts
{
    bool force;
    string provider;
    bool all;
    bool noPatch;
}

private InstallOpts installOpts;

Command installCommand()
{
    auto command = new Command("install", "Installs the specified binary from a url",
        "<url> [name | path]");
    command.withAliases("i", "add");
    command.withFlags(
        boolFlag(&installOpts.force, "force", "f",
            "Force the installation even if the file already exists"),
        boolFlag(&installOpts.all, "all", "a",
            "Show all possible download options (skip scoring & filtering)"),
        textFlag(&installOpts.provider, "provider", "p", "Forces to use a specific provider"),
        boolFlag(&installOpts.noPatch, "no-patch", "",
            "Don't auto-fix the ELF interpreter / bundled libs for this host"),
    );
    command.withAction(&runInstall);
    return command;
}

private void runInstall(string[] args)
{
    if (args.length == 0)
        throw new CommandException("install needs a url");

    const url = args[0];
    const packageName = defaultBinName(url);
    const defaultPath = get().defaultPath;

    string resolvedPath;
    if (args.length > 1)
    {
        resolvedPath = args[1];
        if (!resolvedPath.canFind("/"))
            resolvedPath = buildPath(defaultPath, resolvedPath);
    }
    else
        resolvedPath = buildPath(defaultPath, askString("Install as:", packageName));

    auto provider = newProvider(url, installOpts.provider);
    debugf("Using provider '%s' for '%s'", provider.id(), url);

    FetchOpts fetchOpts;
    fetchOpts.all = installOpts.all;
    fetchOpts.packageName = packageName;
    fetchOpts.collectLibs = !installOpts.noPatch;
    auto result = provider.fetch(fetchOpts);

    resolvedPath = checkFinalPath(resolvedPath,
        sanitizeName(result.name, result.versionText));

    auto hash = saveToDisk(result, resolvedPath, installOpts.force);

    bool patched;
    hash = applyHostPatches(resolvedPath, result.libs, !installOpts.noPatch, hash, patched);

    // Relative paths that survive expansion are stored absolute.
    auto storedPath = resolvedPath;
    if (!expandEnv(resolvedPath).isAbsolute)
        storedPath = resolvedPath.absolutePath;

    auto binary = new Binary;
    binary.remoteName = result.name;
    binary.path = storedPath;
    binary.versionText = result.versionText;
    binary.hash = hexDigest(hash);
    binary.url = url;
    binary.provider = provider.id();
    binary.description = describeBinary(url, provider.id());
    binary.packagePath = result.packagePath;
    binary.stateUrl = url;
    binary.selectedAsset = result.selectedAsset;
    binary.assetFingerprint = result.assetFingerprint;
    binary.packageFingerprint = result.packageFingerprint;
    binary.tags = wantedTags();
    binary.patch = patched;
    upsertBinary(binary);

    stepDone("installed", expandEnv(resolvedPath), result.versionText);
}

// ---------------------------------------------------------------------------
// list
// ---------------------------------------------------------------------------

Command listCommand()
{
    auto command = new Command("list", "List binaries managed by geto");
    command.withAliases("ls", "l");
    command.withAction(&runList);
    return command;
}

private void runList(string[] args)
{
    auto bins = selectByTag(get().bins);

    auto keys = bins.keys;
    keys.sort();

    ListRow[] rows;
    foreach (key; keys)
    {
        auto binary = bins[key];
        const path = expandEnv(binary.path);
        rows ~= ListRow(path, binary.versionText, binTags(binary), binary.url,
            path.exists, binary.pinned);
    }

    const scope_ = tagFilterAll() ? "all" : wantedTags().join(",");
    writefln("\n%s  %s\n", banner(" geto "),
        mutedStyle.render(format("%d binaries · tag: %s", rows.length, scope_)));

    if (rows.length == 0)
    {
        writefln("%s\n", mutedStyle.render(
                "nothing here — try a different --tag, or `geto install <url>`"));
        return;
    }

    writeln(listTable(rows, terminalWidth()));
    writeln();
}

// ---------------------------------------------------------------------------
// update
// ---------------------------------------------------------------------------

private struct UpdateOpts
{
    bool yes;
    bool dryRun;
    bool all;
    bool skipPathCheck;
    bool continueOnError;
    bool recheck;
}

private UpdateOpts updateOpts;

Command updateCommand()
{
    auto command = new Command("update", "Updates one or multiple binaries managed by geto",
        "[binary_path]");
    command.withAliases("u", "up", "upgrade");
    command.withFlags(
        boolFlag(&updateOpts.dryRun, "dry-run", "", "Only show status, don't prompt for update"),
        boolFlag(&updateOpts.yes, "yes", "y", "Assume yes to update prompt"),
        boolFlag(&updateOpts.all, "all", "a",
            "Show all possible download options (skip scoring & filtering)"),
        boolFlag(&updateOpts.skipPathCheck, "skip-path-check", "p",
            "Skips path checking when looking into packages"),
        boolFlag(&updateOpts.continueOnError, "continue-on-error", "c",
            "Continues to update next package if an error is encountered"),
        boolFlag(&updateOpts.recheck, "recheck", "r",
            "Re-prompt for asset selection instead of reusing the remembered choice"),
    );
    command.withAction(&runUpdate);
    return command;
}

private struct UpdateInfo
{
    Binary binary;
    string versionText;
    string url;
}

private void runUpdate(string[] args)
{
    auto cfg = get();
    auto candidates = targetBinaries(args);

    UpdateInfo[] toUpdate;
    string[] failures;

    foreach (path, binary; candidates)
    {
        if (binary is null)
        {
            debugf("no config entry found for %s, skipping", path);
            continue;
        }
        if (binary.pinned)
        {
            infof("%s is a pinned binary", path);
            continue;
        }

        auto provider = newProvider(binary.url, binary.provider);
        debugf("Using provider '%s' for '%s'", provider.id(), binary.url);

        try
        {
            UpdateInfo info;
            if (findNewerVersion(binary, provider, info))
                toUpdate ~= info;
        }
        catch (Exception failure)
        {
            if (!updateOpts.continueOnError)
                throw failure;
            failures ~= format("Error while getting latest version of %s: %s",
                binary.path, failure.msg);
        }
    }

    if (toUpdate.length == 0 && failures.length == 0)
    {
        infof("All binaries are up to date");
        return;
    }

    if (updateOpts.dryRun)
        throw new CommandException("Updates found, exit (dry-run mode).", 3);

    if (toUpdate.length > 0 && !updateOpts.yes)
    {
        foreach (message; failures)
            warnf("%s", message);
        failures = null;
        confirmOrAbort("Do you want to continue?");
    }

    foreach (info; toUpdate)
    {
        auto binary = info.binary;
        sep();
        stepHeader(expandEnv(binary.path).baseName, "updating · " ~ repoShort(binary.url));

        auto provider = newProvider(info.url, binary.provider);
        debugf("Using provider '%s' for '%s'", provider.id(), info.url);

        FetchOpts fetchOpts;
        fetchOpts.all = updateOpts.all;
        fetchOpts.packagePath = binary.packagePath;
        fetchOpts.skipPatchCheck = updateOpts.skipPathCheck;
        fetchOpts.packageName = binary.remoteName;
        fetchOpts.selectedAsset = binary.selectedAsset;
        fetchOpts.assetFingerprint = binary.assetFingerprint;
        fetchOpts.packageFingerprint = binary.packageFingerprint;
        fetchOpts.recheck = updateOpts.recheck;
        fetchOpts.collectLibs = binary.patch;

        File result;
        try
            result = provider.fetch(fetchOpts);
        catch (Exception failure)
        {
            if (!updateOpts.continueOnError)
                throw failure;
            failures ~= format("Error while fetching %s: %s", info.url, failure.msg);
            continue;
        }

        auto hash = saveToDisk(result, binary.path, true);
        bool patched;
        hash = applyHostPatches(binary.path, result.libs, binary.patch, hash, patched);

        auto updated = new Binary;
        updated.remoteName = result.name;
        updated.path = binary.path;
        updated.versionText = result.versionText;
        updated.hash = hexDigest(hash);
        updated.url = binary.url;
        updated.provider = provider.id();
        updated.packagePath = result.packagePath;
        updated.stateUrl = info.url;
        updated.selectedAsset = result.selectedAsset;
        updated.assetFingerprint = result.assetFingerprint;
        updated.packageFingerprint = result.packageFingerprint;
        updated.patch = binary.patch;
        upsertBinary(updated);

        stepDone("updated", expandEnv(binary.path).baseName, info.versionText);
    }
    sep();
    foreach (message; failures)
        warnf("%s", message);
}

/// Reports whether the provider offers a version newer than the installed one.
private bool findNewerVersion(Binary binary, Provider provider, out UpdateInfo info)
{
    debugf("Checking updates for %s", binary.path);
    string tag, url;
    provider.latestVersion(tag, url);

    if (binary.versionText == tag)
        return false;
    if (isNotNewer(binary.versionText, tag))
        return false;

    debugf("Found new version %s for %s at %s", tag, binary.path, url);
    infof("%s %s -> %s (%s)", binary.path, warnStyle.render(binary.versionText),
        okStyle.render(tag), url);
    info = UpdateInfo(binary, tag, url);
    return true;
}

// ---------------------------------------------------------------------------
// ensure
// ---------------------------------------------------------------------------

Command ensureCommand()
{
    auto command = new Command("ensure",
        "Ensures that all binaries listed in the configuration are present",
        "[binary_path]...");
    command.withAliases("e", "sync");
    command.withAction(&runEnsure);
    return command;
}

private void runEnsure(string[] args)
{
    auto candidates = targetBinaries(args);

    size_t ensured = 0;
    foreach (_, binary; candidates)
    {
        if (binary is null)
            continue;

        if (binary.description.length == 0)
        {
            const description = describeBinary(binary.url, binary.provider);
            if (description.length > 0)
            {
                binary.description = description;
                upsertBinary(binary);
            }
        }

        const path = expandEnv(binary.path);
        string reason = "missing, installing";
        if (path.exists)
        {
            if (fileSha256(path) == binary.hash)
                continue;
            reason = "hash mismatch, reinstalling";
        }

        sep();
        stepHeader(path.baseName, reason ~ " · " ~ repoShort(binary.url));

        auto provider = newProvider(binary.url, binary.provider);
        debugf("Using provider '%s' for '%s'", provider.id(), binary.url);

        auto packageName = binary.remoteName;
        if (packageName.length == 0)
            packageName = path.baseName;

        FetchOpts fetchOpts;
        fetchOpts.versionText = binary.versionText;
        fetchOpts.packagePath = binary.packagePath;
        fetchOpts.packageName = packageName;
        fetchOpts.selectedAsset = binary.selectedAsset;
        fetchOpts.assetFingerprint = binary.assetFingerprint;
        fetchOpts.packageFingerprint = binary.packageFingerprint;
        fetchOpts.nonInteractive = envBool("GETO_NONINTERACTIVE");
        fetchOpts.collectLibs = binary.patch;
        auto result = provider.fetch(fetchOpts);

        auto hash = saveToDisk(result, path, true);
        bool patched;
        hash = applyHostPatches(path, result.libs, binary.patch, hash, patched);

        auto updated = new Binary;
        updated.remoteName = result.name;
        updated.path = binary.path;
        updated.versionText = result.versionText;
        updated.hash = hexDigest(hash);
        updated.url = binary.url;
        updated.provider = provider.id();
        updated.packagePath = result.packagePath;
        updated.selectedAsset = result.selectedAsset;
        updated.assetFingerprint = result.assetFingerprint;
        updated.packageFingerprint = result.packageFingerprint;
        updated.patch = binary.patch;
        upsertBinary(updated);

        stepDone("ensured", path.baseName, result.versionText);
        ensured++;
    }

    if (ensured == 0)
        info("All binaries present and up to date");
    else
        sep();
}

// ---------------------------------------------------------------------------
// remove
// ---------------------------------------------------------------------------

private bool removeYes;

Command removeCommand()
{
    auto command = new Command("remove", "Removes binaries managed by geto",
        "[<name> | <paths...>]");
    command.withAliases("rm", "uninstall", "delete");
    command.withFlags(boolFlag(&removeYes, "yes", "y", "Skip the confirmation prompt"));
    command.withAction(&runRemove);
    return command;
}

private void runRemove(string[] args)
{
    import std.file : remove;

    if (args.length == 0)
        throw new CommandException("remove needs at least one binary");

    auto cfg = get();
    Binary[] matches;
    foreach (argument; args)
    {
        string resolved;
        try
            resolved = getBinPath(argument);
        catch (Exception failure)
            debugf("could not resolve %s via PATH: %s", argument, failure.msg);

        Binary match;
        foreach (binary; cfg.bins)
        {
            const path = expandEnv(binary.path);
            if ((resolved.length > 0 && path == expandEnv(resolved))
                || argument == binary.path || argument == path || path.baseName == argument)
            {
                match = binary;
                break;
            }
        }
        if (match is null)
        {
            warnf("%s is not managed by geto, skipping", warnStyle.render(argument));
            continue;
        }
        matches ~= match;
    }

    if (matches.length == 0)
    {
        warn("No binaries to remove");
        return;
    }

    if (!removeYes)
    {
        string[] names;
        foreach (binary; matches)
            names ~= expandEnv(binary.path).baseName;
        if (!confirm("Remove " ~ names.join(", ") ~ "?", false))
        {
            info("Aborted");
            return;
        }
    }

    size_t removed = 0;
    foreach (match; matches)
    {
        const path = expandEnv(match.path);
        if (path.exists)
            remove(path);
        removeBinaries([match.path]);
        infof("Removed %s", okStyle.render(path));
        removed++;
    }
    infof("Done, removed %d binary(s)", removed);
}

// ---------------------------------------------------------------------------
// prune
// ---------------------------------------------------------------------------

private bool pruneForce;

Command pruneCommand()
{
    auto command = new Command("prune", "Prunes binaries that no longer exist in the system");
    command.withAliases("clean", "gc");
    command.withFlags(boolFlag(&pruneForce, "force", "f", "Bypass confirmation prompt"));
    command.withAction(&runPrune);
    return command;
}

private void runPrune(string[] args)
{
    string[] stale;
    foreach (_, binary; selectByTag(get().bins))
    {
        const path = expandEnv(binary.path);
        if (!path.exists)
        {
            infof("%s not found removing", path);
            stale ~= binary.path;
        }
    }

    if (stale.length == 0)
    {
        info("Nothing to prune, all binaries exist");
        return;
    }

    if (!pruneForce)
        confirmOrAbort("The following paths will be removed. Continue?");

    removeBinaries(stale);
    infof("Done, pruned %d binary(s)", stale.length);
}

// ---------------------------------------------------------------------------
// pin / unpin
// ---------------------------------------------------------------------------

Command pinCommand()
{
    auto command = new Command("pin", "Pins current version of the binaries",
        "[<name> | <paths...>]");
    command.withAction((string[] args) { setPinned(args, true); });
    return command;
}

Command unpinCommand()
{
    auto command = new Command("unpin", "Unpins current version of the binaries",
        "[<name> | <paths...>]");
    command.withAction((string[] args) { setPinned(args, false); });
    return command;
}

private void setPinned(string[] args, bool pinned)
{
    if (args.length == 0)
        throw new CommandException((pinned ? "pin" : "unpin") ~ " needs at least one binary");

    auto cfg = get();
    string[] touched;
    foreach (argument; args)
    {
        const key = getBinPath(argument);
        auto binary = key in cfg.bins;
        if (binary is null || *binary is null)
            throw new CommandException(argument ~ " is not managed by geto");
        (*binary).pinned = pinned;
        upsertBinary(*binary);
        touched ~= argument;
    }
    infof("%s %s", pinned ? "Pinned" : "Unpinned", touched.join(" "));
}

// ---------------------------------------------------------------------------
// describe
// ---------------------------------------------------------------------------

private bool describeForce;

/// The upstream description for a URL, or "" when it cannot be fetched.
string describeBinary(string url, string provider)
{
    import std.string : strip;

    try
    {
        auto resolved = newProvider(url, provider);
        return resolved.description().strip;
    }
    catch (Exception)
        return "";
}

Command describeCommand()
{
    auto command = new Command("describe", "Fetch and store repository descriptions",
        "[<name> | <paths...>]");
    command.withAliases("desc");
    command.withFlags(boolFlag(&describeForce, "force", "f",
            "Refetch even if a description already exists"));
    command.withAction(&runDescribe);
    return command;
}

private void runDescribe(string[] args)
{
    auto candidates = targetBinaries(args);

    size_t done = 0, skipped = 0;
    foreach (_, binary; candidates)
    {
        if (binary is null)
            continue;
        if (binary.description.length > 0 && !describeForce)
        {
            skipped++;
            continue;
        }
        const description = describeBinary(binary.url, binary.provider);
        if (description.length == 0)
        {
            warnf("no description for %s", binary.path.baseName);
            continue;
        }
        binary.description = description;
        upsertBinary(binary);
        infof("%s — %s", binary.path.baseName, mutedStyle.render(description));
        done++;
    }
    infof("Done: %d described, %d already had one", done, skipped);
}

// ---------------------------------------------------------------------------
// tag
// ---------------------------------------------------------------------------

Command tagCommand()
{
    auto command = new Command("tag", "Manage tags (tiers) for managed binaries");

    auto list = new Command("ls", "List all tags and how many binaries each has");
    list.withAliases("list");
    list.withAction(&runTagList);
    command.add(list);

    auto show = new Command("show", "Show the tags of the given binaries", "<name|path>...");
    show.withAction(&runTagShow);
    command.add(show);

    auto add = new Command("add", "Add a tag to one or more binaries", "<tag> <name|path>...");
    add.withAction(&runTagAdd);
    command.add(add);

    auto rm = new Command("rm", "Remove a tag from one or more binaries", "<tag> <name|path>...");
    rm.withAliases("remove");
    rm.withAction(&runTagRemove);
    command.add(rm);

    return command;
}

private Binary[string] resolveBins(const string[] args)
{
    auto cfg = get();
    Binary[string] result;
    foreach (argument; args)
    {
        string key;
        try
            key = getBinPath(argument);
        catch (Exception failure)
            throw new CommandException(argument ~ " is not managed by geto: " ~ failure.msg);
        auto binary = key in cfg.bins;
        if (binary is null || *binary is null)
            throw new CommandException(argument ~ " is not managed by geto");
        result[key] = *binary;
    }
    return result;
}

private void runTagList(string[] args)
{
    size_t[string] counts;
    foreach (binary; get().bins)
    {
        if (binary is null)
            continue;
        foreach (tag; binTags(binary))
            counts[tag] = counts.get(tag, 0) + 1;
    }
    if (counts.length == 0)
    {
        info("No binaries installed");
        return;
    }
    auto names = counts.keys;
    names.sort();
    foreach (name; names)
        writefln("%s (%d)", name, counts[name]);
}

private void runTagShow(string[] args)
{
    if (args.length == 0)
        throw new CommandException("tag show needs at least one binary");
    foreach (_, binary; resolveBins(args))
        writefln("%s: %s", expandEnv(binary.path), binTags(binary).join(", "));
}

private void runTagAdd(string[] args)
{
    if (args.length < 2)
        throw new CommandException("tag add needs a tag and at least one binary");
    const tag = args[0];
    foreach (_, binary; resolveBins(args[1 .. $]))
    {
        if (!binHasAnyTag(binary, [tag]))
            binary.tags = binTags(binary) ~ tag;
        upsertBinary(binary);
        infof("Tagged %s with %s (now: %s)", expandEnv(binary.path),
            okStyle.render(tag), binary.tags.join(", "));
    }
}

private void runTagRemove(string[] args)
{
    if (args.length < 2)
        throw new CommandException("tag rm needs a tag and at least one binary");
    const tag = args[0];
    foreach (_, binary; resolveBins(args[1 .. $]))
    {
        string[] kept;
        foreach (existing; binTags(binary))
            if (existing != tag)
                kept ~= existing;
        // A binary always belongs to at least "default".
        binary.tags = kept.length == 0 ? ["default"] : kept;
        upsertBinary(binary);
        infof("Removed tag %s from %s (now: %s)", warnStyle.render(tag),
            expandEnv(binary.path), binary.tags.join(", "));
    }
}

// ---------------------------------------------------------------------------
// ai
// ---------------------------------------------------------------------------

private bool aiForce;

Command aiCommand()
{
    auto command = new Command("ai", "Inspect or reset the learned asset-selection model");
    command.withAction(&runAi);

    auto reset = new Command("reset", "Forget everything learned about asset selection");
    reset.withFlags(boolFlag(&aiForce, "force", "f", "Bypass confirmation prompt"));
    reset.withAction(&runAiReset);
    command.add(reset);
    return command;
}

private void runAi(string[] args)
{
    const dir = aiModelDir();
    if (dir.length == 0)
    {
        info("Asset-selection learning is off (GETO_NO_AI)");
        return;
    }

    infof("Model directory: %s", dir);

    auto engine = Engine.create();
    if (engine.seeded)
        info("Built-in seed model: loaded");
    else
        info("Built-in seed model: unavailable");

    try
    {
        engine.load(dir);
        infof("Your own choices: learned from %d selection(s)", engine.selections);
    }
    catch (Exception failure)
    {
        if (!buildPath(dir, "model.json").exists)
            info("Your own choices: none recorded yet");
        else
            infof("Your own choices: ignoring an unusable model (%s)", failure.msg);
    }

    if (engine.trained)
        info("Clear-cut ties are resolved without asking; anything close still prompts");
    else
        info("Every tie is resolved by asking you");
}

private void runAiReset(string[] args)
{
    if (aiModelDir().length == 0)
    {
        info("Asset-selection learning is off (GETO_NO_AI); nothing to reset");
        return;
    }
    if (!aiForce)
        confirmOrAbort("Discard the learned asset-selection model?");
    if (!resetLearning())
    {
        info("Nothing learned yet; nothing to reset");
        return;
    }
    info("Learned asset-selection model discarded");
}

// ---------------------------------------------------------------------------
// Shared
// ---------------------------------------------------------------------------

/// The binaries named on the command line, or the whole active tag when empty.
package Binary[string] targetBinaries(const string[] args)
{
    auto cfg = get();
    if (args.length == 0)
        return selectByTag(cfg.bins);

    Binary[string] result;
    foreach (argument; args)
    {
        const key = getBinPath(argument);
        if (auto binary = key in cfg.bins)
            result[key] = *binary;
    }
    return result;
}
