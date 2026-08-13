{ config, lib, pkgs, ... }:

let
  cfg = config.programs.compass;
  tomlFormat = pkgs.formats.toml { };

  # **書かれていないファイルは置かない。**
  #
  # compass はファイル欠損を「空」として扱い、既定値で動く。空の TOML を置くと
  # 同じ結果になるが、設定していない人のディレクトリに中身のないファイルが
  # 増えるだけなので置かない。
  sourceFor = name: settings: settingsFile:
    if settingsFile != null then
      settingsFile
    else if settings != { } && settings != [ ] then
      tomlFormat.generate "compass-${name}" (if builtins.isList settings then { snippets = settings; } else settings)
    else
      null;

  configSource = sourceFor "config.toml" cfg.settings cfg.settingsFile;
  hotkeysSource = sourceFor "hotkeys.toml" cfg.hotkeys cfg.hotkeysFile;
  snippetsSource = sourceFor "snippets.toml" cfg.snippets cfg.snippetsFile;
in
{
  options.programs.compass = {
    enable = lib.mkEnableOption "compass（macOS ネイティブのアプリランチャー）";

    app = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/Applications/compass.app";
      description = ''
        compass.app の場所。

        **Nix ストアには置かないこと。** アクセシビリティ権限はコード署名とパスを含む
        アプリの同一性に紐づくため、更新のたびにパスが変わると権限が外れる。
        リポジトリの `./scripts/install-app.sh` が既定でこの場所へ入れる。
        **既定から変えるなら、スクリプト側にも同じ場所を渡すこと**
        （`COMPASS_APP=… ./scripts/install-app.sh`）。ずれると launchd が
        居ない実行ファイルを起動し続ける。

        Swift 6 が要るため nixpkgs の Swift（5.10）ではビルドできない。
        このモジュールが受け持つのは**設定・自動起動・ログの置き場所**だけ。
      '';
    };

    startService = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        launchd agent として登録し、ログイン時に起動する。落ちても上げ直す。

        compass はメニューバーにも Dock にも出ない不可視の常駐プロセスなので、
        起動しているかは `launchctl print gui/$(id -u)/org.nix-community.home.compass`
        か `logFile` で確かめる。
      '';
    };

    settings = lib.mkOption {
      type = tomlFormat.type;
      default = { };
      example = lib.literalExpression ''
        {
          appearance = { width = 680; max_results = 9; };
          search.files.scopes = [ "~" ];
          clipboard = { enabled = true; max_items = 50; };
          search.keywords = [
            { prefix = "f"; kind = "file"; }
            { prefix = "g"; kind = "web"; url = "https://www.google.com/search?q={query}"; }
          ];
        }
      '';
      description = ''
        `~/.config/compass/config.toml` の内容。

        **`search.keywords` は置き換えになる**（既定へ追加されるのではない）ので、
        書くなら必要なものを全部書く。書かなければ既定（`f` = ファイル、
        `g` = Google、`gh` = GitHub）が使われる。

        compass は保存を検知して自動で読み直すので、switch すればそのまま反映される。
        **設定に不備があると通知センターに出て、直前の正常な設定のまま動き続ける。**
      '';
    };

    hotkeys = lib.mkOption {
      type = tomlFormat.type;
      default = { };
      example = lib.literalExpression ''
        {
          trigger = "cmd+alt+shift";
          actions = { space = "search"; v = "clipboard"; w = "snippets"; };
          commands = {
            t = "open -a WezTerm";
            f = "open -a Finder";
            b = "open -a 'Google Chrome'";
          };
        }
      '';
      description = ''
        `~/.config/compass/hotkeys.toml` の内容。

        **トリガーは 1 種類だけ**で、その配下に単キーを並べる。トリガーを無視した
        個別指定や複数トリガーは受け付けない（requirements.md 3.1）。

        `actions` に書けるのは `search` / `clipboard` / `snippets` の 3 つだけ。
        それ以外は `commands` に外部コマンドとして書く。
        **同じキーが `actions` と `commands` の両方にあると設定エラーになる。**

        `trigger` を省略すると `cmd+alt+shift`、`space` を割り当てなければ
        `<trigger>+Space` が検索窓になる。
      '';
    };

    snippets = lib.mkOption {
      type = lib.types.listOf tomlFormat.type;
      default = [ ];
      example = lib.literalExpression ''
        [
          { title = "now"; body = "{date:yyyy-MM-dd}"; }
          { title = "TwitterID"; body = "@example"; }
          { title = "branch"; body_command = "git branch --show-current"; }
        ]
      '';
      description = ''
        `~/.config/compass/snippets.toml` の `[[snippets]]`。

        `body`（静的テキスト。`{date:...}` などのプレースホルダを含みうる）か
        `body_command`（外部コマンドの出力）の**どちらか一方**を書く。
        両方書くと設定エラーになる。
      '';
    };

    settingsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./config.toml";
      description = ''
        既に書いてある `config.toml` をそのまま置く。`settings` より優先する。
        TOML を Nix の属性集合へ書き直したくない場合に使う。
      '';
    };

    hotkeysFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "書いてある `hotkeys.toml` をそのまま置く。`hotkeys` より優先する。";
    };

    snippetsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "書いてある `snippets.toml` をそのまま置く。`snippets` より優先する。";
    };

    logFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/Library/Logs/compass.log";
      description = "launchd から起動したときのログの出力先。";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ "debug" "info" "warn" "error" "off" ];
      default = "info";
      description = ''
        ログの粒度。設定のリロードやホットキーの登録を追うときは `debug` にする。

        **正常時の通知は出ない**ので、動きを確かめる手段はこのログだけ。
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = "programs.compass は macOS でのみ使える。";
      }
    ];

    # **`xdg.configFile` を使う。** compass は `XDG_CONFIG_HOME` を優先して設定を
    # 探すため、`.config` を直接書くと、`xdg.configHome` を変えている環境で
    # 置いた場所と読む場所がずれる。
    xdg.configFile = lib.mkMerge [
      (lib.mkIf (configSource != null) {
        "compass/config.toml".source = configSource;
      })
      (lib.mkIf (hotkeysSource != null) {
        "compass/hotkeys.toml".source = hotkeysSource;
      })
      (lib.mkIf (snippetsSource != null) {
        "compass/snippets.toml".source = snippetsSource;
      })
    ];

    launchd.agents.compass = lib.mkIf cfg.startService {
      enable = true;
      config = {
        ProgramArguments = [ "${cfg.app}/Contents/MacOS/compass" ];
        RunAtLoad = true;
        # 理由不明で落ちたときに上げ直す。落ちたままだとホットキーが全て死ぬ。
        KeepAlive = true;
        ProcessType = "Interactive";
        EnvironmentVariables = {
          COMPASS_LOG_LEVEL = cfg.logLevel;
          # **設定の場所を明示する。** launchd から起動するとシェルの環境を
          # 継承しないので、`XDG_CONFIG_HOME` を設定している環境では compass が
          # モジュールの書いた場所を見ない。欠損は「空」として扱われ、成功時は
          # 通知も出ないため、**設定が丸ごと無視されていることに気づけない。**
          XDG_CONFIG_HOME = config.xdg.configHome;
        };
        StandardOutPath = cfg.logFile;
        StandardErrorPath = cfg.logFile;
      };
    };

    home.activation.compassApp = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      # **launchd は StandardOutPath の親ディレクトリを作らない。** 無いと job が
      # 起動できず、しかもログが唯一の観測手段なので何も残らない。
      run mkdir -p ${lib.escapeShellArg (builtins.dirOf cfg.logFile)}

      # **アプリの実体は Nix の管理外**なので、無ければここで気づけるようにする。
      if [ ! -x "${cfg.app}/Contents/MacOS/compass" ]; then
        warnEcho "compass.app が ${cfg.app} に無い。リポジトリで ./scripts/install-app.sh release を実行する"
      fi
    '';
  };
}
