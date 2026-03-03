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

        pgVersions = {
          pg15 = pkgs.postgresql_15;
          pg16 = pkgs.postgresql_16;
          pg17 = pkgs.postgresql_17;
          pg18 = pkgs.postgresql_18;
        };

        defaultPg = pgVersions.pg18;

        # Build a pg_config wrapper from nix-support metadata.
        # Newer nixpkgs splits PG outputs and no longer ships pg_config as a binary.
        mkPgConfig = pg:
          let
            pgDev = pg.dev;
            expectedFile = "${pgDev}/nix-support/pg_config.expected";
          in pkgs.writeShellScriptBin "pg_config" ''
            FILE="${expectedFile}"
            if [ $# -eq 0 ]; then
              cat "$FILE"
              exit 0
            fi
            case "$1" in
              --version)  echo "PostgreSQL ${pg.version}";;
              --*)
                KEY=$(echo "$1" | sed 's/^--//' | tr '[:lower:]' '[:upper:]')
                VALUE=$(grep "^$KEY = " "$FILE" | sed "s/^$KEY = //")
                if [ -z "$VALUE" ]; then
                  echo "pg_config: invalid argument: $1" >&2; exit 1
                fi
                echo "$VALUE"
                ;;
              *) echo "pg_config: invalid argument: $1" >&2; exit 1;;
            esac
          '';

        mkDevShell = pg: pkgs.mkShell {
          buildInputs = [
            (mkPgConfig pg)
            pg.dev  # server headers, PGXS makefiles
            pg      # runtime binaries (postgres, initdb, etc.)
            pkgs.gcc
            pkgs.gnumake
            pkgs.pkg-config
          ];
          shellHook = ''
            export USE_PGXS=1
            echo "pg_timers dev shell — $(pg_config --version)"
          '';
        };

      in {
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
