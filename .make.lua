-- geto's build, as recipes.
--
--   make              the recipes, with what each of them says it does
--   make build        the release binary
--   make run          run it; arguments pass through
--   make test         the suite
--   make verify       the whole local gate
--   make install      the binary, into $PREFIX/bin
--
-- At an oslo prompt in this directory `make` is enough; everywhere else it is `oslo make`.

local make = oslo.make

---------------------------------------------------------------------------- what the build is

-- `dub.json` is the one place the name and the version are written down, and `release` rewrites it
-- there. `source/app.d` reads the same field at compile time, so `geto --version` cannot disagree
-- with the manifest.
local manifest = oslo.fs.read("dub.json")
local NAME = manifest:match('"name"%s*:%s*"([^"]+)"')
local VERSION = manifest:match('"version"%s*:%s*"([^"]+)"')
assert(NAME and VERSION, "dub.json is missing a name or a version")

local BIN = NAME
local PREFIX = os.getenv("PREFIX") or (os.getenv("HOME") .. "/.local")
local DC = os.getenv("DC") or "ldc2"

local SOURCES = { "source/*.d", "source/**/*.d", "dub.json" }

---------------------------------------------------------------------------- saying what was built

local function absolute(path)
  if oslo.path.is_absolute(path) then return oslo.path.normalize(path) end
  return oslo.path.normalize(oslo.path.join(oslo.fs.cwd(), path))
end

-- Whether `dir` is somewhere `$PATH` already looks.
local function on_path(dir)
  local want = absolute(dir)
  for entry in ((os.getenv("PATH") or "") .. ":"):gmatch("([^:]*):") do
    if entry ~= "" and absolute(entry) == want then return true end
  end
  return false
end

-- `2711368` → `2,711,368`.
local function grouped(n)
  local text = tostring(math.floor(n))
  local out = text:sub(-3)
  local at = #text - 3
  while at > 0 do
    out = text:sub(math.max(1, at - 2), at) .. "," .. out
    at = at - 3
  end
  return out
end

local function dim(text)
  return oslo.ui.style(text, { dim = true })
end

local function line(label, value)
  print(dim(oslo.ui.pad(label, 8)) .. value)
end

-- What the binary needs at run time. geto links the compression libraries and dlopens OpenSSL, so
-- "dynamic" is the honest answer for a normal build; `make static` is the one that owes you none.
local function linkage(path)
  local dynamic = oslo.run{ "readelf", "-d", path, capture = true }
  if not dynamic.ok then return nil end
  local names = {}
  -- readelf writes "(NEEDED)" with the parentheses; matching without them
  -- silently found nothing and every build reported itself as static.
  for lib in (dynamic.out or ""):gmatch("%(NEEDED%)%s+Shared library: %[([^%]]+)%]") do
    names[#names + 1] = lib
  end
  return names
end

-- Where the binary is, what it weighs, and whether you can run it by name. The last row is the one
-- that earns its place: a build that succeeded and a `$PATH` that does not reach it look identical
-- until you type `geto` and get the installed one instead.
local function report(path)
  local stat = oslo.fs.stat(path)
  if not stat then return end
  local dir = oslo.path.parent(absolute(path))
  local megabytes = ("%.2f MB"):format(stat.size / 1048576)

  print("")
  print(oslo.ui.title(("%s %s   %s"):format(NAME, VERSION, megabytes)))
  line("binary", path)
  line("size", megabytes .. dim("   " .. grouped(stat.size) .. " bytes"))

  local needed = linkage(path)
  if needed and #needed == 0 then
    line("linking", oslo.ui.style("✓ static", { fg = "green" }) .. dim("   no runtime dependencies"))
  elseif needed then
    line("linking", dim(#needed .. " shared libraries"))
  end

  if on_path(dir) then
    line("path", oslo.ui.style("✓ on $PATH", { fg = "green" }) .. dim("  " .. dir))
  else
    line("path", oslo.ui.style("✗ not on $PATH", { fg = "yellow" }))
    print(oslo.ui.subtitle(('         add to .env.lua:  oslo.direnv.path_add("%s")'):format(dir)))
  end
  print("")
end

---------------------------------------------------------------------------- building

-- The `Makefile` this replaced printed a banner on every target with `$(info …)`, including the
-- ones whose whole output was meant to be piped. A recipe is the honest place for it.
make.recipe{ name = "version", desc = "what this checkout calls itself",
             run = function() print(("%s v%s"):format(NAME, VERSION)) end }

-- Two recipes, because a skipped recipe prints nothing: the staleness declaration belongs to the
-- compile, and this one always runs and always answers.
make.recipe{
  name = "build",
  desc = "the release binary",
  run = function()
    make.run("_compile")
    report(BIN)
  end,
}

make.recipe{
  name = "_compile",
  desc = "compile the release binary",
  inputs = SOURCES,
  outputs = { BIN },
  stale = "content",
  -- `release` is -O3 -release -enable-inlining, plus section splitting and --gc-sections so the
  -- unreferenced code goes, and -s to drop the symbols. NATIVE=1 adds -mcpu=native, which is
  -- faster here and not portable, so releases never use it.
  run = function()
    local build = (os.getenv("NATIVE") == "1") and "release-native" or "release"
    sh.dub("build", "--compiler=" .. DC, "--build=" .. build)
  end,
}

make.alias("b", "build")

make.recipe{
  name = "clean",
  desc = "remove every build output",
  run = function()
    sh.rm("-rf", BIN, NAME .. "-test-application", "target", "*.lst")
    oslo.run{ "dub", "clean", capture = true }
  end,
}

make.recipe{ name = "compile", desc = "clean, then build", deps = { "clean", "build" } }
make.alias("c", "compile")

---------------------------------------------------------------------------- the static release

-- A fully static build needs musl static archives for OpenSSL and the compression libraries, and
-- those are only packaged for musl — so this is run inside Alpine, which is what the release
-- workflow does.
make.recipe{
  name = "static",
  desc = "the fully static release binary (needs musl static libs)",
  run = function()
    oslo.run{ "dub", "upgrade", "--missing-only", capture = true }
    sh["./scripts/patch-requests-static.sh"]()
    sh.dub("build", "--compiler=" .. DC, "--build=release", "--config=static")
    make.run("check-static")
    report(BIN)
  end,
}

make.recipe{
  name = "check-static",
  desc = "fail if the release ELF asks for a loader",
  run = function()
    -- That there *is* an ELF, before asking anything about it. An interrupted build leaves a
    -- zero-byte geto, and readelf on an empty file prints nothing — so "no INTERP, no NEEDED"
    -- came back true and the recipe reported a successful static build of nothing.
    local info = oslo.fs.stat(BIN)
    assert(info and info.size > 0, BIN .. " is missing or empty; the build did not finish")

    local segments = oslo.run{ "readelf", "-l", BIN, capture = true }
    assert(segments.ok, "readelf could not read " .. BIN)
    assert(not (segments.out or ""):find("program interpreter"),
           BIN .. " requests a dynamic loader; it is not static")
    local dynamic = oslo.run{ "readelf", "-d", BIN, capture = true }
    assert(not (dynamic.out or ""):find("NEEDED"),
           BIN .. " has NEEDED entries; it is not static")
    print("static: no INTERP, no NEEDED")
  end,
}

---------------------------------------------------------------------------- running

-- Bare words reach the binary as they are written; anything with a leading dash goes in --args,
-- because make parses a flag before the recipe ever sees it.
--
--   make run list
--   make run --args="list -t all"
--
-- The `=` is not optional there.
make.recipe{
  name = "run",
  desc = "run it: bare words pass through, flags go in --args",
  deps = { "build" },
  params = { { "--args", desc = "a quoted argument string, for arguments that start with a dash" } },
  run = function(a)
    local argv = { "./" .. BIN }
    for _, word in ipairs(a.rest or {}) do argv[#argv + 1] = word end
    if type(a.args) == "string" then
      for word in a.args:gmatch("%S+") do argv[#argv + 1] = word end
    end
    local ran = oslo.run(argv)
    os.exit(ran.status or 0)
  end,
}

make.alias("r", "run")

---------------------------------------------------------------------------- the gate

make.recipe{
  name = "test",
  desc = "the suite",
  run = function() sh.dub("test", "--compiler=" .. DC) end,
}

make.alias("t", "test")

make.recipe{
  name = "cover",
  desc = "the suite, with a coverage profile",
  run = function()
    sh.dub("test", "--compiler=" .. DC, "--build=unittest-cov")
    print("coverage written to *.lst")
  end,
}

-- dfmt comes from dub, not from the distribution: the `dfmt` some package managers ship is an
-- unrelated docstring tool.
--
-- The file list comes from `find` rather than a glob: `source/**/*.d` matches one directory level,
-- so it saw 13 of the 33 modules and everything under `ai/`, `cmd/`, `providers/` and `ui/` went
-- unformatted and unchecked.
local function each_source(action)
  local found = oslo.run{ "find", "source", "-name", "*.d", capture = true }
  assert(found.ok, "could not list the source files")
  for file in (found.out or ""):gmatch("[^\n]+") do action(file) end
end

-- Trailing whitespace differs between what dfmt writes and what a capture returns, so compare the
-- bodies with it removed rather than reporting every file as unformatted.
local function trimmed(text)
  return (text or ""):gsub("%s+$", "")
end

make.recipe{
  name = "fmt",
  desc = "format the source",
  run = function()
    each_source(function(file) sh.dub("run", "-q", "dfmt", "--", "--inplace", file) end)
  end,
}

make.recipe{
  name = "fmt-check",
  desc = "fail if anything is unformatted",
  run = function()
    local unformatted = {}
    each_source(function(file)
      local formatted = oslo.run{ "dub", "run", "-q", "dfmt", "--", file, capture = true }
      if formatted.ok and trimmed(formatted.out) ~= trimmed(oslo.fs.read(file)) then
        unformatted[#unformatted + 1] = file
      end
    end)
    assert(#unformatted == 0, "dfmt needed on: " .. table.concat(unformatted, " "))
    print("formatting ok")
  end,
}

make.recipe{
  name = "verify",
  desc = "the whole local gate",
  deps = { "fmt-check", "test", "build" },
}

make.alias("v", "verify")

---------------------------------------------------------------------------- installing

make.recipe{
  name = "install",
  desc = "put the release binary in $PREFIX/bin",
  deps = { "build" },
  run = function()
    local dest = (os.getenv("DESTDIR") or "") .. PREFIX .. "/bin"
    sh.install("-d", dest)
    sh.install("-m", "0755", BIN, dest .. "/" .. NAME)
    print(oslo.ui.style("✓ ", { fg = "green" }) .. dest .. "/" .. NAME)
    if not on_path(dest) then
      print(oslo.ui.subtitle(("  %s is not on $PATH, so `%s` still finds something else")
        :format(dest, NAME)))
    end
  end,
}

make.recipe{
  name = "uninstall",
  desc = "take it back out of $PREFIX/bin",
  run = function()
    local dest = PREFIX .. "/bin/" .. NAME
    sh.rm("-f", dest)
    print("removed " .. dest)
  end,
}

---------------------------------------------------------------------------- releasing

make.recipe{
  name = "changelog",
  desc = "regenerate CHANGELOG.md",
  run = function()
    assert(oslo.run{ "sh", "-c", "command -v git-cliff" }.ok,
           "git-cliff is not installed; install it first")
    sh.git("cliff", "-o", "CHANGELOG.md")
  end,
}

make.recipe{
  name = "release",
  desc = "cut a version: --type patch | minor | major | M.m.p",
  params = { { "--type", desc = "patch | minor | major | M.m.p" } },
  run = function(a)
    assert(oslo.run{ "sh", "-c", "command -v git-rel" }.ok,
           "git-rel is not installed; install it first")
    assert(type(a.type) == "string",
           "which release? make release --type patch|minor|major|M.m.p")
    sh.git("rel", a.type)
  end,
}
