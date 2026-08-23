module geto.cmd.tui;

import core.time : Duration, msecs, seconds;
import std.algorithm : canFind, max, min, sort;
import std.array : appender, join, replicate, split;
import std.datetime : SysTime;
import std.file : exists, getSize, read, remove;
import std.format : format;
import std.path : baseName;
import std.process : Config, spawnProcess;
import std.stdio : File, stdin, stdout;
import std.string : strip, toLower;

import mochafizz.ansi.color : Color;
import mochafizz.ansi.width : stringWidth;
import mochafizz.ansi.wrap : truncate;
import mochafizz.bubbles.spinner : Spinner, SpinnerTickMsg, newSpinner, tickCmd, update, view;
import mochafizz.bubbles.textinput : TextInput, newTextInput, setValue, update, value, view;
import mochafizz.style : Align, Style, aligned, background, bold, foreground,
    italic, newStyle, padding, render, width, withBorder;
import mochafizz.tea.cmd : Batch, Cmd, Quit, Tick;
import mochafizz.tea.msg : KeyPressMsg, Msg, WindowSizeMsg;
import mochafizz.tea.program : Model, ModelUpdate, newProgram;
import mochafizz.tea.view : View, newView;
import mochafizz.uv.border : roundedBorder;
import mochafizz.uv.key : keyToString = toString, matchString;

import geto.assets : quiet;
import geto.cli : Command;
import geto.cmd.support;
import geto.config;
import geto.log;
import geto.providers;
import geto.ui.overlay : button, dialog, dim, overlay;
import geto.ui.styles;
import geto.util : expandEnv;
import geto.vers : isNewer;

Command tuiCommand()
{
    auto command = new Command("tui", "Launch the interactive terminal UI");
    command.withAction((string[] args) { runTui(); });
    return command;
}

/// Silences the logger and progress bar, which would corrupt the full-screen
/// UI, then runs the program.
void runTui()
{
    const previouslyDiscarded = discard(true);
    const previouslyQuiet = quiet;
    quiet = true;
    scope (exit)
    {
        discard(previouslyDiscarded);
        quiet = previouslyQuiet;
    }

    newProgram(new TuiModel).run();
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

private final class CheckResultMsg : Msg
{
    string path;
    string latest;
    string failure;

    this(string path, string latest, string failure)
    {
        this.path = path;
        this.latest = latest;
        this.failure = failure;
    }
}

private final class UpdateResultMsg : Msg
{
    string path;
    Binary binary;
    string versionText;
    bool updated;
    string failure;

    this(string path, Binary binary, string versionText, bool updated, string failure)
    {
        this.path = path;
        this.binary = binary;
        this.versionText = versionText;
        this.updated = updated;
        this.failure = failure;
    }
}

private final class StatusExpireMsg : Msg
{
    ulong token;

    this(ulong token)
    {
        this.token = token;
    }
}

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

private final class BinRow
{
    Binary binary;
    /// The install path with environment variables expanded.
    string path;

    // Local metadata, read from the file on disk.
    long size;
    string arch;
    string libc;

    // Network metadata.
    string latest;

    bool checking;
    /// Transient per-row status note.
    string note;

    string filterValue() const
    {
        return path.baseName;
    }
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

private enum editFields = [
    "URL", "Provider", "Tags (comma-separated)", "Description"
];

private final class TuiModel : Model
{
    private string[] scopes;
    private size_t scopeIndex;
    private BinRow[] rows;
    private BinRow[] visible;

    private int cursor;
    private int offset;
    private int listHeight = 20;
    private int width = 80;
    private int height = 24;

    private int busy;
    private Spinner spinner;
    private bool spinning;

    private string statusMessage;
    private ulong statusToken;

    private bool filtering;
    private string filterText;

    private bool confirming;
    private string confirmTarget;
    private bool confirmYes;

    private bool editing;
    private BinRow editRow;
    private TextInput[] inputs;
    private size_t editFocus;

    this()
    {
        spinner = newSpinner();
        scopes = collectTagScopes();
        rebuildRows();
    }

    // -----------------------------------------------------------------------
    // Data
    // -----------------------------------------------------------------------

    private string currentScope() const
    {
        return scopes[scopeIndex];
    }

    /// "all" followed by the sorted distinct tags.
    private static string[] collectTagScopes()
    {
        bool[string] seen;
        foreach (binary; get().bins)
        {
            if (binary is null)
                continue;
            foreach (tag; binTags(binary))
                seen[tag] = true;
        }
        auto tags = seen.keys;
        tags.sort();
        return "all" ~ tags;
    }

    /// Recomputes the rows for the active scope, keeping notes already gathered.
    private void rebuildRows()
    {
        BinRow[string] previous;
        foreach (row; rows)
            previous[row.path] = row;

        const scope_ = currentScope();
        auto keys = get().bins.keys;
        keys.sort();

        BinRow[] rebuilt;
        foreach (key; keys)
        {
            auto binary = get().bins[key];
            if (binary is null)
                continue;
            if (scope_ != "all" && !binHasAnyTag(binary, [scope_]))
                continue;

            auto row = new BinRow;
            row.binary = binary;
            row.path = expandEnv(binary.path);
            localMeta(row.path, row.size, row.arch, row.libc);
            if (auto old = row.path in previous)
            {
                row.latest = old.latest;
                row.checking = old.checking;
                row.note = old.note;
            }
            rebuilt ~= row;
        }
        rows = rebuilt;
        applyFilter();
    }

    private void applyFilter()
    {
        if (filterText.length == 0)
            visible = rows;
        else
        {
            BinRow[] matched;
            const needle = filterText.toLower;
            foreach (row; rows)
                if (row.filterValue.toLower.canFind(needle))
                    matched ~= row;
            visible = matched;
        }
        clampCursor();
    }

    private void clampCursor()
    {
        if (cursor >= cast(int) visible.length)
            cursor = cast(int) visible.length - 1;
        if (cursor < 0)
            cursor = 0;
        const rowsPerScreen = max(rowsVisible(), 1);
        if (cursor < offset)
            offset = cursor;
        if (cursor >= offset + rowsPerScreen)
            offset = cursor - rowsPerScreen + 1;
        if (offset < 0)
            offset = 0;
    }

    private int rowsVisible()
    {
        // Each row is three lines; the chrome is title, blank, status and help.
        return max((listHeight - 4) / 3, 1);
    }

    private BinRow selectedRow()
    {
        if (cursor >= 0 && cursor < cast(int) visible.length)
            return visible[cursor];
        return null;
    }

    private BinRow rowByPath(string path)
    {
        foreach (row; rows)
            if (row.path == path)
                return row;
        return null;
    }

    // -----------------------------------------------------------------------
    // Runtime
    // -----------------------------------------------------------------------

    override Cmd init()
    {
        return null;
    }

    private Cmd setStatus(string message)
    {
        statusMessage = message;
        statusToken++;
        const token = statusToken;
        return Tick(4.seconds, (SysTime _) => cast(Msg) new StatusExpireMsg(token));
    }

    private Cmd startSpinner()
    {
        if (spinning)
            return null;
        spinning = true;
        return spinner.tickCmd();
    }

    override ModelUpdate update(Msg message)
    {
        if (auto size = cast(WindowSizeMsg) message)
        {
            if (size.width > 0 && size.height > 0)
            {
                // The app frame is one line of vertical and two columns of
                // horizontal padding on each side.
                width = size.width - 4;
                height = size.height;
                listHeight = size.height - 2;
                clampCursor();
            }
            return ModelUpdate(this, null);
        }

        if (auto expiry = cast(StatusExpireMsg) message)
        {
            if (expiry.token == statusToken)
                statusMessage = "";
            return ModelUpdate(this, null);
        }

        if (cast(SpinnerTickMsg) message)
        {
            auto next = spinner.update(message);
            return ModelUpdate(this, busy > 0 ? next : null);
        }

        if (auto result = cast(CheckResultMsg) message)
            return ModelUpdate(this, handleCheckResult(result));

        if (auto result = cast(UpdateResultMsg) message)
            return ModelUpdate(this, handleUpdateResult(result));

        if (auto press = cast(KeyPressMsg) message)
            return handleKey(press);

        if (editing)
        {
            foreach (ref input; inputs)
                input.update(message);
        }
        return ModelUpdate(this, null);
    }

    private Cmd handleCheckResult(CheckResultMsg result)
    {
        busy--;
        if (auto row = rowByPath(result.path))
        {
            row.checking = false;
            if (result.failure.length > 0)
                row.note = errStyle.render("error");
            else
            {
                row.latest = result.latest;
                row.note = "";
            }
        }
        if (busy <= 0)
        {
            busy = 0;
            spinning = false;
            return setStatus(okStyle.render("check complete"));
        }
        return null;
    }

    private Cmd handleUpdateResult(UpdateResultMsg result)
    {
        busy--;
        if (busy < 0)
            busy = 0;

        string status;
        if (auto row = rowByPath(result.path))
        {
            row.checking = false;
            if (result.failure.length > 0)
            {
                row.note = errStyle.render("failed");
                status = errStyle.render("update failed: " ~ result.failure);
            }
            else if (result.updated)
            {
                if (result.binary !is null)
                {
                    upsertBinary(result.binary);
                    if (auto stored = result.binary.path in get().bins)
                        row.binary = *stored;
                }
                row.latest = "";
                row.note = okStyle.render("updated");
                status = okStyle.render(format("updated %s → %s",
                        result.path.baseName, result.versionText));
            }
            else
            {
                row.note = okStyle.render("up to date");
                status = result.path.baseName ~ " already up to date";
            }
        }
        if (busy == 0)
            spinning = false;
        return setStatus(status);
    }

    // -----------------------------------------------------------------------
    // Keys
    // -----------------------------------------------------------------------

    private ModelUpdate handleKey(KeyPressMsg press)
    {
        const key = press.key;
        if (key.matchString("ctrl+c"))
            return ModelUpdate(this, () => Quit());

        if (editing)
            return handleEditKey(press);
        if (confirming)
            return handleConfirmKey(press);
        if (filtering)
            return handleFilterKey(press);

        if (key.matchString("q"))
            return ModelUpdate(this, () => Quit());
        if (key.matchString("/"))
        {
            filtering = true;
            filterText = "";
            applyFilter();
            return ModelUpdate(this, null);
        }
        if (key.matchString("up", "k"))
        {
            if (cursor > 0)
                cursor--;
            clampCursor();
            return ModelUpdate(this, null);
        }
        if (key.matchString("down", "j"))
        {
            if (cursor < cast(int) visible.length - 1)
                cursor++;
            clampCursor();
            return ModelUpdate(this, null);
        }
        if (key.matchString("home", "g"))
        {
            cursor = 0;
            clampCursor();
            return ModelUpdate(this, null);
        }
        if (key.matchString("end", "G"))
        {
            cursor = cast(int) visible.length - 1;
            clampCursor();
            return ModelUpdate(this, null);
        }
        if (key.matchString("pgup", "ctrl+u"))
        {
            cursor -= rowsVisible();
            clampCursor();
            return ModelUpdate(this, null);
        }
        if (key.matchString("pgdown", "ctrl+d"))
        {
            cursor += rowsVisible();
            clampCursor();
            return ModelUpdate(this, null);
        }
        if (key.matchString("t"))
        {
            scopeIndex = (scopeIndex + 1) % scopes.length;
            rebuildRows();
            return ModelUpdate(this, setStatus("tag: " ~ currentScope()));
        }
        if (key.matchString("p"))
        {
            auto row = selectedRow();
            if (row is null)
                return ModelUpdate(this, null);
            row.binary.pinned = !row.binary.pinned;
            upsertBinary(row.binary);
            return ModelUpdate(this, setStatus((row.binary.pinned
                    ? "pinned " : "unpinned ") ~ row.path.baseName));
        }
        if (key.matchString("e"))
        {
            if (auto row = selectedRow())
                startEdit(row);
            return ModelUpdate(this, null);
        }
        if (key.matchString("m"))
        {
            auto row = selectedRow();
            if (row is null)
                return ModelUpdate(this, null);
            try
                forgetBinarySelection(row.binary.path);
            catch (Exception failure)
                return ModelUpdate(this, setStatus(errStyle.render("forget failed: " ~ failure.msg)));
            if (auto stored = row.binary.path in get().bins)
                row.binary = *stored;
            row.note = okStyle.render("forgot choice");
            return ModelUpdate(this, setStatus("forgot saved choice for " ~ row.path.baseName));
        }
        if (key.matchString("o"))
        {
            auto row = selectedRow();
            if (row is null || row.binary.url.length == 0)
                return ModelUpdate(this, null);
            openUrl(row.binary.url);
            return ModelUpdate(this, setStatus("opening " ~ repoShort(row.binary.url)));
        }
        if (key.matchString("d", "x"))
        {
            if (auto row = selectedRow())
            {
                confirming = true;
                confirmTarget = row.path;
                confirmYes = false;
            }
            return ModelUpdate(this, null);
        }
        if (key.matchString("r"))
        {
            Cmd[] commands;
            foreach (row; rows)
            {
                row.checking = true;
                row.note = "";
                busy++;
                commands ~= checkCommand(row.binary);
            }
            if (commands.length == 0)
                return ModelUpdate(this, null);
            commands ~= startSpinner();
            commands ~= setStatus(format("checking %d binaries…", rows.length));
            return ModelUpdate(this, Batch(commands));
        }
        if (key.matchString("u"))
        {
            auto row = selectedRow();
            if (row is null)
                return ModelUpdate(this, null);
            if (row.binary.pinned)
                return ModelUpdate(this, setStatus(row.path.baseName ~ " is pinned (p to unpin)"));
            row.checking = true;
            row.note = mutedStyle.render("updating…");
            busy++;
            return ModelUpdate(this, Batch([
                performUpdateCommand(row.binary), startSpinner(),
                setStatus("updating " ~ row.path.baseName ~ "…"),
            ]));
        }
        return ModelUpdate(this, null);
    }

    private ModelUpdate handleFilterKey(KeyPressMsg press)
    {
        const key = press.key;
        if (key.matchString("esc"))
        {
            filtering = false;
            filterText = "";
            applyFilter();
            return ModelUpdate(this, null);
        }
        if (key.matchString("enter"))
        {
            filtering = false;
            return ModelUpdate(this, null);
        }
        if (key.matchString("backspace"))
        {
            if (filterText.length > 0)
                filterText = filterText[0 .. $ - 1];
            applyFilter();
            return ModelUpdate(this, null);
        }
        const text = key.keyToString();
        if (text.length == 1 && text[0] >= 0x20 && text[0] < 0x7F)
        {
            filterText ~= text;
            applyFilter();
        }
        return ModelUpdate(this, null);
    }

    private ModelUpdate handleConfirmKey(KeyPressMsg press)
    {
        const key = press.key;
        if (key.matchString("left", "right", "h", "l", "tab"))
        {
            confirmYes = !confirmYes;
            return ModelUpdate(this, null);
        }
        if (key.matchString("y", "Y"))
        {
            confirmYes = true;
            return ModelUpdate(this, doRemove());
        }
        if (key.matchString("n", "N", "esc"))
        {
            confirming = false;
            confirmTarget = "";
            return ModelUpdate(this, setStatus("remove cancelled"));
        }
        if (key.matchString("enter"))
        {
            if (confirmYes)
                return ModelUpdate(this, doRemove());
            confirming = false;
            confirmTarget = "";
            return ModelUpdate(this, setStatus("remove cancelled"));
        }
        return ModelUpdate(this, null);
    }

    private Cmd doRemove()
    {
        const path = confirmTarget;
        confirming = false;
        confirmTarget = "";
        try
        {
            if (path.exists)
                remove(path);
        }
        catch (Exception failure)
            return setStatus(errStyle.render("remove failed: " ~ failure.msg));

        foreach (key, binary; get().bins)
            if (binary !is null && expandEnv(binary.path) == path)
            {
                removeBinaries([key]);
                break;
            }
        rebuildRows();
        return setStatus("removed " ~ path.baseName);
    }

    // -----------------------------------------------------------------------
    // Editing
    // -----------------------------------------------------------------------

    private void startEdit(BinRow row)
    {
        const values = [
            row.binary.url, row.binary.provider, binTags(row.binary).join(","),
            row.binary.description,
        ];
        inputs = new TextInput[editFields.length];
        foreach (i; 0 .. editFields.length)
        {
            inputs[i] = newTextInput();
            inputs[i].prompt = "";
            inputs[i].charLimit = 1024;
            inputs[i].setValue(values[i]);
            inputs[i].focused = false;
        }
        editing = true;
        editRow = row;
        editFocus = 0;
        focusOnly();
    }

    private void focusOnly()
    {
        foreach (i; 0 .. inputs.length)
            inputs[i].focused = i == editFocus;
    }

    private ModelUpdate handleEditKey(KeyPressMsg press)
    {
        const key = press.key;
        if (key.matchString("esc"))
        {
            editing = false;
            inputs = null;
            return ModelUpdate(this, setStatus("edit cancelled"));
        }
        if (key.matchString("enter", "ctrl+s"))
        {
            auto row = editRow;
            row.binary.url = inputs[0].value.strip;
            row.binary.provider = inputs[1].value.strip;

            string[] tags;
            foreach (piece; inputs[2].value.split(','))
            {
                const trimmed = piece.strip;
                if (trimmed.length > 0)
                    tags ~= trimmed;
            }
            row.binary.tags = tags.length == 0 ? ["default"] : tags;
            row.binary.description = inputs[3].value.strip;
            upsertBinary(row.binary);

            editing = false;
            inputs = null;
            scopes = collectTagScopes();
            if (scopeIndex >= scopes.length)
                scopeIndex = 0;
            rebuildRows();
            return ModelUpdate(this, setStatus("saved " ~ row.path.baseName));
        }
        if (key.matchString("tab", "down"))
        {
            editFocus = (editFocus + 1) % inputs.length;
            focusOnly();
            return ModelUpdate(this, null);
        }
        if (key.matchString("shift+tab", "up"))
        {
            editFocus = (editFocus + inputs.length - 1) % inputs.length;
            focusOnly();
            return ModelUpdate(this, null);
        }
        inputs[editFocus].update(press);
        return ModelUpdate(this, null);
    }

    // -----------------------------------------------------------------------
    // Rendering
    // -----------------------------------------------------------------------

    override View view()
    {
        auto base = renderApp();
        string content = base;
        if (editing)
            content = overlay(dim(base), editDialog());
        else if (confirming)
            content = overlay(dim(base), confirmDialog());

        auto result = newView(content);
        result.altScreen = true;
        return result;
    }

    private string renderApp()
    {
        auto output = appender!string;
        const pad = "  ";

        output ~= pad ~ titleStyle.render("geto · " ~ currentScope()) ~ "\n\n";

        const rowsPerScreen = rowsVisible();
        const end = min(offset + rowsPerScreen, cast(int) visible.length);
        foreach (index; offset .. end)
            output ~= renderRow(index) ~ "\n";

        for (int index = end - offset; index < rowsPerScreen; index++)
            output ~= "\n";

        output ~= pad ~ renderStatusBar() ~ "\n";
        output ~= pad ~ mutedStyle.render("↑/↓ move · u update · r check all · p pin · e edit · m forget · o open · d remove · t tag · / filter · q quit");
        return output.data;
    }

    private string renderStatusBar()
    {
        if (filtering)
            return accentStyle.render("filter: ") ~ filterText ~ mutedStyle.render("▌");
        if (statusMessage.length > 0)
            return (spinning ? spinner.view() ~ " " : "") ~ statusMessage;

        const noun = visible.length == 1 ? "binary" : "binaries";
        return mutedStyle.render(format("%d %s", visible.length, noun));
    }

    /// Renders one three-line row: name, metadata, description.
    private string renderRow(int index)
    {
        auto row = visible[index];
        const selected = index == cursor;

        // Alternating shades; the selected row sits closest to the accent.
        auto rowBackground = rowBg;
        if (selected)
            rowBackground = rowBgSelected;
        else if (index % 2 == 1)
            rowBackground = rowBgAlt;

        Style base()
        {
            return newStyle().background(rowBackground);
        }

        string cell(Color fg, int columns, string text, bool right, bool strong)
        {
            if (columns < 1)
                columns = 1;
            auto style = base().foreground(fg).width(columns);
            if (strong)
                style = style.bold();
            if (right)
                style = style.aligned(Align.right);
            return style.render(clip(text, columns));
        }

        string line(string text)
        {
            return base().width(width).render(text);
        }

        const bar = base().foreground(colorPrimary).render(selected ? "┃ " : "  ");
        const inner = width - 2;

        auto statusFg = row.path.exists ? colorOk : colorErr;
        auto nameFg = selected ? colorPrimary : colorText;
        auto name = row.path.baseName;
        if (row.binary.pinned)
            name ~= " ★";

        auto versionText = dash(row.binary.versionText);
        auto versionFg = colorMuted;
        if (row.checking)
            versionText = "working…";
        else if (row.note.length > 0)
            versionText = row.note;
        else if (row.latest.length > 0 && isNewer(row.binary.versionText, row.latest))
        {
            versionText = row.binary.versionText ~ " ↑ " ~ row.latest;
            versionFg = colorWarn;
        }
        else if (row.latest.length > 0)
        {
            versionText = row.binary.versionText ~ " ✓";
            versionFg = colorOk;
        }

        enum versionColumn = 28;
        const nameColumn = inner - 2 - versionColumn;
        const line1 = line(bar ~ cell(statusFg, 2, "●", false,
                false) ~ cell(nameFg, nameColumn, name, false,
                true) ~ cell(versionFg, versionColumn, versionText, true, false));

        enum archColumn = 8, libcColumn = 8, sizeColumn = 9, tagsColumn = 18;
        const repoColumn = inner - archColumn - libcColumn - sizeColumn - tagsColumn;
        const line2 = line(bar ~ cell(colorTag, repoColumn, repoShort(row.binary.url),
                false, false) ~ cell(colorMuted, archColumn, dash(row.arch),
                false, false) ~ cell(colorMuted, libcColumn, dash(row.libc), false,
                false) ~ cell(colorMuted, sizeColumn, sizeText(row.size), false,
                false) ~ cell(colorTag, tagsColumn, binTags(row.binary).join(","), false, false));

        auto info = row.binary.description;
        if (info.length == 0)
            info = row.path;
        const line3 = line(bar ~ base().foreground(colorMuted).italic()
                .width(inner).render(clip(info, inner)));

        return line1 ~ "\n" ~ line2 ~ "\n" ~ line3;
    }

    private string confirmDialog()
    {
        const name = confirmTarget.baseName;
        const body_ = mutedStyle.render("Remove ") ~ accentStyle.render(name) ~ mutedStyle.render(
                " and forget it?") ~ "\n\n" ~ "  " ~ button("Yes",
                confirmYes) ~ "   " ~ button("No", !confirmYes);
        return dialog("Remove binary", body_, "←/→ choose · y/n · enter");
    }

    private string editDialog()
    {
        auto output = appender!string;
        foreach (i; 0 .. inputs.length)
        {
            auto label = "  " ~ mutedStyle.render(editFields[i]);
            if (i == editFocus)
                label = accentStyle.render("▸ " ~ editFields[i]);
            auto field = newStyle().withBorder(roundedBorder()).padding(0, 1)
                .width(56).foreground(i == editFocus ? colorPrimary : colorMuted);
            output ~= label ~ "\n" ~ field.render(inputs[i].view());
            if (i + 1 < inputs.length)
                output ~= "\n";
        }
        return dialog("Edit  " ~ editRow.path.baseName, output.data,
                "tab/↑↓ move · enter save · esc cancel");
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Reads on-disk metadata without touching the network. Only the ELF header,
/// program headers and interpreter string are read, so refreshing a long list
/// does not pull every managed binary through the page cache.
private void localMeta(string path, out long size, out string arch, out string libc)
{
    import geto.elf : ElfReader;

    if (!path.exists)
        return;
    try
        size = getSize(path);
    catch (Exception)
        return;

    auto reader = ElfReader.open(path);
    if (reader is null)
        return;

    arch = elfArch(reader.machine());
    const interp = reader.interpreter();
    if (interp.length == 0)
        libc = "static";
    else if (interp.canFind("musl"))
        libc = "musl";
    else if (interp.canFind("ld-linux") || interp.canFind("/ld-"))
        libc = "glibc";
    else
        libc = "dynamic";
}

/// Maps an ELF `e_machine` value to the architecture names geto uses.
private string elfArch(ushort machine)
{
    switch (machine)
    {
    case 62:
        return "amd64";
    case 183:
        return "arm64";
    case 3:
        return "386";
    case 40:
        return "arm";
    case 243:
        return "riscv64";
    case 21:
        return "ppc64";
    case 22:
        return "s390x";
    default:
        return format("EM_%d", machine);
    }
}

private string dash(string text)
{
    return text.length == 0 ? "—" : text;
}

private string sizeText(long bytes)
{
    return bytes <= 0 ? "—" : humanSize(bytes);
}

/// Formats a byte count with the TUI's shorter unit suffixes.
private string humanSize(long count)
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
    return format("%.1f%cB", cast(double) count / cast(double) div, "KMGT"[exp]);
}

/// Opens a URL in the user's browser, ignoring failures.
private void openUrl(string url)
{
    try
    {
        auto devNull = File("/dev/null", "w");
        spawnProcess(["xdg-open", url], stdin, devNull, devNull);
    }
    catch (Exception)
    {
    }
}

private Cmd checkCommand(Binary binary)
{
    return () {
        try
        {
            auto provider = newProvider(binary.url, binary.provider);
            string tag, url;
            provider.latestVersion(tag, url);
            return cast(Msg) new CheckResultMsg(binary.path, tag, "");
        }
        catch (Exception failure)
            return cast(Msg) new CheckResultMsg(binary.path, "", failure.msg);
    };
}

private Cmd performUpdateCommand(Binary binary)
{
    return () {
        try
        {
            auto provider = newProvider(binary.url, binary.provider);
            string tag, url;
            provider.latestVersion(tag, url);
            if (!isNewer(binary.versionText, tag))
                return cast(Msg) new UpdateResultMsg(binary.path, null,
                        binary.versionText, false, "");

            auto target = newProvider(url, binary.provider);
            FetchOpts fetchOpts;
            fetchOpts.packagePath = binary.packagePath;
            fetchOpts.packageName = binary.remoteName;
            fetchOpts.selectedAsset = binary.selectedAsset;
            fetchOpts.assetFingerprint = binary.assetFingerprint;
            fetchOpts.nonInteractive = true;
            auto result = target.fetch(fetchOpts);

            auto hash = saveToDisk(result, binary.path, true);

            auto updated = new Binary;
            updated.remoteName = result.name;
            updated.path = binary.path;
            updated.versionText = result.versionText;
            updated.hash = hexDigest(hash);
            updated.url = binary.url;
            updated.provider = target.id();
            updated.packagePath = result.packagePath;
            updated.stateUrl = url;
            updated.selectedAsset = result.selectedAsset;
            updated.assetFingerprint = result.assetFingerprint;
            updated.tags = binary.tags;
            return cast(Msg) new UpdateResultMsg(binary.path, updated,
                    result.versionText, true, "");
        }
        catch (Exception failure)
            return cast(Msg) new UpdateResultMsg(binary.path, null, "", false, failure.msg);
    };
}

unittest
{
    assert(humanSize(512) == "512B");
    assert(humanSize(2048) == "2.0KB");
    assert(humanSize(1024L * 1024) == "1.0MB");
    assert(dash("") == "—");
    assert(dash("x") == "x");
    assert(sizeText(0) == "—");
    assert(elfArch(62) == "amd64");
    assert(elfArch(183) == "arm64");
}
