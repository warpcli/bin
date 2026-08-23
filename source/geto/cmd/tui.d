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

import mochafizz.ansi.color : Color, rgbColor;
import mochafizz.ansi.width : stringWidth;
import mochafizz.ansi.wrap : truncate;
import mochafizz.bubbles.paginator : Paginator, newPaginator, nextPage,
    onLastPage, pkDots, previousPage, itemsOnPage, sliceBounds, totalPages;
import mochafizz.bubbles.spinner : LineFrames, Spinner, SpinnerTickMsg,
    newSpinner, tickCmd, update, view;
import mochafizz.bubbles.textinput : TextInput, clear, newTextInput,
    setValue, update, value, view;
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
// Key bindings
// ---------------------------------------------------------------------------

/// One key binding plus the text the help line shows for it.
private struct Binding
{
    string[] keys;
    string helpKey;
    string helpDesc;
    bool enabled = true;

    bool matches(const ref KeyPressMsg press) const
    {
        foreach (name; keys)
            if (press.key.matchString(name))
                return true;
        return false;
    }
}

/// Palette for the list chrome. The Go build only restyled the title, so
/// everything else keeps bubbles' own defaults and is reproduced here.
private Color helpKeyColor;
private Color helpDescColor;
private Color helpSepColor;
private Color statusBarColor;
private Color statusEmptyColor;
private Color activeDotColor;
private Color inactiveDotColor;

shared static this()
{
    helpKeyColor = rgbColor(0x626262);
    helpDescColor = rgbColor(0x4A4A4A);
    helpSepColor = rgbColor(0x3C3C3C);
    statusBarColor = rgbColor(0x777777);
    statusEmptyColor = rgbColor(0x5C5C5C);
    activeDotColor = rgbColor(0x979797);
    inactiveDotColor = rgbColor(0x3C3C3C);
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

private enum editFields = [
    "URL", "Provider", "Tags (comma-separated)", "Description"
];

/// Each row occupies three lines: name, metadata, description.
private enum rowHeight = 3;

private final class TuiModel : Model
{
    private string[] scopes;
    private size_t scopeIndex;
    private BinRow[] rows;
    private BinRow[] visible;

    private Paginator pages;
    /// Cursor position within the current page.
    private int cursor;
    private int width = 80;
    private int height = 24;

    private int busy;
    private Spinner spinner;
    private bool spinning;

    private string statusMessage;
    private ulong statusToken;

    private bool filtering;
    private bool filterApplied;
    private TextInput filterInput;

    private bool showFullHelp;

    private bool confirming;
    private string confirmTarget;
    private bool confirmYes;

    private bool editing;
    private BinRow editRow;
    private TextInput[] inputs;
    private size_t editFocus;

    // Bindings, mirroring bubbles' list keymap plus geto's own actions.
    private Binding bCursorUp = Binding(["up", "k"], "↑/k", "up");
    private Binding bCursorDown = Binding(["down", "j"], "↓/j", "down");
    private Binding bPrevPage = Binding(["left", "h", "pgup", "b"], "←/h/pgup", "prev page");
    private Binding bNextPage = Binding(["right", "l", "pgdown", "f"], "→/l/pgdn", "next page");
    private Binding bGoToStart = Binding(["home", "g"], "g/home", "go to start");
    private Binding bGoToEnd = Binding(["end", "G"], "G/end", "go to end");
    private Binding bFilter = Binding(["/"], "/", "filter");
    private Binding bClearFilter = Binding(["esc"], "esc", "clear filter");
    private Binding bAccept = Binding(["enter"], "enter", "apply filter");
    private Binding bCancel = Binding(["esc"], "esc", "cancel");
    private Binding bUpdate = Binding(["u"], "u", "update");
    private Binding bCheck = Binding(["r"], "r", "check all");
    private Binding bPin = Binding(["p"], "p", "pin");
    private Binding bEdit = Binding(["e"], "e", "edit");
    private Binding bForget = Binding(["m"], "m", "forget choice");
    private Binding bOpen = Binding(["o"], "o", "open repo");
    private Binding bRemove = Binding(["d", "x"], "d", "remove");
    private Binding bTag = Binding(["t"], "t", "tag");
    private Binding bQuit = Binding(["q"], "q", "quit");
    private Binding bShowFullHelp = Binding(["?"], "?", "more");
    private Binding bCloseFullHelp = Binding(["?"], "?", "close help");

    this()
    {
        import mochafizz.term.raw : getSize, isTerminal;

        if (isTerminal(1))
        {
            const size = getSize(1);
            if (size.width > 0 && size.height > 0)
            {
                width = size.width - 4;
                height = size.height;
            }
        }
        spinner = newSpinner(LineFrames);
        filterInput = newTextInput();
        // The prompt is drawn separately so it can be styled, as bubbles does.
        filterInput.prompt = "";
        filterInput.charLimit = 64;
        pages = newPaginator(1);
        pages.kind = pkDots;
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
        const needle = filterInput.value.strip.toLower;
        if (needle.length == 0)
            visible = rows;
        else
        {
            BinRow[] matched;
            foreach (row; rows)
                if (row.filterValue.toLower.canFind(needle))
                    matched ~= row;
            visible = matched;
        }
        updatePagination();
    }

    /// The absolute index of the cursor across all pages.
    private int index() const
    {
        return pages.page * pages.perPage + cursor;
    }

    /// Recomputes items-per-page from the space the chrome leaves over.
    private void updatePagination()
    {
        const previous = index();

        // Count the chrome exactly, so the rows fill whatever is left.
        pages.totalItems = cast(int) visible.length;

        int available = height;
        available -= 3; // app frame's two blank lines, plus one spare row so the
        // help line never lands on the very last terminal row
        available -= 2; // title bar, plus the blank line under it
        available -= 2; // status bar, plus its blank line
        available -= paginationHeight();
        available -= 1 + helpLines(); // help, preceded by a blank line

        pages.perPage = max(1, available / rowHeight);

        const total = max(pages.totalPages(), 1);
        pages.page = pages.perPage > 0 ? previous / pages.perPage : 0;
        cursor = pages.perPage > 0 ? previous % pages.perPage : 0;
        if (pages.page >= total)
            pages.page = total - 1;
        if (pages.page < 0)
            pages.page = 0;

        const onPage = pages.itemsOnPage(cast(int) visible.length);
        if (cursor >= onPage)
            cursor = max(onPage - 1, 0);
    }

    /// How many lines the help occupies.
    private int helpLines() const
    {
        // The full help is as tall as its longest column.
        return showFullHelp ? 10 : 1;
    }

    /// Empty when there is only one page, matching bubbles.
    private int paginationHeight() const
    {
        // An absent paginator still contributes the blank line the sections
        // are joined with, which is what bubbles' lipgloss.Height("") == 1 does.
        return pages.totalPages() < 2 ? 1 : 2;
    }

    private void cursorUp()
    {
        cursor--;
        if (cursor < 0 && pages.page == 0)
        {
            cursor = 0;
            return;
        }
        if (cursor >= 0)
            return;
        pages.previousPage();
        cursor = pages.itemsOnPage(cast(int) visible.length) - 1;
    }

    private void cursorDown()
    {
        const onPage = pages.itemsOnPage(cast(int) visible.length);
        cursor++;
        if (cursor < onPage)
            return;
        if (!pages.onLastPage())
        {
            pages.nextPage();
            cursor = 0;
            return;
        }
        cursor = max(onPage - 1, 0);
    }

    private BinRow selectedRow()
    {
        const at = index();
        if (at >= 0 && at < cast(int) visible.length)
            return visible[at];
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
                // The app frame costs two columns each side; its vertical cost
                // is accounted for in updatePagination.
                width = size.width - 4;
                height = size.height;
                updatePagination();
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
            foreach (ref input; inputs)
                input.update(message);
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
        if (press.key.matchString("ctrl+c"))
            return ModelUpdate(this, () => Quit());

        if (editing)
            return handleEditKey(press);
        if (confirming)
            return handleConfirmKey(press);
        if (filtering)
            return handleFilterKey(press);

        // geto's own actions are checked first, so `u` and `d` stay update and
        // remove rather than the paging keys bubbles binds them to.
        if (bQuit.matches(press))
            return ModelUpdate(this, () => Quit());
        if (bTag.matches(press))
        {
            scopeIndex = (scopeIndex + 1) % scopes.length;
            rebuildRows();
            return ModelUpdate(this, setStatus("tag: " ~ currentScope()));
        }
        if (bPin.matches(press))
        {
            auto row = selectedRow();
            if (row is null)
                return ModelUpdate(this, null);
            row.binary.pinned = !row.binary.pinned;
            upsertBinary(row.binary);
            return ModelUpdate(this, setStatus((row.binary.pinned
                    ? "pinned " : "unpinned ") ~ row.path.baseName));
        }
        if (bEdit.matches(press))
        {
            if (auto row = selectedRow())
                startEdit(row);
            return ModelUpdate(this, null);
        }
        if (bForget.matches(press))
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
        if (bOpen.matches(press))
        {
            auto row = selectedRow();
            if (row is null || row.binary.url.length == 0)
                return ModelUpdate(this, null);
            openUrl(row.binary.url);
            return ModelUpdate(this, setStatus("opening " ~ repoShort(row.binary.url)));
        }
        if (bRemove.matches(press))
        {
            if (auto row = selectedRow())
            {
                confirming = true;
                confirmTarget = row.path;
                confirmYes = false;
            }
            return ModelUpdate(this, null);
        }
        if (bCheck.matches(press))
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
        if (bUpdate.matches(press))
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

        // Everything else is list navigation.
        if (bShowFullHelp.matches(press))
        {
            showFullHelp = !showFullHelp;
            updatePagination();
            return ModelUpdate(this, null);
        }
        if (bFilter.matches(press))
        {
            filtering = true;
            filterInput.clear();
            filterInput.focused = true;
            applyFilter();
            return ModelUpdate(this, null);
        }
        if (filterApplied && bClearFilter.matches(press))
        {
            filterApplied = false;
            filterInput.clear();
            applyFilter();
            return ModelUpdate(this, null);
        }
        if (bCursorUp.matches(press))
        {
            cursorUp();
            return ModelUpdate(this, null);
        }
        if (bCursorDown.matches(press))
        {
            cursorDown();
            return ModelUpdate(this, null);
        }
        if (bPrevPage.matches(press))
        {
            pages.previousPage();
            clampCursorToPage();
            return ModelUpdate(this, null);
        }
        if (bNextPage.matches(press))
        {
            pages.nextPage();
            clampCursorToPage();
            return ModelUpdate(this, null);
        }
        if (bGoToStart.matches(press))
        {
            pages.page = 0;
            cursor = 0;
            return ModelUpdate(this, null);
        }
        if (bGoToEnd.matches(press))
        {
            pages.page = max(pages.totalPages() - 1, 0);
            cursor = max(pages.itemsOnPage(cast(int) visible.length) - 1, 0);
            return ModelUpdate(this, null);
        }
        return ModelUpdate(this, null);
    }

    private void clampCursorToPage()
    {
        const onPage = pages.itemsOnPage(cast(int) visible.length);
        if (cursor >= onPage)
            cursor = max(onPage - 1, 0);
    }

    private ModelUpdate handleFilterKey(KeyPressMsg press)
    {
        if (bCancel.matches(press))
        {
            filtering = false;
            filterApplied = false;
            filterInput.clear();
            applyFilter();
            return ModelUpdate(this, null);
        }
        if (bAccept.matches(press))
        {
            filtering = false;
            filterApplied = filterInput.value.strip.length > 0;
            applyFilter();
            return ModelUpdate(this, null);
        }
        filterInput.update(press);
        applyFilter();
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
        auto base = frame(renderApp());
        string content = base;
        if (editing)
            content = overlay(dim(base), editDialog());
        else if (confirming)
            content = overlay(dim(base), confirmDialog());

        auto result = newView(content);
        result.altScreen = true;
        return result;
    }

    /// The app frame: one blank line above and below, two columns each side.
    private static string frame(string content)
    {
        auto output = appender!string;
        output ~= "\n";
        foreach (line; content.split("\n"))
            output ~= "  " ~ line ~ "\n";
        return output.data;
    }

    /// Sections in bubbles' order: title, status bar, items, paginator, help.
    private string renderApp()
    {
        auto output = appender!string;
        output ~= titleView() ~ "\n";
        output ~= statusView() ~ "\n";
        output ~= itemsView() ~ "\n";
        output ~= paginationView() ~ "\n";
        output ~= helpView();
        return output.data;
    }

    /// Title chip and status message, with the spinner parked on the right.
    /// While filtering the filter input takes the title's place.
    private string titleView()
    {
        string line;
        if (filtering)
            line = newStyle().foreground(colorOk).render("Filter: ") ~ filterInput.view();
        else
        {
            line = titleStyle.render("geto · " ~ currentScope());
            if (statusMessage.length > 0)
                line ~= "  " ~ statusMessage;
            line = clip(line, max(width - 2, 1));
        }

        if (spinning)
        {
            const spare = width - line.stringWidth() - 1;
            if (spare > 0)
                line ~= " ".replicate(spare) ~ mutedStyle.render(spinner.view());
        }
        // Padding(0, 0, 1, 2): two columns in, one blank line under.
        return "  " ~ line ~ "\n";
    }

    /// Item count, plus the active filter and how many rows it hides.
    private string statusView()
    {
        string status;
        const shown = visible.length;
        const noun = shown == 1 ? "binary" : "binaries";
        const counted = format("%d %s", shown, noun);

        if (filtering)
            status = shown == 0 ? newStyle().foreground(statusEmptyColor)
                .render("Nothing matched") : counted;
        else if (rows.length == 0)
            status = newStyle().foreground(statusEmptyColor).render("No binaries");
        else
        {
            if (filterApplied)
                status ~= "“" ~ clip(filterInput.value.strip, 10) ~ "” ";
            status ~= counted;
        }

        const hidden = rows.length - shown;
        if (hidden > 0)
            status ~= newStyle().foreground(inactiveDotColor).render(" • ") ~ newStyle()
                .foreground(inactiveDotColor).render(format("%d filtered", hidden));

        return "  " ~ newStyle().foreground(statusBarColor).render(status) ~ "\n";
    }

    /// The current page's rows, padded so the chrome below never shifts.
    private string itemsView()
    {
        if (visible.length == 0)
        {
            const message = filtering ? "" : newStyle().foreground(helpKeyColor)
                .render("No binaries.");
            auto filler = appender!string;
            filler ~= "  " ~ message;
            foreach (_; 0 .. pages.perPage * rowHeight - 1)
                filler ~= "\n";
            return filler.data;
        }

        const bounds = pages.sliceBounds(cast(int) visible.length);
        auto output = appender!string;
        foreach (i; bounds.lo .. bounds.hi)
        {
            output ~= renderRow(i);
            if (i + 1 < bounds.hi)
                output ~= "\n";
        }

        const onPage = pages.itemsOnPage(cast(int) visible.length);
        if (onPage < pages.perPage)
            foreach (_; 0 .. (pages.perPage - onPage) * rowHeight)
                output ~= "\n";
        return output.data;
    }

    /// Dots, one per page, hidden when everything fits on one page.
    private string paginationView()
    {
        if (pages.totalPages() < 2)
            return "";
        string dots;
        foreach (page; 0 .. pages.totalPages())
            dots ~= page == pages.page ? newStyle().foreground(activeDotColor)
                .render("•") : newStyle().foreground(inactiveDotColor).render("•");
        // MarginTop(1) plus PaddingLeft(2).
        return "\n  " ~ dots;
    }

    private string helpView()
    {
        return "\n  " ~ (showFullHelp ? fullHelpView() : shortHelpView());
    }

    /// One line of `key desc` pairs joined by dots, clipped to the width.
    private string shortHelpView()
    {
        Binding[] bindings = [bCursorUp, bCursorDown];
        if (filtering)
        {
            bindings ~= bCancel;
            if (filterInput.value.strip.length > 0)
                bindings ~= bAccept;
        }
        else
        {
            if (rows.length > 0)
                bindings ~= bFilter;
            if (filterApplied)
                bindings ~= bClearFilter;
            bindings ~= [
                bUpdate, bCheck, bPin, bEdit, bForget, bOpen, bRemove, bTag, bQuit,
                bShowFullHelp
            ];
        }

        const separator = newStyle().foreground(helpSepColor).render(" • ");
        auto output = appender!string;
        int used;
        foreach (i, binding; bindings)
        {
            const piece = (used > 0 ? separator : "") ~ newStyle().foreground(helpKeyColor)
                .render(binding.helpKey) ~ " " ~ newStyle()
                .foreground(helpDescColor).render(binding.helpDesc);
            const pieceWidth = piece.stringWidth();
            if (used + pieceWidth > width)
            {
                const tail = " " ~ newStyle().foreground(helpSepColor).render("…");
                if (used + tail.stringWidth() < width)
                    output ~= tail;
                break;
            }
            used += pieceWidth;
            output ~= piece;
        }
        return output.data;
    }

    /// Columns of bindings, laid out like bubbles' full help.
    private string fullHelpView()
    {
        import mochafizz.uv.layout : joinHorizontal;

        Binding[] listLevel = [bFilter];
        // Clearing a filter is only offered once one is applied, as bubbles does.
        if (filterApplied)
            listLevel ~= bClearFilter;
        listLevel ~= [
            bUpdate, bCheck, bPin, bEdit, bForget, bOpen, bRemove, bTag
        ];

        Binding[][] groups = [
            [bCursorUp, bCursorDown, bNextPage, bPrevPage, bGoToStart, bGoToEnd],
            listLevel, [bQuit, bCloseFullHelp],
        ];

        string[] columns;
        foreach (group; groups)
        {
            string[] keys, descriptions;
            foreach (binding; group)
            {
                keys ~= newStyle().foreground(helpKeyColor).render(binding.helpKey);
                descriptions ~= newStyle().foreground(helpDescColor).render(binding.helpDesc);
            }
            columns ~= joinHorizontal(keys.join("\n"), " ", descriptions.join("\n"));
        }

        string rendered;
        foreach (i, column; columns)
            rendered = i == 0 ? column : joinHorizontal(rendered, "    ", column);
        // Indent the continuation lines to match the two-column padding.
        return rendered.split("\n").join("\n  ");
    }

    /// Renders one three-line row: name, metadata, description.
    private string renderRow(int position)
    {
        auto row = visible[position];
        const selected = position == index();

        // Alternating shades; the selected row sits closest to the accent.
        auto rowBackground = rowBg;
        if (selected)
            rowBackground = rowBgSelected;
        else if (position % 2 == 1)
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
