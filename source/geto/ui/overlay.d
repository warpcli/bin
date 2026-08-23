module geto.ui.overlay;

import std.array : appender, join, replicate, split;

import mochafizz.ansi.width : stringWidth;
import mochafizz.ansi.wrap : strip, truncate, truncateLeft;
import mochafizz.style : background, bold, foreground, newStyle, padding, render, withBorder;
import mochafizz.uv.border : roundedBorder;

import geto.ui.styles : colorMuted, colorPrimary, colorText, mutedStyle;

/// Renders a modal dialog box.
string dialog(string title, string body_, string footer)
{
    const bar = newStyle().bold().foreground(colorText)
        .background(colorPrimary).padding(0, 1).render(title);

    auto output = appender!string;
    output ~= bar ~ "\n\n";
    output ~= body_;
    if (footer.length > 0)
        output ~= "\n\n" ~ mutedStyle.render(footer);

    return newStyle().withBorder(roundedBorder()).foreground(colorPrimary)
        .padding(1, 2).render(output.data);
}

/// Renders a dialog button.
string button(string label, bool focused)
{
    if (focused)
        return newStyle().bold().foreground(colorText).background(colorPrimary)
            .padding(0, 3).render(label);
    return newStyle().foreground(colorMuted).padding(0, 3).render(label);
}

/// Re-renders text in muted colors, discarding its own styling.
string dim(string text)
{
    return newStyle().foreground(colorMuted).render(text.strip());
}

/// Places `foreground_` centered over `background_`.
string overlay(string background_, string foreground_)
{
    auto backLines = background_.split('\n');
    auto frontLines = foreground_.split('\n');

    int backWidth = 0;
    foreach (line; backLines)
    {
        const width = line.stringWidth();
        if (width > backWidth)
            backWidth = width;
    }
    int frontWidth = 0;
    foreach (line; frontLines)
    {
        const width = line.stringWidth();
        if (width > frontWidth)
            frontWidth = width;
    }

    int startRow = (cast(int) backLines.length - cast(int) frontLines.length) / 2;
    if (startRow < 0)
        startRow = 0;
    int startColumn = (backWidth - frontWidth) / 2;
    if (startColumn < 0)
        startColumn = 0;

    foreach (i, front; frontLines)
    {
        const row = startRow + cast(int) i;
        if (row < 0 || row >= cast(int) backLines.length)
            continue;
        auto back = backLines[row];
        auto left = back.truncate(startColumn);
        const leftWidth = left.stringWidth();
        if (leftWidth < startColumn)
            left ~= " ".replicate(startColumn - leftWidth);
        const right = back.truncateLeft(startColumn + frontWidth);
        backLines[row] = left ~ "\x1b[0m" ~ front ~ "\x1b[0m" ~ right;
    }
    return backLines.join("\n");
}

unittest
{
    const base = "aaaaaaaaaa\naaaaaaaaaa\naaaaaaaaaa";
    const result = overlay(base, "XX");
    assert(result.split('\n').length == 3);
    assert(result.split('\n')[1].strip().stringWidth() == 10);
}
