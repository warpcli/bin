module geto.vers;

import std.algorithm : all, max;
import std.array : split;
import std.ascii : isAlpha, isDigit;
import std.conv : ConvException, to;
import std.string : indexOf, startsWith, strip;

/// A leniently parsed version, mirroring hashicorp/go-version's accepted forms.
struct Version
{
    long[] segments;
    string preRelease;
    string metadata;
    string original;
}

private bool isNumericIdentifier(string text)
{
    return text.length > 0 && text.all!isDigit;
}

/// Parses `v1.2.3-beta.1+build` and friends. Returns false on anything unparseable.
bool parseVersion(string text, out Version result)
{
    string rest = text.strip();
    if (rest.length == 0)
        return false;
    if (rest[0] == 'v' || rest[0] == 'V')
        rest = rest[1 .. $];

    const plus = rest.indexOf('+');
    if (plus >= 0)
    {
        result.metadata = rest[plus + 1 .. $];
        rest = rest[0 .. plus];
    }

    size_t coreEnd = 0;
    while (coreEnd < rest.length && (rest[coreEnd].isDigit || rest[coreEnd] == '.'))
        coreEnd++;
    // A trailing dot belongs to neither the core nor the pre-release.
    while (coreEnd > 0 && rest[coreEnd - 1] == '.')
        coreEnd--;

    const core = rest[0 .. coreEnd];
    string tail = rest[coreEnd .. $];
    if (core.length == 0)
        return false;

    foreach (piece; core.split('.'))
    {
        if (!isNumericIdentifier(piece))
            return false;
        try
            result.segments ~= piece.to!long;
        catch (ConvException)
            return false;
    }

    if (tail.length > 0)
    {
        if (tail[0] == '-')
            tail = tail[1 .. $];
        else if (!(tail[0].isAlpha || tail[0] == '~'))
            return false;
        if (tail.length == 0)
            return false;
        result.preRelease = tail;
    }

    result.original = text.strip();
    return true;
}

private long segmentAt(const Version v, size_t index)
{
    return index < v.segments.length ? v.segments[index] : 0;
}

private int comparePreRelease(string left, string right)
{
    if (left == right)
        return 0;
    if (left.length == 0)
        return 1;
    if (right.length == 0)
        return -1;

    auto lhs = left.split('.');
    auto rhs = right.split('.');
    const shared_ = lhs.length < rhs.length ? lhs.length : rhs.length;
    foreach (i; 0 .. shared_)
    {
        if (lhs[i] == rhs[i])
            continue;
        const lnum = isNumericIdentifier(lhs[i]);
        const rnum = isNumericIdentifier(rhs[i]);
        if (lnum && rnum)
        {
            const a = lhs[i].to!long;
            const b = rhs[i].to!long;
            return a < b ? -1 : 1;
        }
        if (lnum != rnum)
            return lnum ? -1 : 1;
        return lhs[i] < rhs[i] ? -1 : 1;
    }
    if (lhs.length == rhs.length)
        return 0;
    return lhs.length < rhs.length ? -1 : 1;
}

/// Orders two versions; metadata is ignored, matching semver rules.
int compare(const Version left, const Version right)
{
    const count = max(left.segments.length, right.segments.length);
    foreach (i; 0 .. count)
    {
        const a = segmentAt(left, i);
        const b = segmentAt(right, i);
        if (a != b)
            return a < b ? -1 : 1;
    }
    return comparePreRelease(left.preRelease, right.preRelease);
}

/// True when both strings parse and `candidate` sorts strictly above `current`.
bool isNewer(string current, string candidate)
{
    Version a, b;
    if (!parseVersion(current, a) || !parseVersion(candidate, b))
        return current != candidate;
    return compare(b, a) > 0;
}

/// True when both parse and `candidate` sorts at or below `current`.
bool isNotNewer(string current, string candidate)
{
    Version a, b;
    if (!parseVersion(current, a) || !parseVersion(candidate, b))
        return false;
    return compare(b, a) <= 0;
}

/// A strict `X.Y.Z` version, mirroring coreos/go-semver.
struct StrictVersion
{
    long major;
    long minor;
    long patch;
    string preRelease;
    string metadata;
    string original;
}

bool parseStrictVersion(string text, out StrictVersion result)
{
    string rest = text.strip();
    if (rest.length == 0)
        return false;

    const plus = rest.indexOf('+');
    if (plus >= 0)
    {
        result.metadata = rest[plus + 1 .. $];
        rest = rest[0 .. plus];
    }
    const dash = rest.indexOf('-');
    if (dash >= 0)
    {
        result.preRelease = rest[dash + 1 .. $];
        rest = rest[0 .. dash];
    }

    auto parts = rest.split('.');
    if (parts.length != 3)
        return false;
    foreach (piece; parts)
        if (!isNumericIdentifier(piece))
            return false;

    result.major = parts[0].to!long;
    result.minor = parts[1].to!long;
    result.patch = parts[2].to!long;
    result.original = text.strip();
    return true;
}

int compareStrict(const StrictVersion left, const StrictVersion right)
{
    if (left.major != right.major)
        return left.major < right.major ? -1 : 1;
    if (left.minor != right.minor)
        return left.minor < right.minor ? -1 : 1;
    if (left.patch != right.patch)
        return left.patch < right.patch ? -1 : 1;
    return comparePreRelease(left.preRelease, right.preRelease);
}

unittest
{
    Version v;
    assert(parseVersion("v1.2.3", v));
    assert(v.segments == [1L, 2L, 3L]);
    assert(parseVersion("1.2.3-beta.1+build5", v));
    assert(v.preRelease == "beta.1" && v.metadata == "build5");
    assert(!parseVersion("nightly", v));

    assert(isNewer("1.2.3", "1.2.4"));
    assert(isNewer("1.2.3-beta", "1.2.3"));
    assert(!isNewer("1.2.3", "1.2.3"));
    assert(!isNewer("2.0.0", "1.9.9"));
    assert(isNewer("1.9", "1.10"));

    StrictVersion s;
    assert(parseStrictVersion("1.2.3", s) && s.preRelease.length == 0);
    assert(!parseStrictVersion("1.2", s));
}

unittest
{
    // The update check: only a strictly higher version counts.
    assert(isNewer("1.1.0", "1.1.1"));
    assert(!isNewer("1.2.0-rc.1", "1.1.1"));
    assert(!isNewer("1.1.1", "1.1.1"));
    assert(isNewer("1.2.0-rc.1", "1.2.0"));
    assert(isNewer("v0.26.0", "v0.26.1"));

    // Unparseable versions fall back to plain inequality, as hashicorp does.
    assert(isNewer("nightly", "nightly-2"));
    assert(!isNewer("nightly", "nightly"));

    // isNotNewer is the update guard: true only when both parse and the
    // candidate is at or below the installed version.
    assert(isNotNewer("1.2.0", "1.1.0"));
    assert(isNotNewer("1.2.0", "1.2.0"));
    assert(!isNotNewer("1.2.0", "1.3.0"));
    assert(!isNotNewer("nightly", "whatever"));
}
