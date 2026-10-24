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
    };
}
