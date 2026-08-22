module geto.util;

import std.algorithm : any, canFind;

/// True when `text` contains any of `needles`.
bool containsAny(string text, const string[] needles)
{
    return needles.any!(needle => text.canFind(needle));
}

unittest
{
    assert("linux-amd64".containsAny(["amd64", "x86_64"]));
    assert(!"linux-arm64".containsAny(["amd64", "x86_64"]));
}

/// Expands `$VAR` and `${VAR}` references against the process environment.
string expandEnv(string text)
{
    import std.array : appender;
    import std.ascii : isAlphaNum;
    import std.process : environment;

    auto output = appender!string;
    size_t i = 0;
    while (i < text.length)
    {
        if (text[i] != '$')
        {
            output ~= text[i];
            i++;
            continue;
        }
        i++;
        if (i >= text.length)
        {
            output ~= '$';
            break;
        }
        if (text[i] == '{')
        {
            i++;
            const start = i;
            while (i < text.length && text[i] != '}')
                i++;
            const name = text[start .. i];
            if (i < text.length)
                i++;
            output ~= environment.get(name, "");
            continue;
        }
        const start = i;
        while (i < text.length && (text[i].isAlphaNum || text[i] == '_'))
            i++;
        if (i == start)
        {
            output ~= '$';
            continue;
        }
        output ~= environment.get(text[start .. i], "");
    }
    return output.data;
}

/// Reports whether the named environment variable holds a truthy value.
bool envBool(string name)
{
    import std.process : environment;
    import std.string : strip, toLower;

    switch (environment.get(name, "").strip.toLower)
    {
    case "1":
    case "true":
    case "yes":
    case "on":
        return true;
    default:
        return false;
    }
}

/// The user's home directory, or "" when it cannot be determined.
string homeDir()
{
    import std.process : environment;

    return environment.get("HOME", "");
}

unittest
{
    import std.process : environment;

    environment["GETO_TEST_EXPAND"] = "value";
    assert(expandEnv("a/$GETO_TEST_EXPAND/b") == "a/value/b");
    assert(expandEnv("a/${GETO_TEST_EXPAND}/b") == "a/value/b");
    assert(expandEnv("plain") == "plain");
    assert(expandEnv("$") == "$");
}
