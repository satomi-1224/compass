{
  description = "compass — macOS ネイティブのアプリランチャー";

  # **ビルドは提供しない。** 理由が二重にある（requirements.md 5.1 / 7.1）。
  #
  # 1. nixpkgs の Swift は 5.10。Swift 6 を要求するコードはストアの中では組めない
  # 2. アクセシビリティ権限はアプリの同一性に紐づくため、更新のたびにパスが変わる
  #    ストアへ本体を置くと権限が毎回外れる
  #
  # この flake が受け持つのは**設定・自動起動・ログの置き場所**で、本体は
  # `./scripts/install-app.sh` が `~/Applications/compass.app` へ入れる。

  outputs =
    { self }:
    {
      homeManagerModules = rec {
        compass = ./nix/home-manager.nix;
        default = compass;
      };
    };
}
