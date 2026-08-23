module app;

import core.stdc.stdlib : exit;

import geto.cmd.root : run;

/// Overridden at build time via `-version=...`; kept simple for local builds.
enum buildVersion = "0.4.0-d";

void main(string[] args)
{
    exit(run(buildVersion, args[1 .. $]));
}
