module geto.ui.select;

import std.array : appender;
import std.conv : ConvException, to;
import std.format : format;
import std.stdio : readln, stdout, write, writeln;
import std.string : strip, toLower;

import mochafizz.style : bold, foreground, newStyle, render;
import mochafizz.tea.cmd : Cmd, Quit;
import mochafizz.tea.msg : KeyPressMsg, Msg;
import mochafizz.tea.program : Model, ModelUpdate, newProgram;
import mochafizz.tea.view : View, newView;
import mochafizz.term.raw : isTerminal;
import mochafizz.bubbles.textinput : TextInput, newTextInput, setValue, update,
    value, view;
import mochafizz.uv.key : keyToString = toString, matchString;

import geto.ui.styles : accentStyle, colorMuted, colorPrimary, colorText,
    errStyle, mutedStyle, okStyle;

/// Raised when the user aborts a prompt.
class CancelledException : Exception
{
    this(string message = "selection cancelled", string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
    }
}

/// True when both stdin and stdout are attached to a terminal.
bool interactive()
{
    return isTerminal(0) && isTerminal(1);
}

private enum selectWindow = 6;

// ---------------------------------------------------------------------------
// Single choice
// ---------------------------------------------------------------------------

private final class SelectModel : Model
{
    string title;
    string[] items;
    int cursor;
    int top;
    int chosen = -1;

    this(string title, string[] items)
    {
        this.title = title;
        this.items = items;
    }

    private void clampWindow()
    {
        if (cursor < top)
            top = cursor;
        if (cursor >= top + selectWindow)
            top = cursor - selectWindow + 1;
        if (top < 0)
            top = 0;
    }

    override ModelUpdate update(Msg message)
    {
        auto press = cast(KeyPressMsg) message;
        if (press is null)
            return ModelUpdate(this, null);

        const key = press.key;
        if (key.matchString("ctrl+c", "esc", "q"))
            return ModelUpdate(this, () => Quit());
        if (key.matchString("up", "k"))
        {
            if (cursor > 0)
                cursor--;
        }
        else if (key.matchString("down", "j"))
        {
            if (cursor < cast(int) items.length - 1)
                cursor++;
        }
        else if (key.matchString("pgup", "ctrl+u"))
        {
            cursor -= selectWindow;
            if (cursor < 0)
                cursor = 0;
        }
        else if (key.matchString("pgdown", "ctrl+d"))
        {
            cursor += selectWindow;
            if (cursor > cast(int) items.length - 1)
                cursor = cast(int) items.length - 1;
        }
        else if (key.matchString("home", "g"))
            cursor = 0;
        else if (key.matchString("end", "G"))
            cursor = cast(int) items.length - 1;
        else if (key.matchString("enter", " "))
        {
            chosen = cursor;
            return ModelUpdate(this, () => Quit());
        }
        else
        {
            const text = key.keyToString();
            if (text.length == 1 && text[0] >= '1' && text[0] <= '9')
            {
                const index = text[0] - '1';
                if (index < items.length)
                {
                    chosen = index;
                    return ModelUpdate(this, () => Quit());
                }
            }
        }
        clampWindow();
        return ModelUpdate(this, null);
    }

    override View view()
    {
        if (chosen >= 0)
            return newView("  " ~ okStyle.render("✓ ") ~ items[chosen] ~ "\n");

        auto output = appender!string;
        output ~= accentStyle.render(title) ~ "\n";

        auto end = top + selectWindow;
        if (end > cast(int) items.length)
            end = cast(int) items.length;
        if (top > 0)
            output ~= mutedStyle.render(format("  ↑ %d more", top)) ~ "\n";
        foreach (i; top .. end)
        {
            if (i == cursor)
                output ~= accentStyle.render("▸ ")
                    ~ newStyle().foreground(colorText).bold().render(items[i]) ~ "\n";
            else
                output ~= "  " ~ mutedStyle.render(items[i]) ~ "\n";
        }
        if (end < cast(int) items.length)
            output ~= mutedStyle.render(format("  ↓ %d more", items.length - end)) ~ "\n";
        output ~= mutedStyle.render(format("[%d/%d] ↑/↓ move · enter select · esc cancel",
                cursor + 1, items.length));
        return newView(output.data);
    }
}

/// Shows a single-choice picker and returns the chosen index.
int selectOne(string title, string[] items)
{
    if (items.length == 0)
        throw new CancelledException("no options to choose from");
    if (!interactive())
        return selectFallback(title, items);

    auto model = new SelectModel(title, items);
    newProgram(model).run();
    if (model.chosen < 0)
        throw new CancelledException();
    return model.chosen;
}

private int selectFallback(string title, string[] items)
{
    writeln("\n", title);
    foreach (i, item; items)
        writeln(format("  [%d] %s", i + 1, item));
    write("Select an option: ");
    stdout.flush();

    const line = readln();
    if (line is null)
        throw new CancelledException("no input");
    int choice;
    try
        choice = line.strip.to!int;
    catch (ConvException)
        throw new CancelledException("invalid option");
    if (choice < 1 || choice > cast(int) items.length)
        throw new CancelledException("invalid option");
    return choice - 1;
}

// ---------------------------------------------------------------------------
// Choice or free text
// ---------------------------------------------------------------------------

private final class PickModel : Model
{
    string title;
    string[] items;
    int cursor;
    TextInput input;
    string result;
    bool done;

    this(string title, string[] items)
    {
        this.title = title;
        this.items = items;
        input = newTextInput();
        input.prompt = "";
        input.placeholder = "custom value…";
    }

    override ModelUpdate update(Msg message)
    {
        auto press = cast(KeyPressMsg) message;
        if (press is null)
        {
            input.update(message);
            return ModelUpdate(this, null);
        }

        const key = press.key;
        if (key.matchString("ctrl+c", "esc"))
            return ModelUpdate(this, () => Quit());
        if (key.matchString("up"))
        {
            if (cursor > 0)
                cursor--;
            return ModelUpdate(this, null);
        }
        if (key.matchString("down"))
        {
            if (cursor < cast(int) items.length - 1)
                cursor++;
            return ModelUpdate(this, null);
        }
        if (key.matchString("enter"))
        {
            const typed = input.value.strip;
            if (typed.length > 0)
                result = typed;
            else if (items.length > 0)
                result = items[cursor];
            done = true;
            return ModelUpdate(this, () => Quit());
        }
        input.update(message);
        return ModelUpdate(this, null);
    }

    override View view()
    {
        if (done)
            return newView("  " ~ okStyle.render("✓ ") ~ result ~ "\n");

        auto output = appender!string;
        output ~= accentStyle.render(title) ~ "\n";
        const typing = input.value.strip.length > 0;
        foreach (i, item; items)
        {
            if (i == cursor && !typing)
                output ~= accentStyle.render("▸ ")
                    ~ newStyle().foreground(colorText).bold().render(item) ~ "\n";
            else
                output ~= "  " ~ mutedStyle.render(item) ~ "\n";
        }
        output ~= newStyle().foreground(colorMuted).render("› ") ~ input.view() ~ "\n";
        output ~= mutedStyle.render("↑/↓ pick · type a custom value · enter confirm · esc cancel");
        return newView(output.data);
    }
}

/// Prompts for a listed choice or a typed value.
string selectOrInput(string title, string[] items)
{
    if (!interactive())
        return items[selectFallback(title, items)];

    auto model = new PickModel(title, items);
    newProgram(model).run();
    if (!model.done || model.result.length == 0)
        throw new CancelledException();
    return model.result;
}

// ---------------------------------------------------------------------------
// Free text
// ---------------------------------------------------------------------------

private final class AskModel : Model
{
    string prompt;
    TextInput input;
    bool done;
    bool cancelled;

    this(string prompt, string preset)
    {
        this.prompt = prompt;
        input = newTextInput();
        input.prompt = "";
        input.setValue(preset);
    }

    override ModelUpdate update(Msg message)
    {
        if (auto press = cast(KeyPressMsg) message)
        {
            const key = press.key;
            if (key.matchString("enter"))
            {
                done = true;
                return ModelUpdate(this, () => Quit());
            }
            if (key.matchString("ctrl+c", "esc"))
            {
                cancelled = true;
                return ModelUpdate(this, () => Quit());
            }
        }
        input.update(message);
        return ModelUpdate(this, null);
    }

    override View view()
    {
        if (done)
            return newView("  " ~ okStyle.render("✓ ") ~ input.value ~ "\n");
        return newView(accentStyle.render(prompt) ~ " " ~ input.view() ~ "\n"
                ~ mutedStyle.render("enter to confirm · esc to cancel"));
    }
}

/// Prompts for a line of text pre-filled with `preset`.
string askString(string prompt, string preset)
{
    if (!interactive())
        return preset;

    auto model = new AskModel(prompt, preset);
    newProgram(model).run();
    if (model.cancelled)
        throw new CancelledException("cancelled");
    const typed = model.input.value.strip;
    return typed.length > 0 ? typed : preset;
}

// ---------------------------------------------------------------------------
// Confirmation
// ---------------------------------------------------------------------------

private final class ConfirmModel : Model
{
    string question;
    bool yes;
    bool answered;
    bool result;

    this(string question, bool preset)
    {
        this.question = question;
        yes = preset;
    }

    override ModelUpdate update(Msg message)
    {
        auto press = cast(KeyPressMsg) message;
        if (press is null)
            return ModelUpdate(this, null);

        const key = press.key;
        if (key.matchString("ctrl+c", "esc"))
        {
            answered = true;
            result = false;
            return ModelUpdate(this, () => Quit());
        }
        if (key.matchString("left", "h", "right", "l", "tab"))
            yes = !yes;
        else if (key.matchString("y", "Y"))
        {
            answered = true;
            result = true;
            return ModelUpdate(this, () => Quit());
        }
        else if (key.matchString("n", "N"))
        {
            answered = true;
            result = false;
            return ModelUpdate(this, () => Quit());
        }
        else if (key.matchString("enter"))
        {
            answered = true;
            result = yes;
            return ModelUpdate(this, () => Quit());
        }
        return ModelUpdate(this, null);
    }

    override View view()
    {
        import mochafizz.style : background, padding;

        if (answered)
            return newView(result
                    ? "  " ~ okStyle.render("✓ yes") ~ "\n"
                    : "  " ~ errStyle.render("✗ no") ~ "\n");

        auto selected = newStyle().foreground(colorText).background(colorPrimary)
            .bold().padding(0, 2);
        auto plain = newStyle().foreground(colorMuted).padding(0, 2);
        const yesButton = yes ? selected.render("Yes") : plain.render("Yes");
        const noButton = yes ? plain.render("No") : selected.render("No");
        return newView(accentStyle.render(question) ~ "\n"
                ~ yesButton ~ "  " ~ noButton ~ "\n"
                ~ mutedStyle.render("←/→ toggle · y/n · enter"));
    }
}

/// Prompts for a yes/no decision.
bool confirm(string question, bool preset)
{
    if (!interactive())
    {
        write(format("\n%s [%s] ", question, preset ? "Y/n" : "y/N"));
        stdout.flush();
        const line = readln();
        if (line is null)
            return preset;
        switch (line.strip.toLower)
        {
        case "y":
        case "yes":
            return true;
        case "n":
        case "no":
            return false;
        default:
            return preset;
        }
    }

    auto model = new ConfirmModel(question, preset);
    newProgram(model).run();
    return model.result;
}

/// Asks for confirmation, throwing when the user declines.
void confirmOrAbort(string message)
{
    if (!confirm(message, true))
        throw new CancelledException("command aborted");
}
