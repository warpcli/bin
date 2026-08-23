module geto.ui.styles;

import std.array : join, replicate;
import std.conv : ConvException, to;
import std.file : exists, readText, write;
import std.process : environment;
import std.string : indexOf, startsWith, strip, stripRight;

import mochafizz.ansi.color : Color, basicColor, extendedColor, rgbColor;
import mochafizz.style : Align, Style, background, bold, foreground, newStyle,
    padding, render, width;
import mochafizz.table : StaticTable, headerRow, newStaticTable;
import mochafizz.term.raw : getSize, isTerminal;
import mochafizz.uv.border : roundedBorder;

/// Terminal palette used by both the CLI and the TUI.
Color colorPrimary;
Color colorOk;
Color colorWarn;
Color colorErr;
Color colorTag;
Color colorMuted;
Color colorText;
Color rowBg;
Color rowBgAlt;
Color rowBgSelected;

/// Reusable styles built from the palette.
Style titleStyle;
Style accentStyle;
Style mutedStyle;
Style okStyle;
Style warnStyle;
Style errStyle;
Style tagStyle;
Style pinStyle;
Style borderStyle;

shared static this()
{
    resetPalette();
    applyStyles();
}

private void resetPalette()
{
    colorPrimary = basicColor(1);
    colorOk = basicColor(2);
    colorWarn = basicColor(3);
    colorErr = extendedColor(9);
    colorTag = basicColor(6);
    colorMuted = extendedColor(8);
    colorText = extendedColor(15);
    rowBg = extendedColor(232);
    rowBgAlt = extendedColor(235);
    rowBgSelected = extendedColor(237);
}

private void applyStyles()
{
    titleStyle = newStyle().bold().foreground(colorText).background(colorPrimary).padding(0, 1);
    accentStyle = newStyle().foreground(colorPrimary).bold();
    mutedStyle = newStyle().foreground(colorMuted);
    okStyle = newStyle().foreground(colorOk);
    warnStyle = newStyle().foreground(colorWarn);
    errStyle = newStyle().foreground(colorErr);
    tagStyle = newStyle().foreground(colorTag);
    pinStyle = newStyle().foreground(colorWarn);
    borderStyle = newStyle().foreground(colorMuted);
}

/// The default theme file contents.
enum defaultThemeConf = `# geto TUI theme — colors are terminal palette indexes (0-255) or hex (#aabbcc).
# Palette names recolor automatically with pywal-style tools. The 232..255
# grayscale ramp is handy for subtle row shading.

# foreground colors
accent = 1     # highlights, selection, title background
text   = 15    # primary text
muted  = 8     # secondary text / separators
ok     = 2     # up to date / present
warn   = 3     # update available / pinned
err    = 9     # missing / errors
tag    = 6     # tag chips & repo

# TUI row backgrounds (alternating + selected)
row_bg          = 232  # even rows
row_bg_alt      = 235  # odd rows
row_bg_selected = 237  # selected row
`;

/// Writes the theme file if absent, then loads it.
void ensureTheme(string path)
{
    if (path.length == 0)
        return;
    if (!path.exists)
    {
        try
            write(path, defaultThemeConf);
        catch (Exception)
            return;
    }
    try
        loadTheme(path);
    catch (Exception)
    {
    }
}

/// Parses a palette entry: a 0-255 index or a `#rrggbb` literal.
private bool parseColor(string text, out Color color)
{
    if (text.length == 0)
        return false;
    if (text[0] == '#')
    {
        if (text.length != 7)
            return false;
        try
            color = rgbColor(text[1 .. $].to!uint(16));
        catch (ConvException)
            return false;
        return true;
    }
    try
    {
        const index = text.to!int;
        if (index < 0 || index > 255)
            return false;
        color = index < 16 ? basicColor(cast(ubyte) index) : extendedColor(cast(ubyte) index);
    }
    catch (ConvException)
        return false;
    return true;
}

/// Applies colour overrides from a theme file.
void loadTheme(string path)
{
    import std.string : splitLines;

    foreach (raw; readText(path).splitLines)
    {
        auto line = raw.strip;
        if (line.length == 0 || line.startsWith("#"))
            continue;
        const split = line.indexOf('=');
        if (split < 0)
            continue;
        const key = line[0 .. split].strip;
        auto value = line[split + 1 .. $].strip;
        const comment = value.indexOf('#');
        if (comment > 0)
            value = value[0 .. comment].strip;
        else if (comment == 0)
            continue;

        Color parsed;
        if (!parseColor(value, parsed))
            continue;
        switch (key)
        {
        case "accent":
            colorPrimary = parsed;
            break;
        case "text":
            colorText = parsed;
            break;
        case "muted":
            colorMuted = parsed;
            break;
        case "ok":
            colorOk = parsed;
            break;
        case "warn":
            colorWarn = parsed;
            break;
        case "err":
            colorErr = parsed;
            break;
        case "tag":
            colorTag = parsed;
            break;
        case "row_bg":
            rowBg = parsed;
            break;
        case "row_bg_alt":
            rowBgAlt = parsed;
            break;
        case "row_bg_selected":
            rowBgSelected = parsed;
            break;
        default:
            break;
        }
    }
    applyStyles();
}

/// Renders a title chip.
string banner(string text)
{
    return titleStyle.render(text);
}

/// Renders a horizontal rule spanning the terminal.
string rule()
{
    return mutedStyle.render("─".replicate(terminalWidth()));
}

/// Strips the scheme and trailing slash from a repository URL.
string repoShort(string url)
{
    auto text = url;
    foreach (prefix; ["https://", "http://"])
        if (text.startsWith(prefix))
        {
            text = text[prefix.length .. $];
            break;
        }
    if (text.length > 0 && text[$ - 1] == '/')
        text = text[0 .. $ - 1];
    return text;
}

/// Renders tags as styled text.
string tags(const string[] values)
{
    string[] rendered;
    foreach (value; values)
        rendered ~= tagStyle.render(value);
    return rendered.join(" ");
}

/// Renders a presence indicator.
string statusDot(bool present)
{
    return present ? okStyle.render("● ok") : errStyle.render("● missing");
}

/// One row of the binary listing.
struct ListRow
{
    string path;
    string versionText;
    string[] tags;
    string url;
    bool present;
    bool pinned;
}

/// Renders the binary listing table.
string listTable(ListRow[] rows, int width)
{
    if (width < 40)
        width = 40;
    int budget = width - 16;
    if (budget < 40)
        budget = 40;
    enum verW = 12, tagW = 16, stW = 9;
    int flex = budget - verW - tagW - stW;
    if (flex < 24)
        flex = 24;
    const nameW = flex * 11 / 20;
    const repoW = flex - nameW;

    auto captured = rows;
    auto table = newStaticTable().border(roundedBorder()).borderStyle(borderStyle)
        .totalWidth(width).headers("BINARY", "VERSION", "TAGS", "STATUS",
            "REPO").styleFunc((int row, int column) {
        auto style = newStyle().padding(0, 1);
        if (row == headerRow)
            return style.bold().foreground(colorPrimary);
        switch (column)
        {
        case 1:
            if (row >= 0 && row < cast(int) captured.length && captured[row].pinned)
                return style.foreground(colorWarn);
            return style;
        case 2:
            return style.foreground(colorTag);
        case 3:
            if (row >= 0 && row < cast(int) captured.length && !captured[row].present)
                return style.foreground(colorErr);
            return style.foreground(colorOk);
        case 4:
            return style.foreground(colorMuted);
        default:
            return style;
        }
    });

    foreach (row; rows)
    {
        auto versionText = row.pinned ? "★ " ~ row.versionText : row.versionText;
        table.row(clip(row.path, nameW), clip(versionText, verW),
                clip(row.tags.join(","), tagW), row.present
                ? "● ok" : "● missing", clip(repoShort(row.url), repoW),);
    }
    return table.toString();
}

/// Truncates text to `columns` display columns, adding an ellipsis.
string clip(string text, int columns)
{
    import mochafizz.ansi.width : stringWidth;
    import mochafizz.ansi.wrap : truncate;

    if (columns <= 0)
        return "";
    if (text.stringWidth() <= columns)
        return text;
    if (columns == 1)
        return "…";
    return text.truncate(columns, "…");
}

/// Right-pads text to `columns`, clipping first when it overflows.
string padRight(string text, int columns)
{
    import mochafizz.ansi.width : stringWidth;

    auto clipped = clip(text, columns);
    const gap = columns - clipped.stringWidth();
    return gap > 0 ? clipped ~ " ".replicate(gap) : clipped;
}

/// The terminal width, falling back to `$COLUMNS` and then 100.
int terminalWidth()
{
    if (isTerminal(1))
    {
        const size = getSize(1);
        if (size.width > 0)
            return size.width;
    }
    const columns = environment.get("COLUMNS", "");
    if (columns.length > 0)
    {
        try
        {
            const parsed = columns.to!int;
            if (parsed > 0)
                return parsed;
        }
        catch (ConvException)
        {
        }
    }
    return 100;
}

unittest
{
    assert(repoShort("https://github.com/sharkdp/bat/") == "github.com/sharkdp/bat");
    assert(clip("abcdef", 3) == "ab…");
    assert(clip("ab", 5) == "ab");
    assert(padRight("ab", 4) == "ab  ");

    Color parsed;
    assert(parseColor("12", parsed));
    assert(parseColor("#aabbcc", parsed));
    assert(!parseColor("nope", parsed));
    assert(!parseColor("300", parsed));
}
