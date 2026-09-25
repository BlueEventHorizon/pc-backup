# Macバックアップシステム 設計書

## 1. 文書情報

- 対象: `pc-backup`
- ステータス: 実装済み仕様
- 設定形式: YAMLのみ
- 最終更新: 2026-08-07
- 対象OS: macOS

この文書は将来構想ではなく、現在のスクリプトが実際に行う処理を記載する。操作手順はプロジェクト直下の`README.md`を参照する。

## 2. 目的

Mac内のデータを、データの性質に適した方式でバックアップし、新しいMacへ復元できるようにする。

- 通常ファイルは`rsync`でコピーする。
- Gitプロジェクトは作業ツリーを持たないミラーとして保存する。
- 未コミット差分と未追跡ファイルも復元用に保存する。
- 機密情報はGPGのAES-256共通鍵暗号で保存する。
- Homebrewの状態を`Brewfile`等で保存する。
- バックアップ後にマニフェスト、Git、暗号化アーカイブを検証できる。

## 3. 設計原則

### 3.1 保存先はHOMEの構造を再現する

コピー方式とディレクトリ構成を切り離す。`files`、`repositories`、`secrets`などの方式別ディレクトリは作らない。

```text
${HOME}/data/docs        -> <destination>/data/docs
${HOME}/data/environment -> <destination>/data/environment
${HOME}/data/dev/app     -> <destination>/data/dev/app/.git
${HOME}/data/secret      -> <destination>/data/secret/encrypted-backup.tar.gpg
```

HOME外の絶対パスを指定した場合は、`<destination>/_absolute/`以下に絶対パスの構造を再現する。

### 3.2 保存方式はリーフの表現とする

- 通常ディレクトリ: 内容をそのままコピー
- Gitミラー: 元の位置に相当するディレクトリの`.git/`
- 機密ディレクトリ: 元の位置に相当するディレクトリの`encrypted-backup.tar.gpg`
- `git-full`: 元の位置に作業ツリーも含めてコピー

### 3.3 内部情報は隠す

利用者が通常閲覧する必要のないデータは`<destination>/.pc-backup/`に集約する。

## 4. システム構成

```text
backup.yaml
    |
    v
load-config.py -- PyYAML safe_load・スキーマ検証
    |
    v
backup.sh
    +-- rsync: 通常ファイル
    +-- git-backup.sh: Git検出・ミラー・ローカル状態
    +-- gpg/tar: 機密情報
    +-- brewfile-update.sh: Homebrew情報
    +-- manifest: 実行結果
    |
    +-- verify-backup.sh: 整合性検証
    +-- restore.sh + git-restore.sh: 復元
```

## 5. バックアップ先の構成

```text
<PC_BACKUP_ROOT>/
├── data/                              # HOME相対の実データ
│   ├── docs/
│   ├── environment/
│   ├── dev/
│   │   └── app/
│   │       └── .git/                 # bare Git mirror
│   └── secret/
│       └── encrypted-backup.tar.gpg
├── _absolute/                         # HOME外を指定した場合
├── .pc-backup-destination             # 保存先識別子
└── .pc-backup/
    ├── manifests/
    │   ├── manifest-latest.json
    │   └── manifest-<timestamp>.json
    ├── git-state/<repository-path>/
    │   ├── staged.patch
    │   ├── unstaged.patch
    │   ├── untracked.tar.gz
    │   └── status.json
    ├── git-url/                       # URLのみのリポジトリ情報
    ├── git-full/                      # git-fullの復元メタデータ
    ├── secrets-history/               # 日付付き暗号化アーカイブ
    ├── homebrew/
    │   ├── Brewfile
    │   ├── brew-leaves.txt
    │   └── brew-casks.txt
    ├── changes/                       # rsyncのitemize-changes
    ├── logs/
    └── locks/backup.lock/
```

## 6. YAML設定

### 6.1 全体例

```yaml
version: 1

destination:
  root: ${HOME}/Library/CloudStorage/OneDrive/example/backup
  id: my-mac-backup-v1

files:
  mirror:
    - ${HOME}/data/environment
    - ${HOME}/data/docs
    - ${HOME}/data/dev/acn-ai/pc-backup-main/backup.yaml

git:
  roots:
    - ${HOME}/data/dev
  default_mode: git-mirror
  url_only: []
  full: []
  skip: []
  exclude_names:
    - node_modules
    - .venv
    - DerivedData
    - .build
    - build
    - dist
    - .cache
  dirty_mode: backup
  lfs_mode: local
  verify: true

secrets:
  paths:
    - ${HOME}/data/secret
  encryption:
    enabled: true
    allow_plaintext: false
    keychain:
      account: pc-backup
      service: pc-backup-gpg

backup:
  rsync_delete: true
  retention_days: 30
  brew: true

schedule:
  hour: 7
  minute: 30
```

### 6.2 スキーマ

| キー | 型 | デフォルト | 意味 |
|---|---|---:|---|
| `version` | integer | `1` | 設定バージョン。現在は1のみ |
| `destination.root` | absolute path | 必須 | バックアップ先 |
| `destination.id` | string | 空 | 保存先識別子 |
| `files.mirror` | path list | `[]` | `rsync`対象 |
| `git.roots` | path list | `[]` | Git探索ルート |
| `git.default_mode` | enum | `git-mirror` | 既定のGit保存方式 |
| `git.url_only` | path list | `[]` | `git-url`を指定する完全一致パス |
| `git.full` | path list | `[]` | `git-full`にするリポジトリまたは親ディレクトリ |
| `git.skip` | path list | `[]` | 保存しない完全一致パス |
| `git.exclude_names` | string list | 上記例 | Git探索時にpruneするディレクトリ名 |
| `git.dirty_mode` | enum | `backup` | `backup` / `warn` / `fail` |
| `git.lfs_mode` | enum | `local` | `local` / `warn` / `skip` |
| `git.verify` | boolean | `true` | 保存後の`git fsck --full` |
| `secrets.paths` | path list | `[]` | 暗号化アーカイブへ入れるパス |
| `secrets.encryption.enabled` | boolean | `true` | GPG暗号化 |
| `secrets.encryption.allow_plaintext` | boolean | `false` | 暗号化無効時の平文保存許可 |
| `secrets.encryption.keychain.account` | string | `pc-backup` | Keychain account |
| `secrets.encryption.keychain.service` | string | `pc-backup-gpg` | Keychain service |
| `backup.rsync_delete` | boolean | `true` | 通常ディレクトリと`git-full`の`--delete` |
| `backup.retention_days` | integer | `30` | 日付付きメタデータ等の保持日数（1〜3650） |
| `backup.brew` | boolean | `true` | Homebrew情報の保存 |
| `schedule.hour` | integer | `7` | LaunchAgent実行時（0〜23） |
| `schedule.minute` | integer | `30` | LaunchAgent実行分（0〜59） |

PyYAMLの`safe_load`を使用し、未知のキー、型、enum、時刻範囲、相対パスを拒否する。`~`と環境変数（`${HOME}`等）はロード時に展開する。`backup.conf`方式はサポートしない。

## 7. 通常ファイル

- `files.mirror`の各パスを`rsync -a --human-readable --itemize-changes`でコピーする。
- ディレクトリは中身を対応する保存先ディレクトリへ同期する。
- `rsync_delete: true`（既定）では、ディレクトリ内の削除も保存先へ反映する。
- `rsync_delete: false`では、保存先にだけ残るファイルを削除しない。
- この設定は`git-full`にも適用する。
- 存在しない指定パスは警告としてマニフェストに記録する。
- 上位で指定したシンボリックリンクがディレクトリを指す場合、保存名はYAMLの論理パスを保ち、リンク先の内容をコピーする。内部のシンボリックリンクは`rsync -a`によりリンクとして保存する。

### 7.1 Git探索ルートとの重複

`files.mirror`のディレクトリと`git.roots`は重複を許可する。バックアップ開始時にGitリポジトリを先に検出し、通常ディレクトリのrsyncから各リポジトリの相対パスを除外する。

```text
files.mirror: ${HOME}/data/dev
git.roots:    ${HOME}/data/dev

${HOME}/data/dev/notes/       -> rsyncで通常コピー
${HOME}/data/dev/example-app/ -> git.default_modeまたは例外モード
```

通常コピー対象がGitリポジトリ自体と同じ場合は、そのディレクトリ全体をGit処理へ委譲する。Gitリポジトリ内の単一ファイルが`files.mirror`に直接指定された場合は、そのファイルのみ別途コピーする。

復元時も同じ境界を使い、親ディレクトリの通常復元からGit保存領域を除外する。明示ファイルにより復元先リポジトリのディレクトリが先に作られている場合は、Gitを一時ディレクトリへcloneし、明示ファイルを保ったまま作業ツリーと`.git`をマージする。

## 8. Gitバックアップ

### 8.1 検出

- `git.roots`の下を`find`で探索し、`.git`マーカーからリポジトリを検出する。
- `.git`がディレクトリの通常リポジトリと、`.git`がファイルのworktreeを扱う。
- `exclude_names`に一致するディレクトリはpruneする。`.build`内のSwiftPM一時リポジトリ等は対象にしない。
- 同じトップレベルを複数回検出した場合は重複を除く。
- HEADのGitオブジェクトを読めないリポジトリは、警告およびバックアップ失敗として扱う。

### 8.2 保存モード

| モード | 保存内容 | 保存先 |
|---|---|---|
| `git-mirror` | 全Git refsとobjects。作業ツリーなし | `<logical-repo>/.git/` |
| `git-url` | 元パス、URL、HEAD、branch | `.pc-backup/git-url/` |
| `git-full` | 作業ツリーと`.git`を`rsync` | `<logical-repo>/` |
| `skip` | 保存しない | なし |

ルールの優先順位は`skip` → `full` → `url_only` → `default_mode`。`skip`と`url_only`はリポジトリパスとの完全一致で判定する。`full`は完全一致に加え、指定ディレクトリ配下で検出したすべてのリポジトリに適用する。これによりworktree群を含む親ディレクトリを1件で指定できる。

### 8.3 `git-mirror`

初回は次を実行する。

```bash
git clone --mirror --no-hardlinks <source> <temporary-destination>
```

成功後に一時ディレクトリを最終的な`.git/`へ移動する。2回目以降は、更新前refsを`refs/backup-snapshots/<timestamp>/`へ保存し、ローカルの元リポジトリから`refs/*`をfetchする。

既存の`.git/`がbareリポジトリでない場合（`git-full`から`git-mirror`へ切り替えた後に残った旧コピー等）は、fetchせずにそのリポジトリを失敗として扱う。判定は`git rev-parse --is-bare-repository`の出力が`true`であることで行う（非bareの`.git/`でも終了コードは0になるため）。旧コピーを手動で削除すると、次回に新しいミラーが作成される。

ミラーには復元用の独自configを保存する。

```ini
[backup]
    originalPath = /Users/example/data/dev/app
    originalOrigin = git@github.com:owner/app.git
    mode = git-mirror
    statePath = .pc-backup/git-state/data/dev/app
```

### 8.4 `git-url`の安全条件

URLのみの保存は、次の全条件を満たす場合だけ許可する。

- remote URLがある。
- staged、unstaged、未追跡ファイルがない。
- upstreamより先行したコミットがない。
- upstreamのないローカルブランチがない。
- stashがない。

条件を満たさない場合は、データ喪失を避けるため自動的に`git-mirror`へ昇格する。

### 8.5 未コミット状態

`dirty_mode: backup`の場合、次を`.pc-backup/git-state/<repository-path>/`へ保存する。

- staged差分: `staged.patch`
- unstaged差分: `unstaged.patch`
- gitignoreされていない未追跡ファイル: `untracked.tar.gz`
- 件数とタイムスタンプ: `status.json`

gitignoreされた`.env`等はこの処理には入らない。必要なものは`secrets.paths`に入れる。stashはGit refとしてミラーに保存する。

### 8.6 Git LFS

- `local`: 元リポジトリのローカルLFS objectsをミラーへ`rsync`する。
- `warn`: LFS objectsを検出して警告するがコピーしない。
- `skip`: LFS objectsを確認しない。

## 9. 機密情報

### 9.1 暗号化

`secrets.paths`の存在するパスをHOME相対で1つのtarへまとめ、次の条件でGPG共通鍵暗号化する。

```text
gpg --symmetric --cipher-algo AES256 --pinentry-mode loopback
```

最新版は、先頭の`secrets.paths`に対応する保存先ディレクトリの`encrypted-backup.tar.gpg`へ保存する。日付付き世代は`.pc-backup/secrets-history/`へ保存する。

`~/.ssh/agent`、GnuPG socket等の一時ソケットはtarから除外する。暗号化成功後、平文のtarは作業用一時ディレクトリとともに削除する。

`encryption.enabled: false`で平文保存するには、`allow_plaintext: true`も必要である。既定値は暗号化有効、平文拒否とする。

### 9.2 パスフレーズ

macOS Keychainからaccount/serviceの組で取得する。

```bash
security add-generic-password \
  -a pc-backup \
  -s pc-backup-gpg \
  -U \
  -w
```

`-w`は必ず最後に置き、対話入力する。手動実行時にKeychainになければ、端末から非表示入力する。バックアップ時は2回入力し、復元・検証時は1回入力する。

LaunchAgentには対話端末がないため、定期実行ではKeychain登録を必須とする。復元に必要なパスフレーズはMacとは別の安全なパスワードマネージャーにも保管する。

## 10. Homebrew

`backup.brew: true`で`brew`が存在する場合、次を`.pc-backup/homebrew/`へ保存する。

- `Brewfile`: `brew bundle dump --force`の結果
- `brew-leaves.txt`: `brew leaves`
- `brew-casks.txt`: `brew list --cask`

`brew bundle dump`が失敗した場合は、leavesとcasksから最小の`Brewfile`を生成する。復元時に`--brew`を指定すると`brew bundle`を実行する。

## 11. マニフェストとログ

### 11.1 マニフェスト

`.pc-backup/manifests/manifest-latest.json`および日付付きファイルに次を記録する。

- schema version、backup ID、開始・完了時刻、hostname
- 全体status、warning数、failure数
- 通常ファイルの元パス、保存パス、メソッド、結果
- Gitの元パス、保存パス、mode、origin、HEAD、branch
- dirty状態、未追跡数、ahead数、upstreamのないbranch数、stash数、検証結果

### 11.2 ログ

- 実行ログ: `.pc-backup/logs/<timestamp>.log`
- rsync変更記録: `.pc-backup/changes/`
- LaunchAgent stdout: `~/Library/Logs/pc-backup.log`
- LaunchAgent stderr: `~/Library/Logs/pc-backup.err.log`

Dry Runは保存先にログやマニフェストを書かない。

## 12. 安全設計

### 12.1 保存先識別子

`destination.id`が設定されている場合、初回に`init-backup-destination.sh`が`<destination>/.pc-backup-destination`を作成する。バックアップ、検証、復元はファイル内のidがYAMLと一致しなければ停止する。

外付けディスクやクラウドストレージが利用できないとき、意図しないローカルディレクトリへ書き込むことを防ぐ。

### 12.2 保存元と保存先の重複防止

論理パスとシンボリックリンク解決後の物理パスを使い、次の場合は開始前に停止する。

- 保存元と保存先が同一
- 保存元の下に保存先がある
- 保存先の下に保存元がある

`files.mirror`、`git.roots`、`secrets.paths`の全てを検査し、バックアップの自己取り込みを防ぐ。

### 12.3 排他制御

`.pc-backup/locks/backup.lock/`を原子的に作成する。すでに存在する場合は二重起動と判定して停止する。ownerファイルにPID、開始時刻、hostnameを記録する。通常終了、エラー、シグナル時は`trap`で解放する。Dry Runではロックを作成しない。

### 12.4 一時ファイルと更新

- Gitミラー初回作成は一時ディレクトリから`mv`する。
- 暗号化アーカイブのlatestは一時名から`mv`する。
- マニフェストlatestも一時名から`mv`する。
- 一時作業ディレクトリは`.pc-backup/.work.*`を使い、`trap`で削除する。
- rsync先全体のトランザクションやスナップショットは実装していない。

### 12.5 パスとアーカイブの安全性

- YAML内の対象パスは展開後の絶対パスに限定する。
- 復元先Gitパスは絶対パスのみ許可する。
- 機密tarの復元前にパスを検査し、絶対パスや`..`によるディレクトリトラバーサルを拒否する。

## 13. 保持方針

`backup.retention_days`を過ぎた次の日付付きファイルをバックアップ後に削除する。

- `.pc-backup/logs/*.log`
- `.pc-backup/changes/*.txt`
- `.pc-backup/manifests/manifest-2*.json`
- `.pc-backup/secrets-history/secrets-2*.tar.gpg`

`manifest-latest.json`と`encrypted-backup.tar.gpg`は常に最新として保持する。Gitの`refs/backup-snapshots/`は現在自動削除しない。通常ファイルの日次・週次スナップショットは実装していない。

## 14. 検証

`verify-backup.sh`は読み取り専用で、次を検証する。

1. 保存先識別子がYAMLと一致すること。
2. `manifest-latest.json`が存在し、JSONとして解析できること。
3. `backup.mode=git-mirror`の全`.git/`が`git fsck --full`に成功すること。
4. 暗号化アーカイブが復号でき、tar一覧を読めること。

通常ファイルのバイト単位ハッシュ照合は現在行わない。

## 15. 復元

### 15.1 モード

```text
--dry-run       復元予定の表示のみ
--all           通常ファイル + Git + 機密情報
--files         通常ファイル
--git           Gitリポジトリ
--secrets       機密情報
--no-secrets    --allから機密情報を除外
--brew          brew bundleを追加実行
--yes           実行前確認を省略
```

オプションを指定しない場合は、通常ファイル、Git、機密情報を対象とする。本番復元は`--yes`がなければ全体確認を表示する。

### 15.2 Git

- `git-mirror`: ミラーを`fsck`後に元パスへcloneし、refs、origin URL、staged/unstaged差分、未追跡ファイルを復元する。
- `git-url`: 記録済みURLからcloneし、HEADの相違を警告する。
- `git-full`: 記録した保存先から元パスへ`rsync`する。
- 復元先が存在するGitリポジトリは上書きせずスキップする。

### 15.3 機密情報

GPG復号後のtarのパスを検査し、HOMEへ展開する。`.ssh`と`.gnupg`が含まれる場合は基本パーミッションを調整する。

機密データからHOMEへ張るシンボリックリンクの再作成はこのツールの対象外である。バックアップ済みの環境構築スクリプを実行して再作成する。

## 16. 依存関係

必須または設定により必要なコマンド:

- macOS標準: Bash 3.2、`rsync`、`tar`、`security`、`launchctl`、`caffeinate`
- Git: `git`
- 暗号化: `gpg`
- YAML: Python 3.8以上、PyYAML 6.x
- LFS: `git-lfs`（LFS利用時）
- Homebrew情報: `brew`（`backup.brew: true`時）

`setup-dependencies.sh`は次の順でPythonを探す。

1. `PC_BACKUP_PYTHON`
2. プロジェクトの`.venv`
3. PATH上のPython 3.8以上
4. Homebrewがあれば確認後にPythonをインストール

Pythonがあればプロジェクト専用`.venv`を作り、`requirements.txt`からPyYAMLを導入する。非対話実行では自動インストールしない。

## 17. Makeコマンド

`make`のみでhelpを表示し、状態を変更しない。`.NOTPARALLEL`により連続処理の並列実行を禁止する。

| ターゲット | 処理 |
|---|---|
| `make setup` | Python/PyYAMLの準備 |
| `make check` | 依存関係の確認のみ |
| `make init` | 保存先の初期化 |
| `make dry-run` | バックアップDry Run |
| `make backup` | `caffeinate -i ./scripts/backup.sh`をそのまま実行 |
| `make verify` | 整合性検証 |
| `make run` | 本番バックアップ → 検証 |
| `make first-backup` | setup → init → Dry Run → 本番 → 検証 |
| `make restore-dry-run` | 全復元のDry Run |
| `make restore` | 全復元（確認あり） |
| `make test` | 統合テスト |
| `make install-schedule` | LaunchAgent登録 |

`make run`は手動運用と同じ`caffeinate -i ./scripts/backup.sh`の後に`./scripts/verify-backup.sh`を実行する。バックアップが失敗した場合は停止し、検証を実行しない。`make first-backup`はDry Run後に停止せず、続けて本番を実行する。目視確認を挟む場合は`make dry-run`と`make run`を分ける。

## 18. 定期実行

`install-launch-agent.sh`が`~/Library/LaunchAgents/com.pc-backup.plist`を生成し、LaunchAgentとしてbootstrapする。`schedule.hour`と`schedule.minute`の時刻に毎日実行する。

- Label: `com.pc-backup`
- 実行対象: `scripts/backup.sh`
- stdout: `~/Library/Logs/pc-backup.log`
- stderr: `~/Library/Logs/pc-backup.err.log`
- PATH: Homebrew prefix、`/usr/local/bin`、macOS標準パス

設定時刻を変えた場合は`make install-schedule`を再実行する。現在のLaunchAgentはバックアップのみを行い、`verify-backup.sh`は自動実行しない。

## 19. テスト

`tests/integration.sh`は実際のHOMEとバックアップ先を変更せず、一時ディレクトリに隔離環境を作る。

テストの実行方法、作成するデータ、アサーション、対象外は[TESTING.md](TESTING.md)を参照する。

検査範囲:

- 不正YAMLの拒否
- 依存関係の確認
- 保存元と保存先の重複拒否
- `files.mirror`と`git.roots`の重複時に、非Git文書をコピーしGit作業ツリーを除外すること
- Git内で明示指定した単一ファイルを保存・復元できること
- Dry Runが保存先へ書き込まないこと
- 通常ファイルのバックアップと復元
- Gitミラーの作成、更新、更新前refsの保存
- URLのみのGitリポジトリ
- unstaged差分と未追跡ファイル
- GPG暗号化、検証、復号
- マニフェストとGit `fsck`
- 復元後のbranchとファイル内容

## 20. 実装ファイル

```text
Makefile
README.md
backup.yaml.example
requirements.txt
scripts/
├── backup.sh
├── restore.sh
├── verify-backup.sh
├── init-backup-destination.sh
├── install-launch-agent.sh
├── setup-dependencies.sh
├── load-config.py
├── git-backup.sh
├── git-restore.sh
├── brewfile-update.sh
└── lib/
    ├── common.sh
    └── config.sh
tests/
├── integration.sh
├── integration.yaml
└── invalid.yaml
```

`backup.yaml`はマシン固有設定でありGit管理対象外。復元できるよう、現在の設定では`backup.yaml`自身を`files.mirror`に含める。

## 21. 現在の制約と運用上の注意

- 通常ファイルの世代スナップショットはない。既定の`rsync_delete: true`では元で削除したファイルもミラーから削除する。
- Git snapshot refsは自動pruneされない。
- `verify-backup.sh`は通常ファイルの全ハッシュを照合しない。
- gitignoreされた未追跡ファイルはGitローカル状態に含まれない。
- 暗号化しても、暗号化ファイルの保存パスやファイル名は見える。
- 定期実行はバックアップのみで、検証は別途実行が必要。
- OneDrive等のFile Provider配下では、ローカル利用可能性、容量、同期完了を別途確認する。
- KeychainはMac故障時に同時に失われる可能性がある。パスフレーズは別系統にも保管する。
- バックアップと復元の統合テストは成功済みだが、実データでの定期的な復元演習も行う。

## 22. 標準運用

### 初回

```bash
make setup
make init
make dry-run
make run
```

Dry Run後に自動で本番へ進んでよい場合は、次の1コマンドでもよい。

```bash
make first-backup
```

### 手動運用

```bash
make run
```

### 定期運用

```bash
make install-schedule
```

定期実行のログを確認し、定期的に`make verify`と復元Dry Runを実行する。

```bash
make verify
make restore-dry-run
```
