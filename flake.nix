{
  description = "artbip — great public-domain paintings on the macOS desktop";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # A pure-Nix build isn't practical: the package needs a Swift 6.1
      # toolchain, which nixpkgs does not ship for darwin. Build with the
      # system toolchain instead (from a checkout):
      #
      #   nix run .#build        # wraps scripts/make_app.sh
      #   cp -R dist/artbip.app /Applications/
      apps = forAll (pkgs: {
        build = {
          type = "app";
          program = toString (pkgs.writeShellScript "artbip-build" ''
            if [ ! -x scripts/make_app.sh ]; then
              echo "run from an artbip checkout (scripts/make_app.sh not found)" >&2
              exit 1
            fi
            exec bash scripts/make_app.sh
          '');
        };
      });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          # Swift comes from the system toolchain; this is just pipeline tooling.
          packages = [ pkgs.python3 ];
        };
      });

      # nix-darwin module: a launchd user agent running the CLI rotation
      # daemon from the installed app bundle. Use this OR the app's own
      # timer + launch-at-login — not both.
      darwinModules.default = { config, lib, ... }:
        let
          cfg = config.services.artbip;
        in
        {
          options.services.artbip = {
            enable = lib.mkEnableOption "artbip wallpaper rotation daemon";
            appPath = lib.mkOption {
              type = lib.types.str;
              default = "/Applications/artbip.app";
              description = "Installed artbip.app (built by scripts/make_app.sh).";
            };
            intervalMinutes = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              description = "Rotation interval override; null uses settings.json (default 60).";
            };
          };

          config = lib.mkIf cfg.enable {
            launchd.user.agents.artbip-rotate = {
              serviceConfig = {
                ProgramArguments =
                  [ "${cfg.appPath}/Contents/MacOS/artbip" "rotate" "daemon" ]
                  ++ lib.optionals (cfg.intervalMinutes != null)
                    [ "--interval" (toString cfg.intervalMinutes) ];
                RunAtLoad = true;
                KeepAlive = true;
                ProcessType = "Background";
                StandardErrorPath = "/tmp/artbip-rotate.log";
              };
            };
          };
        };
    };
}
