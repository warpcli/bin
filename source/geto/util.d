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
