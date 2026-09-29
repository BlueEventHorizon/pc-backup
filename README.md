# pc-backup

**Version: 0.1.0**

Macのデータを性質別にバックアップ・復元するツール。

- 通常ファイル: `rsync`ミラー
- Gitプロジェクト: 独立ミラー、URL記録、または作業ツリーの完全コピー
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
3. 事前確認（`make check`）
4. 本番バックアップ
5. 整合性検証

確認結果を目視してから本番を実行したい場合は、分けて実行する。初回は保存先が空で全ファイルが差分になるため、`make dry-run`ではなく`make check`で対象を確認する。

```bash
make setup
make init
make check
make run
```

利用できるコマンド一覧は次で表示できる。

```bash
make
```

### 1. プロジェクトへ移動

以下のコマンドは、すべてこのプロジェクトのルートで実行する。

```bash
cd /path/to/pc-backup
```

### 2. 必要なコマンドとPython環境を準備

暗号化バックアップを使う場合、GPGが未導入ならHomebrewでインストールする。

```bash
brew install gnupg
```

Python 3.8以上とPyYAMLを確認し、不足していれば導入する。インストール前には確認が表示される。

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

HOME外の通常ファイルとGitリポジトリは`<destination>/_absolute/`以下へ絶対パス相当の階層で保存する。Secretsは安全のためHOME配下だけを指定できる。すべてのバックアップ元はバックアップ先と同一、上位、下位の関係にならないよう検証され、重なる場合は処理を中止する。

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

### 6. 事前確認とDry Run

どちらもバックアップ先へデータを書き込まない。

`make check`は依存関係の確認に加え、設定、保存先識別子、保存元と保存先の重複を検査し、バックアップ対象を一覧表示する。保存先の中身とは比較しない。表示される`rsync`と`Git mirror`の左右のパスを確認する。

```bash
make check
# 依存関係以外の部分だけを実行する場合
PC_BACKUP_CHECK_ONLY=1 ./scripts/backup.sh
```

`make dry-run`は保存先と比較し、本番を実行したときに変わる内容だけを表示する。差分のない対象は表示しない。

```bash
make dry-run
# 同じ処理
PC_BACKUP_DRY_RUN=1 ./scripts/backup.sh
```

| 対象 | 表示内容 |
|---|---|
| 通常ファイル、`git-full` | `rsync --dry-run --itemize-changes`で転送・新規作成・削除（`*deleting`）されるファイル。パーミッションや更新時刻だけの変更（`.`で始まる行）は表示しない |
| `git-mirror` | 新規作成されるミラー、または新規・更新されるref（`new`/`update`）。ミラーにだけ残るref（更新前スナップショット等）は表示しない |
| `git-url` | 記録済みのURL・HEAD・branchから変わる場合 |
| Gitの未コミット変更 | 保存される場合（`would capture Git local changes`） |
| 機密情報、Brewfile、ツール一式 | 毎回作り直すため、差分にかかわらず作成予定として表示する |

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

`Verification complete (0 warning(s))`と表示されれば、実装されている全検査が成功している。Gitミラーには`git fsck --full`、JSONマニフェストには構文検査、GPG暗号化アーカイブには復号とtar一覧取得を行い、復元用の同梱ツール`.pc-backup/tool/`の有無を確認する。元データとの完全比較、マニフェスト内容のスキーマ検証、`git-full`や通常ファイルの内容比較は行わない。

パスフレーズが取得できない場合、Secrets検証は警告してスキップされるが、ほかに失敗がなければスクリプトの終了コードは0になる。したがって、終了コードだけでなく`0 warning(s)`も確認する。マニフェストはJSON構文だけを検査するため、単独で`verify-backup.sh`を実行しても、過去の`partial_failure`を内容から失敗判定することはない。

### 2回目以降

通常は次の2コマンドだけでよい。`init-backup-destination.sh`の再実行は不要。

```bash
caffeinate -i ./scripts/backup.sh
./scripts/verify-backup.sh
```

## 必要なコマンド

macOSのほか、`rsync`、`git`、`tar`、Python 3.8以上、PyYAMLを使用する。暗号化バックアップでは`gpg`、Homebrew情報を保存・復元する場合は`brew`も必要になる。`make backup`と`make run`はスリープ抑止のためmacOSの`caffeinate`を使用する。

`git.lfs_mode: local`は既にローカルに存在するLFS objectsを`rsync`するため、バックアップ処理自体は`git-lfs`コマンドを呼び出さない。ただし、復元後にLFSファイルの実体を取得・checkoutするには`git-lfs`が必要になる場合がある。

```bash
brew install gnupg
./scripts/setup-dependencies.sh
```

依存セットアップは、利用中の環境を次の順で確認する。

1. `PC_BACKUP_PYTHON`で明示されたPython
2. プロジェクトの`.venv`
3. `PATH`上のPython 3.8以上
4. Homebrewが利用可能なら、確認後に`brew install python`

Pythonが利用できれば、プロジェクト専用`.venv`を作成し、確認後にPyYAMLを`requirements.txt`からインストールする。PythonもHomebrewもない場合は、Python公式macOSインストーラーの案内を表示する。

`backup.sh`などの実行時にもPythonとPyYAMLを確認する。不足している場合、手動実行ではインストール確認を表示する。LaunchAgentなど非対話環境では自動インストールせず、`setup-dependencies.sh`の事前実行を促して終了する。`git`、`rsync`、`tar`、`gpg`などのコマンドは自動インストールせず、必要な処理の開始時に不足していれば終了する。

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

`destination.id`を設定した場合は、初回に一度だけ実行する。`make init`と`make first-backup`はこの識別子を必須とする。識別子を設定しない構成では初期化スクリプトを使わず、バックアップ先の誤認防止チェックも行われない。

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

`git-url`は、リモートURLがあり、未push・ローカル専用ブランチ・stashがない場合だけ使用される。条件を満たさない場合は、安全のため`git-mirror`へ自動昇格する。作業ツリーの変更（staged・unstaged・未追跡）は、`dirty_mode: backup`なら差分パッチとして保存されるため、`git-url`のままでよい（復元時に適用する）。`dirty_mode`が`warn`のときは、変更が失われないよう`git-mirror`へ昇格する。

以前`git-mirror`で保存したリポジトリが`git-url`に切り替わると、保存先に古いミラー（`<リポジトリ>/.git/`）が残る。復元は`.git`ミラーを先にcloneし、復元先があれば`git-url`をスキップするため、古いミラーが優先されてしまう。そこで`backup.sh`は、`git-url`のリポジトリに古いミラー（`backup.mode=git-mirror`のbareリポジトリ）を見つけると、対話端末で削除を確認する（`y`: このミラー、`a`: 残りすべて、それ以外: 残す）。`PC_BACKUP_ASSUME_YES=1`なら確認しない。非対話実行では削除せず警告する。削除するとミラーだけが持つ過去の状態（`refs/backup-snapshots/`）も失われる。`make dry-run`は削除予定を`would ask to remove stale Git mirror`と表示する。`make check`は保存先を読まないため確認しない。

`full`に親ディレクトリを指定すると、その配下で検出したすべてのGitリポジトリに`git-full`を適用する。個別リポジトリを`skip`に入れた場合は、親の`full`より`skip`を優先する。

`full`から外したリポジトリの旧コピーは、`backup.rsync_delete`では削除されない（同期対象内の削除だけを反映するため）。`git-mirror`へ切り替えた場合、次回の`make backup`が旧コピー（`<destination>/<repo>/`）を検出し、削除してミラーを作り直すか確認する。`y`で新しいミラーを作成した後に旧コピーを削除し、`files.mirror`で個別指定したリポジトリ内のファイルは残す。旧コピーだけにあるgitignore対象ファイル等はバックアップから消える（元リポジトリには残る）。

- 確認できない非対話実行（LaunchAgent等）や`N`の場合は旧コピーを変更せず、そのリポジトリを失敗として報告する。端末から`make backup`を実行するか、旧コピーを手動で削除する
- 旧コピーの中に別のGitリポジトリがある場合は自動で置き換えず、手動削除を案内する
- `PC_BACKUP_ASSUME_YES=1`を指定すると確認せずに置き換える
- `skip`にした場合や元リポジトリを削除した場合の旧コピーは対象外で、手動で削除する

`dirty_mode`の動作は次のとおり。

| 値 | 動作 |
|---|---|
| `backup` | staged／unstaged差分と、gitignoreされていない未追跡ファイルを保存する |
| `warn` | ローカル変更を保存せず警告する。コミット済みのrefsとobjectsは設定したGitモードで保存する |
| `fail` | ローカル変更があるリポジトリを失敗扱いにし、そのリポジトリのGit保存処理を行わない |

`.env`などのgitignore対象は`dirty_mode: backup`でも自動保存しないため、必要なものを`secrets.paths`へ明示する。stashはGit refとして`git-mirror`に含まれる。

そのほかのGit設定は次のとおり。

- `exclude_names`: Git探索時にpruneするディレクトリ名。`git-full`のコピー内容を除外する設定ではない
- `lfs_mode: local`: ローカルLFS objectsをミラーへコピーする
- `lfs_mode: warn`: ローカルLFS objectsがあれば警告し、コピーしない
- `lfs_mode: skip`: ローカルLFS objectsの確認とコピーを行わない
- `verify: true`: 新しく作る`git-mirror`を、ローカルディスク上で`git fsck --full`してから保存先へ置く。保存先のミラーを読み戻さないため、OneDriveでも遅くならない。既存ミラーの更新では`fsck`を行わない（`fetch`がパックの整合性と接続性を検査する）。保存済みミラー全体の検査は`make verify`で行う

### 機密情報と保持期間

`secrets.paths`に複数のパスを指定した場合、すべてを1つのtarへまとめる。暗号化された最新版は、先頭に指定したパスに対応するバックアップ先の`encrypted-backup.tar.gpg`へ保存する。暗号化時は日付付き世代も`<destination>/.pc-backup/secrets-history/`へ保存する。

秘密領域内のUnixソケットは復元可能なファイルではないため、自動的にアーカイブ対象から除外する。通常ファイル、ディレクトリ、シンボリックリンクはtarに含まれる。

暗号化を無効にするには、情報漏えいを避けるため`enabled: false`と`allow_plaintext: true`の両方が必要になる。この場合は日付付き暗号化世代を作らず、最新版を`plaintext-backup.tar`として保存する。

```yaml
secrets:
  encryption:
    enabled: true
    allow_plaintext: false
```

暗号化済み運用から平文運用へ切り替えても、以前の`encrypted-backup.tar.gpg`は自動削除されず、復元処理は暗号化版を優先する。方式を切り替える場合は、必要な世代を別途保全し、新しい平文バックアップを検証してから古い最新版ファイルを手動で整理する。通常運用では暗号化を無効にしないことを推奨する。

`backup.retention_days`は、日付付きSecrets世代、実行ログ、rsync変更記録、日付付きマニフェストの保持日数で、既定値は30日である。最新版のSecretsと`manifest-latest.json`は削除対象にならない。Gitの`refs/backup-snapshots/`はこの設定では削除されない。

## バックアップ

### 差分更新と世代管理

すべての対象が同じ方式で差分バックアップされるわけではない。対象ごとの更新方法は次のとおり。

| 対象 | 2回目以降の更新方法 | 補足 |
|---|---|---|
| 通常ファイル（`files.mirror`） | `rsync -a`で変更されたファイルだけを転送 | サイズと更新時刻を基準に比較する。通常ファイルの世代バックアップは作成しない |
| `git-full` | `rsync -a`で変更されたファイルだけを転送 | 作業ツリー、`.git`、gitignore対象を含むディレクトリ全体が対象。既定では削除も反映する |
| `git-mirror` | 元リポジトリのrefsがミラーと違うときだけ`git fetch`で新しいGitオブジェクトとrefsを取得。同じなら何も書かない | 更新前のheads・tags・stashは`refs/backup-snapshots/`へ保存する（更新があるときだけ）。マニフェストの`verification`は、新規`ok`、更新`fetched`、変更なし`unchanged` |
| 機密情報（`secrets.paths`） | tarアーカイブ全体を毎回作り直す | 暗号化有効時はGPG暗号化し、最新版に加えて日付付き世代を保存する |
| Brewfile | `backup.brew: true`の場合に毎回生成または更新 | `brew`がなければ警告してスキップする |
| マニフェスト | Dry Run以外で毎回生成または更新 | バックアップ内容と実行結果を記録する |

`rsync`を使う通常ファイルと`git-full`は、未変更ファイルを再転送しない。ただし、これは変更履歴を複数世代保持する方式ではなく、バックアップ先を最新状態へ近づけるミラー方式である。また、ローカルパス間の転送では、変更されたファイルの一部分だけではなく、基本的に変更されたファイル単位で転送される。

`backup.rsync_delete`は`files.mirror`のディレクトリと`git-full`に適用され、既定値は`true`である。元データ側で削除したファイルもバックアップ先から削除し、現在の状態と一致するミラーを保つ。バックアップ先だけに置いたファイルも削除対象になるため、バックアップ先を手動の保管場所として併用しない。過去の削除済みファイルを残したい場合だけ`false`へ変更できる。

```yaml
backup:
  rsync_delete: true
```

最初にdry-runで削除される内容（`*deleting`）を確認する。

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
└── .pc-backup/             # 管理情報と復元用メタデータ
    ├── manifests/
    ├── git-state/
    ├── git-url/
    ├── git-full/
    ├── secrets-history/
    ├── homebrew/Brewfile
    ├── changes/
    ├── logs/
    ├── locks/
    └── tool/               # 復元用のこのツール一式とbackup.yaml
```

HOME配下の保存先はYAMLのパスと同じ階層になる。Git、暗号化などの保存方式は階層を変えず、その位置にあるデータの表現方法として扱う。

### 運用上の制約

- 通常ファイルと`git-full`の保存先全体を一括で切り替えるトランザクションやスナップショットはない。中断時には一部だけ更新された状態になり得る
- OneDriveなどFile Provider配下への書き込み完了は確認するが、クラウド側への同期完了、空き容量、オンラインのみファイルの利用可能性は検証しない
- 通常ファイルのバイト単位ハッシュやクラウド側のバージョン履歴は検証しない
- Git snapshot refsは自動削除されないため、長期運用では保存容量を確認する

## 復元

### 新しいMacで復元する

本番バックアップのたびに、復元に必要なファイル（`Makefile`、`README.md`、`requirements.txt`、`scripts/`）と、実行時の設定ファイルを`backup.yaml`として`<destination>/.pc-backup/tool/`へ保存する。このプロジェクトのcheckoutや`backup.yaml`が手元になくても、バックアップ先だけから復元できる。復元に使わない`docs/`や`tests/`等は含まない。

```bash
# バックアップ先（例: OneDriveの同期完了後）からローカルへコピーして実行する
cp -R ~/Library/CloudStorage/OneDrive-Accenture/backup/.pc-backup/tool ~/pc-backup
cd ~/pc-backup
make restore-dry-run  # Python/PyYAMLが未準備なら確認のうえ準備する
make restore
```

- バックアップ先の中で直接実行せず、ローカルへコピーしてから実行する（`.venv`がバックアップ先に作られるのを避けるため）
- バックアップ先のマウント位置が元のMacと違う場合は、コピーした`backup.yaml`の`destination.root`を修正する。`destination.id`の検証により、別の保存先を誤って使うことはない
- 暗号化された機密情報の復元にはパスフレーズが必要。新しいMacのKeychainには無いため、実行時に入力する
- Finderで`.pc-backup`が見えない場合は`Cmd+Shift+.`で隠しファイルを表示する

### 復元コマンド

引数なしの`restore.sh`と`--all`は、通常ファイル、Git、Secretsを対象にする。復元は常にSecrets → 通常ファイル → Gitの順で行う。`git-url`のリポジトリはリモートから`git clone`するため、先にSSH鍵などの認証情報を戻す必要があるからである。Secretsの復号に失敗した場合は、他の復元を始める前に停止する。

Gitの復元で一部のリポジトリが失敗しても（`git clone`の認証エラー、リモートの削除、ミラーの検証失敗、未コミット変更の適用失敗など）、残りのリポジトリの復元は続行する。最後に失敗した項目を一覧表示し、終了コードを1にする。原因を直したら`./scripts/restore.sh --git`を再実行する。復元先がすでにあるリポジトリはスキップされる。Homebrewパッケージは自動では復元せず、`--brew`を明示した場合だけ`brew bundle`を実行する。Dry Runでは書き込みも確認プロンプトも行わない。

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

通常ファイルは`rsync -a`で復元し、既存ファイルを更新するが、復元先にだけ存在するファイルは削除しない。Secretsは最新版のアーカイブをHOMEへ展開し、同名ファイルを上書きする。日付付きSecrets世代を選択して復元する機能はない。

既存の復元先に`.git`があるGitリポジトリは上書きせずスキップする。ただし、`files.mirror`で明示したファイルの復元などによって復元先ディレクトリが先に作られていても、`.git`がなければ一時cloneの内容をそのディレクトリへ統合し、既存の追加ファイルを残す。`git-full`と`git-url`は復元先パスが既に存在すればスキップする。

`git-url`は保存されたリモートURLからcloneしたあと、バックアップ時に記録したbranchとHEADへ切り替え、`git-state/`に保存した差分（staged・unstaged・未追跡ファイル）を適用する。記録したHEADがリモートに存在しない場合（リモートの履歴の書き換えなど）は、復元失敗として記録する。linked worktreeはそれぞれ独立した通常のGitリポジトリとして復元され、元のworktree共有関係は再構築しない。

Dry Run以外の復元では、選択した処理全体に対して実行前に1回確認が表示される。確認を省略する場合だけ`--yes`を指定する。

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

LaunchAgentが定刻に実行するのは`backup.sh`だけで、`verify-backup.sh`は自動実行しない。また、登録されたコマンドは`caffeinate`を使用しないため、実行中のスリープ抑止も行わない。暗号化を有効にした非対話実行ではパスフレーズを入力できないため、事前のキーチェーン登録が必須になる。プロジェクトを移動した場合はplist内のスクリプト絶対パスが変わるため、LaunchAgentを再登録する。

LaunchAgentログ:

```text
~/Library/Logs/pc-backup.log
~/Library/Logs/pc-backup.err.log
```

## テスト

テスト環境、フィクスチャ、実行順序、検査項目、本番E2Eとの違いは[TESTING.md](docs/TESTING.md)を参照。

一時HOMEと一時バックアップ先を作り、以下を通して確認する。

- 通常ファイルのバックアップ・復元
- 通常ファイルと`git-full`から削除したファイルのミラー削除
- Gitミラーの初回作成と更新
- 非bareの既存`.git/`（旧`git-full`コピー等）へのミラー書き込み拒否と、確認後のミラーへの置き換え
- linked worktreeごとの独立ミラー作成と検証
- 不整合commit-graphの自動再構築
- 更新前Git参照の保持
- staged／unstaged・未追跡ファイルの復元
- GPG暗号化・検証・復号
- UnixソケットのSecrets除外
- JSONマニフェスト検証

```bash
./tests/integration.sh
```

テストデータは終了時に一時ディレクトリから削除され、実際のHOMEとバックアップ先は変更しない。
