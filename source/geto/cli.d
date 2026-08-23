module geto.cli;

import std.algorithm : canFind, max;
import std.array : appender, join, replicate, split;
import std.format : format;
import std.stdio : stdout, writeln;
import std.string : startsWith;

import geto.ui.styles : accentStyle, mutedStyle, tagStyle;

import mochafizz.style : render;

/// Raised for bad command-line input; the message is shown without a stack.
class UsageException : Exception
{
    this(string message, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
    }
}

/// Raised to stop with a specific exit code.
class ExitException : Exception
{
    int code;

    this(int code, string message = "", string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
        this.code = code;
    }
}

private enum FlagKind
{
    boolean,
    text,
    list,
}

/// One command-line flag bound to a variable.
struct Flag
{
    string longName;
    string shortName;
    string help;
    private FlagKind kind;
    private bool* boolTarget;
    private string* textTarget;
    private string[]* listTarget;

    /// Whether the flag consumes a following value.
    bool takesValue() const
    {
        return kind != FlagKind.boolean;
    }
}

Flag boolFlag(bool* target, string longName, string shortName, string help)
{
    Flag flag;
    flag.longName = longName;
    flag.shortName = shortName;
    flag.help = help;
    flag.kind = FlagKind.boolean;
    flag.boolTarget = target;
    return flag;
}

Flag textFlag(string* target, string longName, string shortName, string help)
{
    Flag flag;
    flag.longName = longName;
    flag.shortName = shortName;
    flag.help = help;
    flag.kind = FlagKind.text;
    flag.textTarget = target;
    return flag;
}

Flag listFlag(string[]* target, string longName, string shortName, string help)
{
    Flag flag;
    flag.longName = longName;
    flag.shortName = shortName;
    flag.help = help;
    flag.kind = FlagKind.list;
    flag.listTarget = target;
    return flag;
}

private void applyFlag(ref Flag flag, string value)
{
    final switch (flag.kind)
    {
    case FlagKind.boolean:
        *flag.boolTarget = value != "false";
        return;
    case FlagKind.text:
        *flag.textTarget = value;
        return;
    case FlagKind.list:
        foreach (piece; value.split(','))
            if (piece.length > 0)
                *flag.listTarget ~= piece;
        return;
    }
}

/// A command or subcommand.
final class Command
{
    string name;
    string[] aliases;
    string summary;
    /// Argument spec shown after the command name in usage.
    string argSpec;
    string example;
    Flag[] flags;
    Command[] children;
    /// Runs the command with its positional arguments.
    void delegate(string[] args) action;
    /// Runs before any subcommand action, outermost first.
    void delegate() preRun;

    private Command parent;

    this(string name, string summary, string argSpec = "")
    {
        this.name = name;
        this.summary = summary;
        this.argSpec = argSpec;
    }

    Command add(Command child)
    {
        child.parent = this;
        children ~= child;
        return this;
    }

    Command withFlags(Flag[] values...)
    {
        flags ~= values;
        return this;
    }

    Command withAliases(string[] values...)
    {
        aliases ~= values;
        return this;
    }

    Command withAction(void delegate(string[]) value)
    {
        action = value;
        return this;
    }

    /// Overload for module-level functions, which are not delegates.
    Command withAction(void function(string[]) value)
    {
        import std.functional : toDelegate;

        action = toDelegate(value);
        return this;
    }

    bool matches(string token) const
    {
        return token == name || aliases.canFind(token);
    }

    /// The full invocation path, e.g. `geto tag add`.
    string path() const
    {
        return parent is null ? name : parent.path() ~ " " ~ name;
    }

    /// Flags declared here plus every ancestor's.
    package Flag*[] visibleFlags()
    {
        Flag*[] result;
        for (Command node = this; node !is null; node = node.parent)
            foreach (ref flag; node.flags)
                result ~= &flag;
        return result;
    }

    private Flag*[] inheritedFlags()
    {
        Flag*[] result;
        for (Command node = parent; node !is null; node = node.parent)
            foreach (ref flag; node.flags)
                result ~= &flag;
        return result;
    }

    private void runPreRuns()
    {
        Command[] chain;
        for (Command node = this; node !is null; node = node.parent)
            chain = node ~ chain;
        foreach (node; chain)
            if (node.preRun !is null)
                node.preRun();
    }
}

/// Locates the command `args` names, returning the arguments left to parse.
/// Flags may appear before the subcommand, so they are skipped while walking.
Command resolve(Command root, string[] args, out string[] rest)
{
    auto command = root;
    size_t i = 0;

    Flag* lookup(Command node, string token)
    {
        auto body_ = token.startsWith("--") ? token[2 .. $] : token[1 .. $];
        const equals = body_.indexOfChar('=');
        if (equals >= 0)
            return null;
        foreach (flag; node.visibleFlags())
        {
            if (token.startsWith("--") && flag.longName == body_)
                return flag;
            if (!token.startsWith("--") && flag.shortName.length > 0
                && flag.shortName == body_)
                return flag;
        }
        return null;
    }

    while (i < args.length)
    {
        const token = args[i];
        if (token == "--")
            break;
        if (token.length > 1 && token.startsWith("-"))
        {
            // A value-taking flag swallows the token after it.
            auto flag = lookup(command, token);
            if (flag !is null && flag.takesValue)
            {
                rest ~= args[i];
                if (i + 1 < args.length)
                    rest ~= args[i + 1];
                i += 2;
                continue;
            }
            rest ~= args[i];
            i++;
            continue;
        }

        Command next;
        foreach (child; command.children)
            if (child.matches(token))
            {
                next = child;
                break;
            }
        if (next is null)
            break;
        command = next;
        i++;
    }

    rest ~= args[i .. $];
    return command;
}

/// Parses `args` against `root` and runs the resolved command.
void execute(Command root, string[] args)
{
    string[] rest;
    auto command = resolve(root, args, rest);

    string[] positional;
    bool sawTerminator;
    auto flags = command.visibleFlags();

    Flag* findLong(string name)
    {
        foreach (flag; flags)
            if (flag.longName == name)
                return flag;
        return null;
    }

    Flag* findShort(string name)
    {
        foreach (flag; flags)
            if (flag.shortName.length > 0 && flag.shortName == name)
                return flag;
        return null;
    }

    for (size_t i = 0; i < rest.length; i++)
    {
        auto token = rest[i];
        if (sawTerminator || !token.startsWith("-") || token == "-")
        {
            positional ~= token;
            continue;
        }
        if (token == "--")
        {
            sawTerminator = true;
            continue;
        }

        string name;
        string value;
        bool hasValue;
        auto body_ = token.startsWith("--") ? token[2 .. $] : token[1 .. $];
        const equals = body_.indexOfChar('=');
        if (equals >= 0)
        {
            name = body_[0 .. equals];
            value = body_[equals + 1 .. $];
            hasValue = true;
        }
        else
            name = body_;

        if (name == "help" || name == "h")
        {
            printHelp(command);
            return;
        }

        auto flag = token.startsWith("--") ? findLong(name) : findShort(name);
        if (flag is null)
            throw new UsageException("unknown flag: " ~ token);

        if (flag.takesValue && !hasValue)
        {
            if (i + 1 >= rest.length)
                throw new UsageException("flag needs a value: " ~ token);
            value = rest[++i];
        }
        else if (!flag.takesValue && !hasValue)
            value = "true";

        applyFlag(*flag, value);
    }

    if (command.action is null)
    {
        printHelp(command);
        return;
    }

    command.runPreRuns();
    command.action(positional);
}

private ptrdiff_t indexOfChar(string text, char needle)
{
    foreach (i, c; text)
        if (c == needle)
            return cast(ptrdiff_t) i;
    return -1;
}

private string flagUsage(const Flag* flag)
{
    auto label = flag.shortName.length > 0
        ? format("-%s, --%s", flag.shortName, flag.longName)
        : format("    --%s", flag.longName);
    if (flag.takesValue)
        label ~= flag.kind == FlagKind.list ? " strings" : " string";
    return label;
}

private string renderFlags(const Flag*[] flags)
{
    if (flags.length == 0)
        return "";
    size_t width = 0;
    foreach (flag; flags)
        width = max(width, flagUsage(flag).length);

    auto output = appender!string;
    foreach (flag; flags)
    {
        const label = flagUsage(flag);
        output ~= "  " ~ label ~ " ".replicate(width - label.length + 3)
            ~ mutedStyle.render(flag.help) ~ "\n";
    }
    return output.data;
}

/// Prints the colorized help for one command.
void printHelp(Command command)
{
    auto output = appender!string;
    output ~= accentStyle.render("Usage:") ~ "\n";
    if (command.action !is null)
        output ~= "  " ~ command.path()
            ~ (command.argSpec.length > 0 ? " " ~ command.argSpec : "") ~ "\n";
    if (command.children.length > 0)
        output ~= "  " ~ command.path() ~ " [command]\n";

    if (command.aliases.length > 0)
        output ~= "\n" ~ accentStyle.render("Aliases:") ~ "\n  "
            ~ ([command.name] ~ command.aliases).join(", ") ~ "\n";

    if (command.example.length > 0)
        output ~= "\n" ~ accentStyle.render("Examples:") ~ "\n" ~ command.example ~ "\n";

    if (command.children.length > 0)
    {
        output ~= "\n" ~ accentStyle.render("Available Commands:") ~ "\n";
        size_t width = 0;
        foreach (child; command.children)
            width = max(width, child.name.length);
        foreach (child; command.children)
            output ~= "  " ~ tagStyle.render(child.name)
                ~ " ".replicate(width - child.name.length + 1)
                ~ mutedStyle.render(child.summary) ~ "\n";
    }

    if (command.flags.length > 0)
    {
        output ~= "\n" ~ accentStyle.render("Flags:") ~ "\n";
        Flag*[] own;
        foreach (ref flag; command.flags)
            own ~= &flag;
        output ~= renderFlags(own);
    }

    auto inherited = command.inheritedFlags();
    if (inherited.length > 0)
        output ~= "\n" ~ accentStyle.render("Global Flags:") ~ "\n" ~ renderFlags(inherited);

    if (command.children.length > 0)
        output ~= "\n" ~ mutedStyle.render("Use") ~ " \"" ~ command.path()
            ~ " [command] --help\" " ~ mutedStyle.render("for more information about a command.")
            ~ "\n";

    writeln(output.data);
}

unittest
{
    bool verbose;
    string[] tags;
    string name;
    string[] captured;

    auto root = new Command("geto", "test root");
    root.withFlags(boolFlag(&verbose, "debug", "", "debug"),
        listFlag(&tags, "tag", "t", "tags"));

    auto child = new Command("install", "install something", "<url>");
    child.withAliases("i", "add");
    child.withFlags(textFlag(&name, "provider", "p", "provider"));
    child.withAction((string[] args) { captured = args; });
    root.add(child);

    execute(root, ["add", "-t", "cli,extra", "--provider=github", "github.com/a/b"]);
    assert(captured == ["github.com/a/b"]);
    assert(tags == ["cli", "extra"]);
    assert(name == "github");
    assert(!verbose);

    execute(root, ["install", "--debug", "x"]);
    assert(verbose);
    assert(captured == ["x"]);

    // Flags may precede the subcommand, as cobra allows.
    tags = null;
    captured = null;
    execute(root, ["-t", "essential", "install", "y"]);
    assert(captured == ["y"]);
    assert(tags == ["essential"]);

    string[] rest;
    assert(resolve(root, ["--debug", "install", "z"], rest).name == "install");
    assert(rest == ["--debug", "z"]);

    bool threw;
    try
        execute(root, ["install", "--nope"]);
    catch (UsageException)
        threw = true;
    assert(threw);
}
