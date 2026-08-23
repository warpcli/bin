-- geto's directory environment. Loaded when you `cd` here, unloaded when you leave.
--
-- Inert until `direnv allow`, and allowing it hashes the *contents* — so editing this file revokes
-- the allowance and you will be asked again.

-- The flake's dev shell: LDC and dub, the formatter, and the C libraries geto links against. The
-- slow line here; everything below is instant.
oslo.direnv.nix_develop()

-- The binary this repository builds, ahead of anything installed, so `geto` is the one from this
-- checkout rather than the one in ~/.local/bin. Idempotent, so a reload does not grow $PATH.
oslo.direnv.path_add("./")

-- Where the checkout is, for scripts that need to find their way back to the top.
oslo.env.set("TOP_HEAD", oslo.sys.pwd())

-- A token in the environment is a token in every child process. `nix` and `gh` both read this one,
-- and geto would quietly use it for every API call made from in here.
oslo.env.unset("GITHUB_TOKEN")

-- geto's own state, pointed at the checkout rather than at the real one. A test run installs into
-- target/bin and writes its manifest there, so trying something out cannot rewrite the list of
-- binaries this machine actually depends on.
oslo.env.set("GETO_CONFIG_HOME", oslo.sys.pwd() .. "/target")
oslo.env.set("GETO_STATE_HOME", oslo.sys.pwd() .. "/target")
oslo.env.set("GETO_DEFAULT_PATH", oslo.sys.pwd() .. "/target/bin")

-- The commands this repository is driven by. All unload with the directory, so they cannot fire
-- the wrong project's build.
oslo.env.set_alias("_b", "make build")
oslo.env.set_alias("_c", "make compile")
oslo.env.set_alias("_r", "make run")
oslo.env.set_alias("_t", "make test")
oslo.env.set_alias("_v", "make verify")
oslo.env.set_alias("_i", "make install")
