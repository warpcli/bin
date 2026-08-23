module app;

import core.stdc.stdlib : exit;
import std.json : parseJSON;

import geto.cmd.root : run;

/// The version lives in dub.json and nowhere else. Read at compile time, so
/// there is no second copy to fall out of step with the manifest.
private string manifestVersion()
{
    return parseJSON(import("dub.json"))["version"].str;
}

enum buildVersion = manifestVersion();

void main(string[] args)
{
    exit(run(buildVersion, args[1 .. $]));
}
