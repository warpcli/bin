module geto.cmd.root;

import std.path : buildPath;
import std.stdio : writeln;

import geto.cli;
import geto.cmd.apply : applyCommand;
import geto.cmd.commands;
import geto.cmd.support : CommandException, activeTags;
import geto.cmd.tui : tuiCommand;
import geto.config;
import geto.log;
import geto.ui.select : CancelledException, interactive;
import geto.ui.styles : ensureTheme;

private struct RootOpts
{
    bool debugMode;
    string[] tags;
    string configFile;
    string stateFile;
    string defaultPath;
}

private RootOpts rootOpts;
private string buildVersion;

/// Builds the full command tree.
Command buildRoot(string versionText)
{
    buildVersion = versionText;

    auto root = new Command("geto", "Effortless binary manager");
    root.withFlags(
        boolFlag(&rootOpts.debugMode, "debug", "", "Enable debug mode"),
        listFlag(&rootOpts.tags, "tag", "t",
            `Tag context: which tier to act on (default "default", "all" for every binary)`),
        textFlag(&rootOpts.configFile, "config-file", "",
            "Path to geto manifest (env GETO_CONFIG_FILE)"),
        textFlag(&rootOpts.stateFile, "state-file", "",
            "Path to mutable state file (env GETO_STATE_FILE)"),
        textFlag(&rootOpts.defaultPath, "default-path", "",
            "Default install directory (env GETO_DEFAULT_PATH)"),
    );
    import std.functional : toDelegate;

    root.preRun = toDelegate(&loadEnvironment);

    root.add(installCommand());
    root.add(ensureCommand());
    root.add(updateCommand());
    root.add(pinCommand());
    root.add(unpinCommand());
    root.add(removeCommand());
    root.add(applyCommand());
    root.add(listCommand());
    root.add(pruneCommand());
    root.add(tagCommand());
    root.add(describeCommand());
    root.add(aiCommand());
    root.add(tuiCommand());
    return root;
}

private void loadEnvironment()
{
    if (rootOpts.debugMode)
    {
        setLevel(Level.dbg);
        debugf("debug logs enabled, version: %s", buildVersion);
    }

    activeTags = rootOpts.tags;
    setPathOverrides(PathOverrides(rootOpts.configFile, rootOpts.stateFile,
            rootOpts.defaultPath));

    try
        checkAndLoad();
    catch (Exception failure)
        fatalf("Error loading config file %s", failure.msg);

    ensureTheme(buildPath(configDir(), "config"));
}

/// Whether the bare `geto` invocation should open the TUI.
private bool isInteractive()
{
    return interactive();
}

/// Whether a leading argument should be treated as a `list` filter rather than
/// a command, mirroring the Go build's default-command behaviour.
private bool defaultsToList(Command root, string[] args)
{
    if (args.length == 0)
        return true;

    // Resolution skips leading flags, so `geto -t all update` still finds
    // `update` rather than being treated as a `list` filter.
    string[] rest;
    if (resolve(root, args, rest) !is root)
        return false;

    foreach (token; args)
    {
        if (token.length > 1 && token[0] == '-')
            continue;
        foreach (reserved; ["help", "completion"])
            if (token == reserved)
                return false;
        return true;
    }
    // Only flags were given; let them apply to the root command.
    return false;
}

/// Parses and runs the command line, returning the process exit code.
int run(string versionText, string[] args)
{
    auto root = buildRoot(versionText);

    string[] effective = args;
    if (args.length == 0)
        effective = [isInteractive() ? "tui" : "list"];
    else if (args.length == 1 && (args[0] == "-v" || args[0] == "--version"))
    {
        writeln("geto ", versionText);
        return 0;
    }
    else if (args[0] == "help")
    {
        printHelp(root);
        return 0;
    }
    else if (defaultsToList(root, args))
        effective = "list" ~ args;

    try
        execute(root, effective);
    catch (UsageException failure)
    {
        errorWith(failure, "invalid arguments");
        return 1;
    }
    catch (CancelledException failure)
    {
        errorWith(failure, "command failed");
        return 1;
    }
    catch (CommandException failure)
    {
        errorWith(failure, failure.msg);
        return failure.code;
    }
    catch (ExitException failure)
        return failure.code;
    catch (Exception failure)
    {
        errorWith(failure, "command failed");
        return 1;
    }
    return 0;
}
