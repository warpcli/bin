module geto.jsonutil;

import std.json : JSONType, JSONValue;

/// Reads a string field, returning "" when absent or of another type.
string jstr(const JSONValue node, string key)
{
    if (node.type != JSONType.object)
        return "";
    if (auto found = key in node.objectNoRef)
        return found.type == JSONType.string ? found.str : "";
    return "";
}

/// Reads a boolean field, defaulting to `fallback` when absent.
bool jbool(const JSONValue node, string key, bool fallback = false)
{
    if (node.type != JSONType.object)
        return fallback;
    if (auto found = key in node.objectNoRef)
    {
        if (found.type == JSONType.true_)
            return true;
        if (found.type == JSONType.false_)
            return false;
    }
    return fallback;
}

/// Reads an integer field, defaulting to `fallback` when absent.
long jnum(const JSONValue node, string key, long fallback = 0)
{
    if (node.type != JSONType.object)
        return fallback;
    if (auto found = key in node.objectNoRef)
    {
        if (found.type == JSONType.integer)
            return found.integer;
        if (found.type == JSONType.uinteger)
            return cast(long) found.uinteger;
    }
    return fallback;
}

/// Reads an array field, returning an empty slice when absent.
const(JSONValue)[] jitems(const JSONValue node, string key)
{
    if (node.type != JSONType.object)
        return null;
    if (auto found = key in node.objectNoRef)
        if (found.type == JSONType.array)
            return found.arrayNoRef;
    return null;
}

/// Reads a nested object, returning a null JSON value when absent.
JSONValue jobject(const JSONValue node, string key)
{
    if (node.type == JSONType.object)
        if (auto found = key in node.objectNoRef)
            return *found;
    return JSONValue(null);
}

/// Percent-encodes a path segment for use in a URL.
string urlEscape(string text)
{
    import std.ascii : isAlphaNum;
    import std.format : format;

    string result;
    foreach (char c; text)
    {
        if (c.isAlphaNum || c == '-' || c == '_' || c == '.' || c == '~')
            result ~= c;
        else
            result ~= format("%%%02X", cast(ubyte) c);
    }
    return result;
}

unittest
{
    import std.json : parseJSON;

    auto node = parseJSON(`{"a":"x","b":true,"c":7,"d":[1,2]}`);
    assert(node.jstr("a") == "x");
    assert(node.jbool("b"));
    assert(node.jnum("c") == 7);
    assert(node.jitems("d").length == 2);
    assert(node.jstr("missing") == "");
    assert(urlEscape("group/project") == "group%2Fproject");
}
