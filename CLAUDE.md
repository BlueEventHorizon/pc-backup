# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

`pc-backup`は、Macのデータを性質別（通常ファイル／Gitプロジェクト／未コミット状態／機密情報／Homebrew環境）に分けてバックアップ・復元するBashツール一式。macOS標準搭載のBash 3.2上で動作させる前提のため、連想配列など新しいBash機能は使わない。

詳細設計は`docs/BACKUP_SYSTEM_PLAN.md`（実装済み仕様の記述、将来構想ではない）、運用手順は`README.md`、テスト仕様は`docs/TESTING.md`を参照。これらのドキュメントと実装がずれた場合は実装を正とし、ドキュメントを更新する。

## よく使うコマンド

```bash
make                  # ヘルプ表示（状態変更なし）
make setup            # Python/PyYAMLの準備
make check            # 依存関係の確認 + PC_BACKUP_CHECK_ONLY=1でbackup.sh（設定・保存先・対象の確認、書き込みなし）
make init             # バックアップ先の初期化（destination.id設定時、初回のみ）
make dry-run          # PC_BACKUP_DRY_RUN=1でbackup.sh（保存先との差分だけ表示、書き込みなし）
make backup           # caffeinate -i ./scripts/backup.sh
make verify           # ./scripts/verify-backup.sh
make run              # backup → verify（backup失敗時はverifyを実行しない）
make first-backup     # setup → init → check → backup → verify
make restore-dry-run  # ./scripts/restore.sh --dry-run --all
make restore          # ./scripts/restore.sh --all（実行前に確認あり）
make test             # ./tests/integration.sh
make install-schedule # LaunchAgent登録
```

`Makefile`は`.NOTPARALLEL`を指定しているため、連続する複数ターゲットの並列実行はできない。

テストは`./tests/integration.sh`を直接実行してもよい。単一のアサーションだけ確認したい場合は、ファイル内の関数名や行番号を直接参照してデバッグする（テストケース単位の実行オプションは無い）。

静的検査は次を個別に実行できる。

```bash
bash -n scripts/*.sh scripts/lib/*.sh   # 構文チェック
python3 scripts/load-config.py backup.yaml.example  # スキーマ検証の動作確認
```

## アーキテクチャ

### 設定の読み込みフロー

```
backup.yaml (YAML)
    → scripts/load-config.py  (PyYAMLでsafe_load、スキーマ検証、shlex.quoteで安全にshell代入文を生成)
    → scripts/lib/config.sh の pc_load_config()  (Pythonの出力をevalしてPC_BACKUP_*変数を展開)
    → 各スクリプトが source
```

- 設定は`backup.yaml`（Git管理外、`backup.yaml.example`がテンプレート）のみサポート。`backup.conf`形式は廃止済み（過去のconf/example方式からの移行が現在の差分に含まれる）。
- `load-config.py`は未知のキー・型・enum値・相対パスを拒否し、`~`と`${HOME}`等の環境変数を展開してから絶対パスとしてshell変数に埋め込む。パスフレーズ自体はYAMLに保存しない。
- 生成される主要変数: `PC_BACKUP_ROOT`, `PC_BACKUP_DESTINATION_ID`, `PC_BACKUP_MIRROR_PATHS`, `PC_BACKUP_GIT_ROOTS`, `PC_BACKUP_GIT_URL_ONLY_PATHS`, `PC_BACKUP_GIT_FULL_PATHS`, `PC_BACKUP_GIT_SKIP_PATHS`, `PC_BACKUP_SECRET_PATHS`, `PC_BACKUP_GIT_DEFAULT_MODE`, `PC_BACKUP_GIT_DIRTY_MODE`など。命名は`PC_BACKUP_*`（設定由来）と`PC_GIT_*`（実行時の一時状態）で区別される。
- Pythonの探索順は `PC_BACKUP_PYTHON` → プロジェクトの`.venv` → `PATH`上のPython 3.8+ → （対話時のみ）Homebrewでインストール。非対話実行（LaunchAgent等）ではPython未整備時に自動インストールせず終了する。

### スクリプトの構成とsourceパターン

各エントリポイントスクリプト（`backup.sh`, `restore.sh`, `verify-backup.sh`, `init-backup-destination.sh`, `install-launch-agent.sh`, `brewfile-update.sh`）は同じ起動パターンに従う。

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/config.sh"
pc_load_config
source "${SCRIPT_DIR}/lib/common.sh"
```

- `scripts/lib/common.sh`: ログ出力（`pc_log`/`pc_warn`/`pc_die`）、パス正規化（`pc_absolute_path`/`pc_storage_rel`/`pc_visible_storage_rel`）、JSON文字列エスケープ、ロック取得/解放（`pc_acquire_lock`/`pc_release_lock`）、保存元/保存先の重複検査など全スクリプト共通のヘルパー。
- `scripts/git-backup.sh`は`backup.sh`から、`scripts/git-restore.sh`は`restore.sh`からsourceされる関数集であり、単独実行はしない。
- Bash 3.2互換を維持すること（`declare -A`等の連想配列や`${var,,}`のような新しい展開は使わない）。

### バックアップ先のレイアウト

保存先は「コピー方式」と「ディレクトリ構成」を分離する設計思想（`docs/BACKUP_SYSTEM_PLAN.md` 3章）。HOME配下のパスはYAMLに書いた相対階層のまま保存先に再現され、`files`/`repositories`/`secrets`のような方式別ディレクトリは作らない。HOME外の絶対パスは`<destination>/_absolute/`以下に配置される。

```
<PC_BACKUP_ROOT>/
├── data/...                # $HOMEをそのまま再現（通常ファイル、Gitミラーの.git/、暗号化アーカイブ）
├── _absolute/               # HOME外を指定した場合
├── .pc-backup-destination   # 保存先識別子（destination.id検証用）
└── .pc-backup/               # 利用者が通常参照しない内部情報
    ├── manifests/            # manifest-latest.json / manifest-<timestamp>.json
    ├── git-state/<repo>/     # staged.patch, unstaged.patch, untracked.tar.gz, status.json
    ├── git-url/, git-full/   # URL-onlyおよびgit-fullの復元メタデータ
    ├── secrets-history/      # 日付付き暗号化アーカイブ
    ├── homebrew/             # Brewfile等
    ├── changes/, logs/, locks/
    └── tool/                 # 復元用のツール一式と実行時の設定（backup.yamlとして保存）
```

### Gitバックアップのモード判定

`git.roots`配下を`find`で探索してリポジトリを検出し（`exclude_names`でprune）、各リポジトリのモードを次の優先順位で決定する（`pc_git_mode_for_repo`, `scripts/git-backup.sh`）。

```
skip（完全一致） > full（完全一致 or 親ディレクトリ配下） > url_only（完全一致） > default_mode
```

- `git-mirror`: `git clone --mirror`で作業ツリーなしのミラーを`<repo>/.git/`へ保存。新規ミラーはローカル（`PC_LOCAL_WORK_DIR`）で作って`fsck`し、検査後に保存先へ置く。2回目以降は、元のrefsがミラーと違うときだけ、更新前refsを`refs/backup-snapshots/<timestamp>/`へ退避してから`fetch`する（同じなら何も書かない、更新時の`fsck`もしない。全体検査は`verify-backup.sh`）。OneDrive等では保存先の読み戻しが遅いため、この設計を崩さないこと。
- `git-url`: リモートURL・HEAD・branchのみ記録。remote URLがある／unpushedコミットなし／upstreamのないローカルブランチなし／stashなし、の全条件を満たさない場合は自動的に`git-mirror`へ昇格する（データ損失防止のための安全側フォールバック）。作業ツリーの変更は`dirty_mode: backup`なら`git-state/`の差分として保存されるので昇格理由にならない（`warn`のときは昇格）。復元はcloneのあと記録したbranch/HEADへ切り替えて差分を適用する。
- `git-url`が確定したリポジトリの保存先に、以前の`git-mirror`が残っている場合は、確認のうえで削除する（復元は`.git`ミラーを`git-url`より先にcloneするため、古いミラーが優先されてしまう）。非対話実行では削除せず警告のみ。
- `git-full`: 作業ツリーを含めて`rsync`。
- `dirty_mode`（`backup`/`warn`/`fail`）: staged/unstaged差分と未追跡ファイル（gitignore対象は含まない）の扱いを決める。`.env`など秘密情報の追跡除外ファイルは`secrets.paths`へ明示的に含める必要がある。

`files.mirror`と`git.roots`が重なる場合、検出済みGitリポジトリのパスは通常のrsyncから自動的に除外され（Gitモードに委譲）、リポジトリ間の非Gitファイルのみ通常コピーされる。この境界判定は`backup.sh`の`pc_rsync_item`と復元側で対応関係を保つ。

### 安全機構（変更時に壊さないよう注意）

- **排他制御**: `.pc-backup/locks/backup.lock/`を`mkdir`で原子的に作成し、二重起動を防止（checkとDry Runではロックしない）。
- **保存先識別子**: `destination.id`設定時、`init-backup-destination.sh`が`.pc-backup-destination`を作成。以後全操作でYAMLの値と一致するか検証し、不一致なら停止（外付けディスク未接続時の誤書き込み防止）。
- **保存元/保存先の重複防止**: シンボリックリンク解決後の物理パスで、`files.mirror`/`git.roots`/`secrets.paths`のいずれかが保存先と重なる場合は開始前に停止。
- **アトミックな更新**: Gitミラー初回作成、暗号化アーカイブのlatest、マニフェストのlatestはいずれも一時パスへ書いてから`mv`。
- **アーカイブの安全性**: 復元前に機密tarの内部パスを検査し、絶対パスや`..`によるディレクトリトラバーサルを拒否（`pc_tar_is_safe`）。

### 復元

`restore.sh`は`--all`/`--files`/`--git`/`--secrets`/`--no-secrets`/`--brew`/`--dry-run`/`--yes`を受け付ける。復元順は機密情報 → 通常ファイル → Gitで固定（`git-url`のcloneにSSH鍵などが要るため。順序を変えないこと）。Gitはリポジトリ単位の失敗（clone等）を`pc_restore_fail`で記録して続行し、最後に一覧表示して終了コード1で終わる（`pc_die`で全体を止めない）。既存の復元先があるGitリポジトリは上書きせずスキップする。新しいMacでは`.pc-backup/tool/`をローカルへコピーし、同梱の`backup.yaml`で実行する（`backup.sh`の`pc_backup_tool_bundle`が毎回更新）。

### テスト

`tests/integration.sh`は`mktemp -d`で一時HOME・一時バックアップ先・一時GNUPGHOMEを作り、実際のスクリプトとコマンド（Git/rsync/tar/GPG、モックなし）を実行して、バックアップ→更新バックアップ→完全復元までの一連の流れを検証する。実際のHOME・本番バックアップ先・macOS Keychain・LaunchAgentは変更しない。テスト用YAMLは`tests/integration.yaml`、不正設定の拒否確認には`tests/invalid.yaml`を使う。カバー範囲・対象外項目は`docs/TESTING.md`を参照。

## 設定ファイル

- `backup.yaml`: 実際の設定（Git管理外、マシン固有）。`backup.yaml.example`をコピーして作成する。
- 暗号化パスフレーズはYAMLに書かず、macOS Keychain（`security add-generic-password`）に登録する。LaunchAgentなど対話端末のない実行では、Keychain登録が必須。
