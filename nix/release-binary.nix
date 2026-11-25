{
  stdenvNoCC,
  fetchurl,
  system,
}:

let
  version = "2.4.1-rigel.1";
  assets = {
    x86_64-linux = {
      platform = "linux-amd64";
      hash = "sha256-uM5t1qWdZXniOK/oZfkpJQb9WuVesPJmFCnGChfLydM=";
    };
    aarch64-linux = {
      platform = "linux-arm64";
      hash = "sha256-UNLAFs24f122eDorX3zWbov4OZA/9k68OgzPnHf5uzg=";
    };
    aarch64-darwin = {
      platform = "darwin-arm64";
      hash = "sha256-SmOZCHzFYdeyTYDHo/E45EHjCm2ixpRfqCG2cs/Syg4=";
    };
  };
  asset = assets.${system};
in
stdenvNoCC.mkDerivation {
  pname = "devenv-release";
  inherit version;
  src = fetchurl {
    url = "https://github.com/RigelBuild/devenv/releases/download/v${version}/devenv-v${version}-${asset.platform}.tar.gz";
    inherit (asset) hash;
  };
  sourceRoot = ".";
  dontBuild = true;
  installPhase = ''
    install -Dm755 "devenv-v${version}-${asset.platform}/devenv" "$out/bin/devenv"
  '';
  meta.mainProgram = "devenv";
}
