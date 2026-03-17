{
  description = "realtime-check — Supabase Realtime end-to-end test CLI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      let
        src = pkgs.lib.cleanSourceWith {
          src = ./.;
          filter = path: type:
            let baseName = baseNameOf path;
            in baseName != "node_modules" && baseName != "result" && baseName != "realtime-check";
        };

        node_modules = pkgs.stdenv.mkDerivation {
          name = "realtime-check-node-modules";
          inherit src;
          nativeBuildInputs = [ pkgs.bun ];
          buildPhase = ''
            export HOME=$TMPDIR
            bun install --frozen-lockfile
          '';
          installPhase = "cp -r node_modules $out";
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash = "sha256-I7ZNZkyK83Lk+Ut3j6FngvWNfIl8JaW2cF4bfyVf5TQ=";
        };
      in {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "realtime-check";
          version = "0.0.1";
          inherit src;
          nativeBuildInputs = [ pkgs.bun ];
          buildPhase = ''
            export HOME=$TMPDIR
            cp -r ${node_modules} node_modules
            chmod -R u+w node_modules
            bun build --compile --minify-syntax --minify-whitespace --minify-identifiers realtime-check.ts --outfile realtime-check
          '';
          installPhase = ''
            install -Dm755 realtime-check $out/bin/realtime-check
          '';
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [ pkgs.bun ];
        };
      }
    );
}
