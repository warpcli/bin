module geto.log;

import std.array : replicate;
import std.conv : to;
import std.format : format;
import std.stdio : File, stderr;
import std.string : toLower;

import mochafizz.ansi.color : Color, extendedColor;
import mochafizz.style : Style, bold, foreground, newStyle, render;
import mochafizz.term.raw : isTerminal;

enum Level
{
    dbg = 0,
    info,
    warn,
    error,
    fatal,
}

private enum defaultPadding = 2;

private immutable string[5] levelNames = [
    "debug", "info", "warn", "error", "fatal"
];
private immutable string[5] levelSymbols = ["•", "•", "•", "⨯", "⨯"];
private immutable ubyte[5] levelColors = [15, 12, 11, 9, 9];

private struct Field
{
    string key;
    string value;
}

private struct State
{
    Level level = Level.info;
    int padding = defaultPadding;
    File sink;
    bool discarded;
    bool color;
    bool initialised;
}

private State state;

private void ensureInit()
{
    if (state.initialised)
        return;
    state.sink = stderr;
    state.color = isTerminal(2);
    state.initialised = true;
}

/// Parses a level name, returning false when the name is unknown.
bool parseLevel(string name, out Level level)
{
    switch (name.toLower)
    {
    case "debug":
        level = Level.dbg;
        return true;
    case "info":
        level = Level.info;
        return true;
    case "warn":
    case "warning":
        level = Level.warn;
        return true;
    case "error":
        level = Level.error;
        return true;
    case "fatal":
        level = Level.fatal;
        return true;
    default:
        return false;
    }
}

string levelName(Level level)
{
    return levelNames[cast(size_t) level];
}

void setLevel(Level level)
{
    ensureInit();
    state.level = level;
}

Level currentLevel()
{
    ensureInit();
    return state.level;
}

void setOutput(File sink)
{
    ensureInit();
    state.sink = sink;
    state.color = isTerminal(sink.fileno);
}

/// Silences all output; returns the previous state so it can be restored.
bool discard(bool enabled)
{
    ensureInit();
    const previous = state.discarded;
    state.discarded = enabled;
    return previous;
}

void resetPadding()
{
    ensureInit();
    state.padding = defaultPadding;
}

void increasePadding()
{
    ensureInit();
    state.padding += defaultPadding;
}

void decreasePadding()
{
    ensureInit();
    state.padding -= defaultPadding;
}

private string paint(Level level, string text)
{
    if (!state.color)
        return text;
    return newStyle().foreground(extendedColor(levelColors[cast(size_t) level])).bold()
        .render(text);
}

private string rightAlign(string text, int width)
{
    import mochafizz.ansi.width : stringWidth;

    const gap = width - stringWidth(text);
    return gap > 0 ? replicate(" ", gap) ~ text : text;
}

private void emit(Level level, string message, Field[] fields = null)
{
    ensureInit();
    if (state.discarded || level < state.level)
        return;

    const marker = paint(level, rightAlign(levelSymbols[cast(size_t) level], 1 + state.padding));
    string line = marker ~ " " ~ message;
    foreach (field; fields)
        line ~= " " ~ paint(level, field.key) ~ "=" ~ field.value;
    state.sink.writeln(line);
    state.sink.flush();
}

void debugf(Args...)(string fmt, Args args)
{
    ensureInit();
    if (Level.dbg < state.level)
        return;
    emit(Level.dbg, format(fmt, args));
}

void infof(Args...)(string fmt, Args args)
{
    emit(Level.info, format(fmt, args));
}

void warnf(Args...)(string fmt, Args args)
{
    emit(Level.warn, format(fmt, args));
}

void errorf(Args...)(string fmt, Args args)
{
    emit(Level.error, format(fmt, args));
}

void info(string message)
{
    emit(Level.info, message);
}

void warn(string message)
{
    emit(Level.warn, message);
}

void error(string message)
{
    emit(Level.error, message);
}

/// Logs at error level with the failure attached as an `error=` field.
void errorWith(Throwable failure, string message)
{
    emit(Level.error, message, [Field("error", failure.msg)]);
}

void fatalf(Args...)(string fmt, Args args)
{
    import core.stdc.stdlib : exit;

    emit(Level.fatal, format(fmt, args));
    exit(1);
}
