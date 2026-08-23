{
  description = "geto binary manager";

  inputs = {
    # Pinned to a rev that still accepts the `kernel` arg in
    # nvidia-x11/generic.nix. Newer nixpkgs (post 2026-04) dropped
    # that arg, which breaks nixGL until upstream catches up. Bump
    # together with nixgl when its corresponding fix lands.
    nixpkgs.url = "github:NixOS/nixpkgs?rev=4c1018dae018162ec878d42fec712642d214fdfa";
    flake-utils.url = "github:numtide/flake-utils";
    nixgl.url = "github:nix-community/nixGL";
  };

  outputs =
    { self, nixpkgs, flake-utils, nixgl, ... }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        overlays = [
          (final: prev: {
            xorg = prev.xorg // {
              libX11 = final.libx11;
              libxcb = final.libxcb;
              libxshmfence = final.libxshmfence;
            };
          })
        ];

        pkgs = import nixpkgs {
          inherit system overlays;
          config = {
            allowUnfree = true;
            nvidia.acceptLicense = true;
          };
        };

        nvidiaVersion = builtins.getEnv "NVIDIA_VERSION";
        hasNvidia = nvidiaVersion != "";

        nixglPkgs = import "${nixgl}/default.nix" ({
          inherit pkgs;
        } // pkgs.lib.optionalAttrs hasNvidia {
          inherit nvidiaVersion;
          nvidiaHash = null;
        });

        nixGLTarget =
          if hasNvidia
          then "${nixglPkgs.nixGLNvidia}/bin/nixGLNvidia-${nvidiaVersion}"
          else "${nixglPkgs.nixGLIntel}/bin/nixGLIntel";
        nixVulkanTarget =
          if hasNvidia
          then "${nixglPkgs.nixVulkanNvidia}/bin/nixVulkanNvidia-${nvidiaVersion}"
          else "${nixglPkgs.nixVulkanIntel}/bin/nixVulkanIntel";

        nixGLAlias = pkgs.runCommand "nixGL" { } ''
          mkdir -p $out/bin
          ln -s ${nixGLTarget} $out/bin/nixGL
        '';
        nixVulkanAlias = pkgs.runCommand "nixVulkan" { } ''
          mkdir -p $out/bin
          ln -s ${nixVulkanTarget} $out/bin/nixVulkan
        '';

        guiLibs = with pkgs; [
          alsa-lib
          udev
          vulkan-loader
          libxkbcommon
          wayland
          libx11
          libxcursor
          libxi
          libxrandr
        ];
        getoPackage = pkgs.callPackage ./nix/package.nix { };
      in
      {
        packages.default = getoPackage;
        packages.geto = getoPackage;

        apps.default = flake-utils.lib.mkApp {
          drv = getoPackage;
          exePath = "/bin/geto";
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.ldc
            pkgs.dub
            pkgs.dtools
            pkgs.dscanner
            pkgs.serve-d
            pkgs.dub-to-nix
            pkgs.git-cliff
            pkgs.clang
            pkgs.mold
            pkgs.pkg-config
            pkgs.openssl
            pkgs.xz
            pkgs.bzip2
            pkgs.zstd
            pkgs.zlib

            nixGLAlias
            nixVulkanAlias
            nixglPkgs.nixGLIntel
            nixglPkgs.nixVulkanIntel
          ] ++ pkgs.lib.optionals hasNvidia [
            nixglPkgs.nixGLNvidia
            nixglPkgs.nixVulkanNvidia
          ] ++ guiLibs;

          # `requests` dlopens libssl/libcrypto, and squiz-box links the
          # compression libraries, so both must be on the loader path.
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (guiLibs ++ [
            pkgs.openssl
            pkgs.xz
            pkgs.bzip2
            pkgs.zstd
            pkgs.zlib
          ]);
          WGPU_VALIDATION = "0";
          WGPU_DEBUG = "0";
        };
      }
    )
    // {
      overlays.default = final: prev: {
        geto = final.callPackage ./nix/package.nix { };
      };

      nixosModules.default = import ./nix/nixos-module.nix { inherit self; };
      homeManagerModules.default = import ./nix/home-manager-module.nix { inherit self; };
    };
}
