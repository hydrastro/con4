{
  description = "con4 — Connect Four in the terminal, local or over the network";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      package = pkgs: pkgs.stdenvNoCC.mkDerivation {
        pname = "con4";
        version = "1.0";
        src = ./.;
        nativeBuildInputs = [ pkgs.makeWrapper ];
        dontBuild = true;
        installPhase = ''
          runHook preInstall
          install -Dm755 con4.sh $out/bin/con4
          # socat for network games (openssl for TLS), tput for colour.
          # --suffix: a socat or nc you installed yourself comes first.
          wrapProgram $out/bin/con4 \
            --suffix PATH : ${pkgs.lib.makeBinPath (with pkgs; [ socat openssl ncurses gawk ])}
          runHook postInstall
        '';
        meta = {
          description = "Connect Four in the terminal, local or over the network";
          homepage = "https://github.com/hydrastro/con4";
          mainProgram = "con4";
          platforms = pkgs.lib.platforms.unix;
        };
      };
    in {
      packages = forAllSystems (pkgs: { default = package pkgs; con4 = package pkgs; });
      overlays.default = final: prev: { con4 = package final; };
    };
}
