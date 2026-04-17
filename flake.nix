{
  description = "pg_timers – precise timer scheduling for PostgreSQL";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;

        pgVersions = {
          pg15 = pkgs.postgresql_15;
          pg16 = pkgs.postgresql_16;
          pg17 = pkgs.postgresql_17;
          pg18 = pkgs.postgresql_18;
        };

        defaultPg = pgVersions.pg18;

        # Extract version string from the control file
        extVersion =
          let
            lines = lib.splitString "\n" (builtins.readFile ./pg_timers.control);
            versionLine = lib.findFirst (lib.hasPrefix "default_version") null lines;
            m = if versionLine != null
              then builtins.match "default_version = '([^']+)'.*" versionLine
              else null;
          in
          if m != null then builtins.head m else "0.0.0";

        # Build a pg_config wrapper from nix-support metadata.
        # Newer nixpkgs splits PG outputs and no longer ships pg_config as a binary.
        mkPgConfig = pg:
          let
            pgDev = pg.dev;
            expectedFile = "${pgDev}/nix-support/pg_config.expected";
          in
          pkgs.writeShellScriptBin "pg_config" ''
            FILE="${expectedFile}"
            if [ $# -eq 0 ]; then
              cat "$FILE"
              exit 0
            fi
            case "$1" in
              --version) echo "PostgreSQL ${pg.version}" ;;
              --*)
                KEY=$(echo "$1" | sed 's/^--//' | tr '[:lower:]' '[:upper:]')
                VALUE=$(grep "^$KEY = " "$FILE" | sed "s/^$KEY = //")
                if [ -z "$VALUE" ]; then
                  echo "pg_config: invalid argument: $1" >&2
                  exit 1
                fi
                echo "$VALUE"
                ;;
              *) echo "pg_config: invalid argument: $1" >&2; exit 1 ;;
            esac
          '';

        # Build the extension locally — useful for fast iteration and editor tooling.
        # Runtime distribution uses Docker (Dockerfile.release / Dockerfile.cnpg).
        mkExtension = pg:
          pkgs.stdenv.mkDerivation {
            pname = "pg_timers";
            version = extVersion;
            src = lib.cleanSource ./.;
            nativeBuildInputs = [ pkgs.gnumake pkgs.pkg-config (mkPgConfig pg) ];
            buildInputs = [ pg.dev ];
            buildPhase = "make USE_PGXS=1 all";
            installPhase = ''
              mkdir -p $out/lib $out/share/postgresql/extension
              if [ -f pg_timers.so ]; then
                install -m755 pg_timers.so $out/lib/
              elif [ -f pg_timers.dylib ]; then
                install -m755 pg_timers.dylib $out/lib/
              else
                echo "installPhase: no shared library found" >&2; exit 1
              fi
              install -m644 pg_timers.control $out/share/postgresql/extension/
              install -m644 sql/pg_timers--*.sql $out/share/postgresql/extension/
            '';
          };

        # Dev shell: native toolchain for Neovim/LSP and local compilation.
        # Runtime (dev postgres, tests) is handled by Docker — see docker-compose.yml.
        mkDevShell = pg:
          pkgs.mkShell {
            buildInputs = [
              (mkPgConfig pg)
              pg.dev
              pg
              pkgs.gcc
              pkgs.gnumake
              pkgs.pkg-config
            ];
            shellHook = ''
              export USE_PGXS=1
              echo "pg_timers dev shell — $(pg_config --version)"
            '';
          };

      in
      {
        # Local extension builds — for fast iteration without Docker.
        packages = {
          extension-pg15 = mkExtension pgVersions.pg15;
          extension-pg16 = mkExtension pgVersions.pg16;
          extension-pg17 = mkExtension pgVersions.pg17;
          extension-pg18 = mkExtension pgVersions.pg18;
          default = mkExtension defaultPg;
        };

        # Dev shells — native toolchain for editor/LSP integration.
        devShells = {
          default = mkDevShell defaultPg;
          pg15 = mkDevShell pgVersions.pg15;
          pg16 = mkDevShell pgVersions.pg16;
          pg17 = mkDevShell pgVersions.pg17;
          pg18 = mkDevShell pgVersions.pg18;

          # Kubernetes testing shell (k3d + CNPG)
          k8s = pkgs.mkShell {
            buildInputs = [
              pkgs.k3d
              pkgs.kubectl
              pkgs.kubernetes-helm
            ];
            shellHook = ''
              echo "pg_timers k8s test shell — k3d $(k3d version -o json 2>/dev/null | ${pkgs.jq}/bin/jq -r .k3d), kubectl $(kubectl version --client -o json 2>/dev/null | ${pkgs.jq}/bin/jq -r .clientVersion.gitVersion)"
            '';
          };
        };
      }
    );
}
