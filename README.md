# pc-backup

Macのデータを性質別にバックアップ・復元するツール。

- 通常ファイル: `rsync`ミラー
- Gitプロジェクト: チェックアウトを持たない独立ミラー
- 未コミット状態: staged／unstagedパッチと未追跡ファイル
- 機密情報: GPGによるAES-256暗号化
- 開発環境: Homebrew `Brewfile`

詳細設計は[Macバックアップシステム 設計書](docs/BACKUP_SYSTEM_PLAN.md)を参照。

## 利用手順

### Makeで実行する場合

通常のバックアップと検証は、次の1コマンドで連続実行できる。バックアップが失敗した場合はそこで停止し、検証は実行されない。

```bash
make run
```

初回の準備から検証まで連続実行する場合。

```bash
make first-backup
```

`first-backup`は次の順で実行する。

1. PythonとPyYAMLの準備
2. バックアップ先の初期化
3. Dry Run
4. 本番バックアップ
5. 整合性検証

Dry Runの結果を目視確認してから本番を実行したい場合は、分けて実行する。

```bash
make setup
make init
make dry-run
make run
```

利用できるコマンド一覧は次で表示できる。

```bash
make
```

### 1. プロジェクトへ移動

以下のコマンドは、すべてこのプロジェクトのルートで実行する。

```bash
cd /Users/katsuhiko.terada/data/dev/acn-ai/pc-backup-main
```

### 2. 必要なコマンドとPython環境を準備

GPGとGit LFSが未導入の場合はHomebrewでインストールする。

```bash
brew install gnupg git-lfs
```

Python 3とPyYAMLを確認し、不足していれば導入する。インストール前には確認が表示される。

```bash
./scripts/setup-dependencies.sh
./scripts/setup-dependencies.sh --check
```

### 3. `backup.yaml`を確認

少なくとも以下を確認する。

- `destination.root`: バックアップ先
- `destination.id`: バックアップ先の識別子
- `files.mirror`: 通常コピーするパス
- `git.roots`: Gitリポジトリを探索するルート
- `secrets.paths`: GPG暗号化するパス

`${HOME}`と`~`は自動展開される。HOME配下のパスは、バックアップ先に同じ相対階層で保存される。

```text
${HOME}/data/docs        -> <destination>/data/docs
${HOME}/data/environment -> <destination>/data/environment
${HOME}/data/dev/app     -> <destination>/data/dev/app/.git
${HOME}/data/secret      -> <destination>/data/secret/encrypted-backup.tar.gpg
```

Gitの`.git/`はチェックアウトを持たないミラー。ログ、マニフェスト、未コミット差分などの内部情報は`<destination>/.pc-backup/`に保存される。

`files.mirror`と`git.roots`は重なってもよい。例えば両方に`${HOME}/data/dev`を指定した場合、検出したGitリポジトリのディレクトリは通常のrsyncから自動除外し、Gitモードで保存する。リポジトリ間にある文書や非Gitディレクトリは通常コピーする。

```text
data/dev/notes/          -> 通常コピー
data/dev/example-app/    -> Git設定で保存
```

Gitリポジトリ内の`backup.yaml`などを`files.mirror`へファイル単位で直接指定した場合は、Gitミラーに加えてそのファイルも同じ論理位置へ保存する。

### 4. 暗号化パスフレーズをキーチェーンへ登録

`-w`は必ず最後に置く。入力内容は画面に表示されず、シェル履歴にも残らない。

```bash
security add-generic-password \
  -a pc-backup \
  -s pc-backup-gpg \
  -U \
  -w
```

登録状態の確認。このコマンドはパスフレーズを表示しない。

```bash
security find-generic-password \
  -a pc-backup \
  -s pc-backup-gpg
```

同じパスフレーズを別の安全なパスワードマネージャーにも保存する。キーチェーンもMacと一緒に失われる可能性があるため、キーチェーンだけを唯一の保管先にしない。

### 5. バックアップ先を初期化

初回に1度実行する。バックアップ先の内容を削除し、`.pc-backup-destination`も消えた場合は再実行する。

```bash
./scripts/init-backup-destination.sh
```

### 6. Dry Runで対象と保存先を確認

Dry Runはバックアップ先へデータを書き込まない。表示される`rsync`と`Git mirror`の左右のパスを確認する。

```bash
PC_BACKUP_DRY_RUN=1 ./scripts/backup.sh
```

### 7. 本番バックアップ

Macのスリープを抑止して実行する。

```bash
caffeinate -i ./scripts/backup.sh
```

`make backup`も上と同じコマンドをそのまま実行する。`make run`は続けて`./scripts/verify-backup.sh`を実行する。

`PC backup complete`と表示され、終了コードが0ならバックアップ成功。`failure(s)`が表示された場合はログを確認する。

```text
<destination>/.pc-backup/logs/
```

### 8. 整合性を検証

```bash
./scripts/verify-backup.sh
```

`Verification complete (0 warning(s))`と表示されれば検証成功。Gitオブジェクト、JSONマニフェスト、GPG暗号化アーカイブを検査する。

### 2回目以降

通常は次の2コマンドだけでよい。`init-backup-destination.sh`の再実行は不要。

```bash
caffeinate -i ./scripts/backup.sh
./scripts/verify-backup.sh
```

## 必要なコマンド

macOSのほか、`rsync`、`git`、`tar`、`gpg`、Python 3、PyYAMLを使用する。Homebrew情報を保存する場合は`brew`、LFSを使う場合は`git-lfs`も必要。

```bash
brew install gnupg git-lfs
./scripts/setup-dependencies.sh
```

依存セットアップは、利用中の環境を次の順で確認する。

1. `PC_BACKUP_PYTHON`で明示されたPython
2. プロジェクトの`.venv`
3. `PATH`上のPython 3.8以上
4. Homebrewが利用可能なら、確認後に`brew install python`

Pythonが利用できれば、プロジェクト専用`.venv`を作成し、確認後にPyYAMLを`requirements.txt`からインストールする。PythonもHomebrewもない場合は、Python公式macOSインストーラーの案内を表示する。

`backup.sh`などの実行時にも依存関係を確認する。不足している場合、手動実行ではインストール確認を表示する。LaunchAgentなど非対話環境では自動インストールせず、`setup-dependencies.sh`の事前実行を促して終了する。

状態確認だけ行う場合:

```bash
./scripts/setup-dependencies.sh --check
```

## 初期設定

```bash
cd /path/to/pc-backup
cp backup.yaml.example backup.yaml
chmod +x scripts/*.sh
```

`backup.yaml`の最低限の例:

```yaml
version: 1

destination:
  root: /Volumes/BackupDisk/mac-backup
  id: my-mac-backup-v1

files:
  mirror:
    - ~/Documents
    - ~/Desktop

git:
  roots:
    - ~/data/dev
    - ~/Developer
  default_mode: git-mirror

secrets:
  paths:
    - ~/.ssh
    - ~/data/dev/private-project/.env
  encryption:
    enabled: true
    keychain:
      account: pc-backup
      service: pc-backup-gpg
```

YAMLはPyYAMLの`safe_load`で読み込み、未知のキー、型、選択値、時刻、相対パスを起動時に検証する。`~`と`${HOME}`は読み込み時に展開される。パスフレーズ自体はYAMLへ保存しない。

### 暗号化パスフレーズ

バックアップ専用の長いパスフレーズをmacOSキーチェーンへ登録する。

```bash
security add-generic-password \
  -a pc-backup \
  -s pc-backup-gpg \
  -U \
  -w
```

`-w`を最後に置くと、パスフレーズの入力を求められる。コマンドの引数にパスフレーズを書かないため、シェル履歴に残らない。

復元時にも同じパスフレーズが必要になる。キーチェーンだけでなく、別の安全なパスワードマネージャーにも保管する。

キーチェーンに登録がない場合、手動実行では端末からパスフレーズを入力できる。バックアップ時は入力ミスを防ぐため2回、復元・検証時は1回入力する。LaunchAgentなど端末を持たない自動実行では入力できないため、キーチェーン登録が必須になる。

### バックアップ先の初期化

`destination.id`を設定した場合は、初回に一度だけ実行する。

```bash
./scripts/init-backup-destination.sh
```

外付けディスクが未接続のとき、同名のローカルディレクトリへ誤って保存するのを防ぐための識別ファイルが作成される。

## 保存方式の設定

Gitルート配下の既定は`git-mirror`。作業ツリーをコピーせず、ローカルブランチ、未pushコミット、タグ、stashを含むGit参照を保存する。

```yaml
git:
  roots:
    - ~/data/dev
  default_mode: git-mirror

  # GitHub等のURLと配置情報だけ保存する
  url_only:
    - ~/data/dev/disposable-project

  # 作業ツリーを含めて全体を保存する。
  # リポジトリ自体だけでなく、複数リポジトリを含む親DIRも指定できる。
  full:
    - ~/data/dev/local-data-project
    - ~/data/dev/project-worktrees

  # 保存しない
  skip:
    - ~/data/dev/scratch

  dirty_mode: backup # backup | warn | fail
```

`git-url`は、リモートURLがあり、作業ツリーがcleanで、未push・ローカル専用ブランチ・stashがない場合だけ使用される。条件を満たさない場合は、安全のため`git-mirror`へ自動昇格する。

`full`に親ディレクトリを指定すると、その配下で検出したすべてのGitリポジトリに`git-full`を適用する。個別リポジトリを`skip`に入れた場合は、親の`full`より`skip`を優先する。

`backup`ではstaged／unstaged差分と、gitignoreされていない未追跡ファイルを保存する。`.env`などのgitignore対象は自動保存しないため、必要なものを`secrets.paths`へ明示する。

## バックアップ

最初にdry-runで対象を確認する。

```bash
PC_BACKUP_DRY_RUN=1 ./scripts/backup.sh
```

本番実行:

```bash
./scripts/backup.sh
```

整合性検証:

```bash
./scripts/verify-backup.sh
```

バックアップ先の主な構成:

```text
<PC_BACKUP_ROOT>/
├── data/                   # $HOME/dataをそのまま再現
│   ├── docs/              # 通常ファイル
│   ├── dev/app/.git/      # チェックアウトなしGitミラー
│   └── secret/
│       └── encrypted-backup.tar.gpg
├── .pc-backup-destination
└── .pc-backup/             # 復元対象ではない内部情報
    ├── manifests/
    ├── git-state/
    ├── git-url/
    ├── homebrew/Brewfile
    ├── changes/
    ├── logs/
    └── locks/
```

HOME配下の保存先はYAMLのパスと同じ階層になる。Git、暗号化などの保存方式は階層を変えず、その位置にあるデータの表現方法として扱う。

## 復元

全対象のdry-run:

```bash
./scripts/restore.sh --dry-run --all
```

全対象を復元:

```bash
./scripts/restore.sh --all
```

対象を選んで復元:

```bash
./scripts/restore.sh --git
./scripts/restore.sh --files
./scripts/restore.sh --secrets
./scripts/restore.sh --files --git --no-secrets
./scripts/restore.sh --all --brew
```

既存の復元先があるGitリポジトリは上書きせずスキップする。通常ファイルと秘密情報は、実行前に全体確認が表示される。確認を省略する場合だけ`--yes`を指定する。

## 毎日の自動実行

時刻は`backup.yaml`で指定する。

```yaml
schedule:
  hour: 7
  minute: 30
```

登録:

```bash
./scripts/install-launch-agent.sh
```

LaunchAgentログ:

```text
~/Library/Logs/pc-backup.log
~/Library/Logs/pc-backup.err.log
```

## テスト

テスト環境、フィクスチャ、実行順序、検査項目、本番E2Eとの違いは[TESTING.md](docs/TESTING.md)を参照。

一時HOMEと一時バックアップ先を作り、以下を通して確認する。

- 通常ファイルのバックアップ・復元
- Gitミラーの初回作成と更新
- 更新前Git参照の保持
- staged／unstaged・未追跡ファイルの復元
- GPG暗号化・検証・復号
- JSONマニフェスト検証

```bash
./tests/integration.sh
```

テストデータは終了時に一時ディレクトリから削除され、実際のHOMEとバックアップ先は変更しない。
