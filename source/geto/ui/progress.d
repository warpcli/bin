module geto.ui.progress;

import core.time : Duration, MonoTime, msecs;
import std.array : replicate;
import std.format : format;
import std.stdio : stderr;

import mochafizz.style : render;

import geto.ui.styles : accentStyle, clip, mutedStyle, padRight, tagStyle,
    terminalWidth, warnStyle;

/// Renders a single-line download progress bar on stderr.
struct ProgressBar
{
    private long total;
    private long readSoFar;
    private string label;
    private MonoTime start;
    private MonoTime lastDraw;
    private bool finished;

    static ProgressBar opCall(long total, string label)
    {
        ProgressBar bar;
        bar.total = total;
        bar.label = label;
        bar.start = MonoTime.currTime;
        bar.lastDraw = bar.start;
        return bar;
    }

    /// Records more bytes, redrawing at most every 70ms.
    void advance(size_t count)
    {
        readSoFar += count;
        const now = MonoTime.currTime;
        if (now - lastDraw >= 70.msecs)
        {
            lastDraw = now;
            render();
        }
    }

    /// Draws the final state and moves to the next line.
    void finish()
    {
        if (finished)
            return;
        finished = true;
        render();
        stderr.write("\n");
        stderr.flush();
    }

    private void render()
    {
        // Fixed-width columns so every row lines up regardless of label length:
        //   "  ⤓ " + label(labelW) + "  " + bar(barW) + "  " + pct(4) + "  " + size(20)
        enum labelW = 26;
        int barW = terminalWidth() - labelW - 38;
        if (barW < 10)
            barW = 10;
        if (barW > 50)
            barW = 50;

        double fraction = 0;
        if (total > 0)
        {
            fraction = cast(double) readSoFar / cast(double) total;
            if (fraction > 1)
                fraction = 1;
        }
        int filled = cast(int)(fraction * barW);
        if (filled > barW)
            filled = barW;

        const bar = accentStyle.render("█".replicate(filled)) ~ mutedStyle.render(
                "░".replicate(barW - filled));

        const elapsed = (MonoTime.currTime - start).total!"msecs" / 1000.0;
        const speed = elapsed > 0 ? cast(long)(readSoFar / elapsed) : 0;

        auto sizeText = total > 0 ? format("%s/%s", humanBytes(readSoFar), humanBytes(total)) : humanBytes(
                readSoFar);
        const stats = format("%-20s %9s/s", sizeText, humanBytes(speed));

        const line = format("  %s %s  %s  %s  %s", accentStyle.render("⤓"),
                tagStyle.render(padRight(label, labelW)), bar,
                warnStyle.render(format("%3.0f%%", fraction * 100)), mutedStyle.render(stats));

        // \r to the line start, draw, then clear to end-of-line.
        stderr.write("\r", line, "\x1b[K");
        stderr.flush();
    }
}

/// Formats a byte count using binary units.
string humanBytes(long count)
{
    enum long unit = 1024;
    if (count < unit)
        return format("%dB", count);
    long div = unit;
    size_t exp = 0;
    for (long rest = count / unit; rest >= unit; rest /= unit)
    {
        div *= unit;
        exp++;
    }
    return format("%.1f%ciB", cast(double) count / cast(double) div, "KMGT"[exp]);
}

unittest
{
    assert(humanBytes(512) == "512B");
    assert(humanBytes(1024) == "1.0KiB");
    assert(humanBytes(1536) == "1.5KiB");
    assert(humanBytes(1024L * 1024) == "1.0MiB");
    assert(humanBytes(1024L * 1024 * 1024) == "1.0GiB");
}
