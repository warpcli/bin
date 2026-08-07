{ self ? null }:
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.geto;
  defaultPackage =
    if self != null
    then self.packages.${pkgs.system}.default
    else pkgs.geto;

  repoName = repo:
    lib.removeSuffix ".git" (baseNameOf (lib.removeSuffix "/" repo));

  entrySpec = lib.types.submodule {
    options = {
      repo = lib.mkOption {
        type = lib.types.str;
        description = "Repository or provider URL understood by geto.";
        example = "github.com/atuinsh/atuin";
      };
      name = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Installed binary name. Defaults to the repository basename.";
      };
      tag = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Single geto tag/tier for this binary.";
        example = "essential";
      };
      tags = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Geto tags/tiers for this binary. Overrides tag when non-empty.";
      };
      path = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Absolute installation path. Defaults to installDir/name.";
      };
      provider = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Provider override.";
      };
      description = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional description stored in the geto manifest.";
      };
      patch = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether geto should patch ELF interpreter/RUNPATH for this host.";
      };
    };
  };

  attrSpec = lib.types.submodule ({ name, ... }: {
    options = (entrySpec.getSubOptions [ ]) // {
      repo = lib.mkOption {
        type = lib.types.str;
        description = "Repository or provider URL understood by geto.";
      };
      name = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = name;
        description = "Installed binary name. Defaults to the attribute name.";
      };
    };
  });

  normalizeEntry = entry:
    let
      e =
        if builtins.isString entry
        then { repo = entry; name = null; tag = null; tags = [ ]; path = null; provider = null; description = null; patch = true; }
        else entry;
      name = if e.name == null then repoName e.repo else e.name;
      tags =
        if e.tags != [ ]
        then e.tags
        else if e.tag != null
        then [ e.tag ]
        else [ "default" ];
      path = if e.path == null then "${cfg.installDir}/${name}" else e.path;
      manifest = lib.filterAttrs (_: v: v != null) {
        inherit path tags;
        url = e.repo;
        provider = e.provider;
        description = e.description;
        patch = e.patch;
      };
    in
    {
      inherit name path manifest;
    };

  attrEntries = lib.mapAttrsToList (_: spec: spec) cfg.binaries;
  normalizedEntries = map normalizeEntry (cfg.entries ++ attrEntries);
  manifestBins = builtins.listToAttrs (map (e: { name = e.path; value = e.manifest; }) normalizedEntries);
  manifest = pkgs.writeText "geto-list.json" (builtins.toJSON {
    default_path = cfg.installDir;
    bins = manifestBins;
  });

  managedPath = pkgs.runCommand "geto-managed-path" { } ''
    mkdir -p "$out/bin"
    ${lib.concatMapStringsSep "\n" (e: ''
      ln -s ${lib.escapeShellArg e.path} "$out/bin/${e.name}"
    '') normalizedEntries}
  '';
in
{
  options.programs.geto = {
    enable = lib.mkEnableOption "geto declarative binary manager";
    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      defaultText = lib.literalExpression "inputs.geto.packages.\${pkgs.system}.default";
      description = "geto package to run.";
    };
    installDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.local/bin";
      description = "Directory where managed binaries are installed.";
    };
    configFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.configHome}/geto/list.json";
      description = "Generated geto manifest path for this Home Manager instance.";
    };
    stateFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.local/state/geto/config.state.json";
      description = "Mutable geto state path for versions, hashes, and selected assets.";
    };
    addToPath = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Add wrappers for managed binaries to home.packages.";
    };
    entries = lib.mkOption {
      type = lib.types.listOf (lib.types.either lib.types.str entrySpec);
      default = [ ];
      description = "List of repositories or binary entries. Nix turns this into geto's list.json; geto ensure fills state.";
      example = lib.literalExpression ''
        [
          "github.com/rust-lang/mdBook"
          { repo = "github.com/git-town/git-town"; tag = "essential"; }
        ]
      '';
    };
    binaries = lib.mkOption {
      type = lib.types.attrsOf attrSpec;
      default = { };
      description = "Attribute-set form of entries, keyed by installed binary name.";
      example = lib.literalExpression ''
        {
          mdbook.repo = "github.com/rust-lang/mdBook";
          git-town = { repo = "github.com/git-town/git-town"; tag = "essential"; };
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ] ++ lib.optional cfg.addToPath managedPath;

    home.activation.getoEnsure = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${pkgs.coreutils}/bin/install -D -m 0644 ${manifest} ${lib.escapeShellArg cfg.configFile}
      run ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg cfg.installDir} ${lib.escapeShellArg (dirOf cfg.stateFile)}
      run env \
        GETO_CONFIG_FILE=${lib.escapeShellArg cfg.configFile} \
        GETO_STATE_FILE=${lib.escapeShellArg cfg.stateFile} \
        GETO_DEFAULT_PATH=${lib.escapeShellArg cfg.installDir} \
        GETO_NONINTERACTIVE=1 \
        ${cfg.package}/bin/geto --tag all ensure
    '';
  };
}
