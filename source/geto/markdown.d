module geto.markdown;

/// An inline markdown link.
struct Link
{
    string text;
    string destination;
    string title;
}

/// Extracts inline `[text](dest "title")` links, skipping images. Enough for
/// scraping asset links out of a release description.
Link[] inlineLinks(string source)
{
    Link[] result;
    size_t i = 0;
    while (i < source.length)
    {
        if (source[i] == '\\')
        {
            i += 2;
            continue;
        }
        if (source[i] != '[')
        {
            i++;
            continue;
        }
        // An image is `![text](dest)`; only plain links are wanted.
        const isImage = i > 0 && source[i - 1] == '!';

        size_t cursor = i + 1;
        int depth = 1;
        while (cursor < source.length && depth > 0)
        {
            if (source[cursor] == '\\')
            {
                cursor += 2;
                continue;
            }
            if (source[cursor] == '[')
                depth++;
            else if (source[cursor] == ']')
                depth--;
            if (depth == 0)
                break;
            cursor++;
        }
        if (cursor >= source.length || source[cursor] != ']')
        {
            i++;
            continue;
        }
        const text = source[i + 1 .. cursor];

        cursor++;
        if (cursor >= source.length || source[cursor] != '(')
        {
            i = cursor;
            continue;
        }
        cursor++;

        const targetStart = cursor;
        depth = 1;
        while (cursor < source.length && depth > 0)
        {
            if (source[cursor] == '\\')
            {
                cursor += 2;
                continue;
            }
            if (source[cursor] == '(')
                depth++;
            else if (source[cursor] == ')')
                depth--;
            if (depth == 0)
                break;
            cursor++;
        }
        if (cursor >= source.length)
            break;

        auto target = source[targetStart .. cursor];
        if (!isImage)
        {
            Link link;
            link.text = text;
            splitTarget(target, link.destination, link.title);
            result ~= link;
        }
        i = cursor + 1;
    }
    return result;
}

/// Splits a link target into its destination and optional quoted title.
private void splitTarget(string target, out string destination, out string title)
{
    import std.string : strip;

    auto rest = target.strip;
    size_t cut = 0;
    while (cut < rest.length && rest[cut] != ' ' && rest[cut] != '\t' && rest[cut] != '\n')
        cut++;
    destination = rest[0 .. cut];
    if (destination.length >= 2 && destination[0] == '<' && destination[$ - 1] == '>')
        destination = destination[1 .. $ - 1];

    auto tail = rest[cut .. $].strip;
    if (tail.length >= 2)
    {
        const quote = tail[0];
        if ((quote == '"' || quote == '\'' || quote == '(') && tail[$ - 1] != quote)
        {
            const closer = quote == '(' ? ')' : quote;
            if (tail[$ - 1] == closer)
                title = tail[1 .. $ - 1];
        }
        else if ((quote == '"' || quote == '\'') && tail[$ - 1] == quote)
            title = tail[1 .. $ - 1];
    }
}

unittest
{
    auto links = inlineLinks("see [tool.tar.gz](https://x/y.tar.gz \"tool\") and ![img](a.png)");
    assert(links.length == 1);
    assert(links[0].text == "tool.tar.gz");
    assert(links[0].destination == "https://x/y.tar.gz");
    assert(links[0].title == "tool");

    auto plain = inlineLinks("[a](b)");
    assert(plain.length == 1 && plain[0].destination == "b" && plain[0].title.length == 0);

    assert(inlineLinks("no links here").length == 0);
    assert(inlineLinks("[unclosed(x)").length == 0);
}
