{
  description = "docker-wyze-bridge - Wyze camera RTSP bridge built from source with Nix";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Detect architecture for native library selection
        arch =
          if system == "aarch64-darwin" then "arm64"
          else if system == "aarch64-linux" then "arm64"
          else if system == "x86_64-linux" then "amd64"
          else if system == "x86_64-darwin" then "amd64"
          else throw "Unsupported system: ${system}";

        # MediaMTX streaming server
        mediamtx = pkgs.stdenv.mkDerivation rec {
          pname = "mediamtx";
          version = "1.9.1";

          src =
            if pkgs.stdenv.isLinux && pkgs.stdenv.isAarch64 then
              pkgs.fetchurl {
                url = "https://github.com/bluenviron/mediamtx/releases/download/v${version}/mediamtx_v${version}_linux_arm64v8.tar.gz";
                sha256 = "sha256-Tc700NbMFIuHmuWxEWSsydA2vw7kGlmIUnL85xC/sZE=";
              }
            else if pkgs.stdenv.isLinux && pkgs.stdenv.isx86_64 then
              pkgs.fetchurl {
                url = "https://github.com/bluenviron/mediamtx/releases/download/v${version}/mediamtx_v${version}_linux_amd64.tar.gz";
                sha256 = "sha256-8eU2PMqTYCa8q7uWWSB39Rd+39whxK91Jf0e4zZgyjw=";
              }
            else if pkgs.stdenv.isDarwin && pkgs.stdenv.isAarch64 then
              pkgs.fetchurl {
                url = "https://github.com/bluenviron/mediamtx/releases/download/v${version}/mediamtx_v${version}_darwin_arm64.tar.gz";
                sha256 = "sha256-UHDaWCnBAlme0ZXZN45RXBlS8ursgGEZ5CaG+2KJ47w=";
              }
            else if pkgs.stdenv.isDarwin && pkgs.stdenv.isx86_64 then
              pkgs.fetchurl {
                url = "https://github.com/bluenviron/mediamtx/releases/download/v${version}/mediamtx_v${version}_darwin_amd64.tar.gz";
                sha256 = "sha256-N27KMavVj617Hg9UUvUm+e57TRqPOwm2QtsF1kPjMUA=";
              }
            else
              throw "Unsupported system: ${system}";

          nativeBuildInputs = [ pkgs.gnutar ];

          unpackPhase = "tar xzf $src";

          installPhase = ''
            mkdir -p $out/bin
            cp mediamtx $out/bin/
          '';
        };

        # Python with pip and virtualenv
        pythonWithPip = pkgs.python312.withPackages (ps: with ps; [
          pip
          virtualenv
        ]);

      in {
        packages = {
          wyze-bridge = let
            app = ./.;
          in pkgs.stdenv.mkDerivation {
            pname = "wyze-bridge";
            version = "2.10.3";
            src = app;

            nativeBuildInputs = [ pkgs.makeWrapper pythonWithPip ];

            buildPhase = ''
              # Create a virtual environment in the output directory
              mkdir -p $out/venv
              ${pythonWithPip}/bin/python -m venv $out/venv
              source $out/venv/bin/activate

              # Install Python dependencies
              pip install --quiet --upgrade pip
              pip install --quiet -r app/requirements.txt
            '';

            installPhase = ''
              # Copy application code
              mkdir -p $out/app
              cp -r app/* $out/app/

              # Create wrapper script - use venv's flask directly
              mkdir -p $out/bin
              cat > $out/bin/wyze-bridge << WRAPPER
              #!${pkgs.bash}/bin/bash

              # Set up writable directories for wyze-bridge data
              export WB_DATA_DIR="\''${WB_DATA_DIR:-\$HOME/.local/share/wyze-bridge}"
              mkdir -p "\$WB_DATA_DIR/tokens" "\$WB_DATA_DIR/img"

              # Copy mediamtx config to writable location if not exists
              if [ ! -f "\$WB_DATA_DIR/mediamtx.yml" ]; then
                cp "$out/app/mediamtx.yml" "\$WB_DATA_DIR/mediamtx.yml" 2>/dev/null || \
                  echo "pathDefaults: {}" > "\$WB_DATA_DIR/mediamtx.yml"
              fi

              export FLASK_APP="$out/app/frontend.py"
              export FLASK_ENV="\''${FLASK_ENV:-production}"
              export TOKEN_PATH="\$WB_DATA_DIR/tokens"
              export IMG_DIR="\$WB_DATA_DIR/img"
              export MTX_CONFIG="\$WB_DATA_DIR/mediamtx.yml"
              export MTX_BIN="${mediamtx}/bin/mediamtx"
              export LD_LIBRARY_PATH="$out/app/lib:${pkgs.lib.makeLibraryPath [ pkgs.ffmpeg ]}"
              export PATH="${pkgs.ffmpeg}/bin:${mediamtx}/bin:\$PATH"

              cd "$out/app"
              exec $out/venv/bin/flask run --host=0.0.0.0 "\$@"
              WRAPPER

              chmod +x $out/bin/wyze-bridge
            '';
          };

          default = self.packages.${system}.wyze-bridge;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            python312
            pythonWithPip
            ffmpeg
            mediamtx
            git
          ];

          shellHook = ''
            echo "🌉 Wyze Bridge Development Environment"
            echo "Python: $(python --version)"
            echo "FFmpeg: $(ffmpeg -version | head -1)"
            echo "MediaMTX: $(mediamtx --version 2>&1 | head -1 || echo 'installed')"
            echo ""

            # Set up Python virtual environment
            if [ ! -d .venv ]; then
              echo "Creating Python virtual environment..."
              python -m venv .venv
            fi

            source .venv/bin/activate

            # Install dependencies from requirements.txt
            if [ -f app/requirements.txt ]; then
              echo "Installing Python packages..."
              pip install -q --upgrade pip
              pip install -q -r app/requirements.txt
            fi

            echo ""
            echo "To run the bridge:"
            echo "  python -m flask --app app.frontend run --host=0.0.0.0"
            echo ""
            echo "Or use the system wrapper (after nix build):"
            echo "  nix shell .#wyze-bridge --command wyze-bridge"
            echo ""
          '';
        };
      }
    );
}
