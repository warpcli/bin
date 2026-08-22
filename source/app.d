module app;

void main(string[] args)
{
    import std.stdio : writeln;
    import geto.http : getOrThrow;

    auto response = getOrThrow("https://api.github.com/repos/sharkdp/bat/releases/latest");
    writeln("status=", response.status, " bytes=", response.content.length);
    writeln(response.text[0 .. 120]);
}
