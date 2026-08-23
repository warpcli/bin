module app;

import core.stdc.stdlib : exit;
import std.string : strip;

import geto.cmd.root : run;

/// Single source of truth for the release version; the Makefile and the
/// release workflow read the same file.
enum buildVersion = import("VERSION").strip;

void main(string[] args)
{
    exit(run(buildVersion, args[1 .. $]));
}
