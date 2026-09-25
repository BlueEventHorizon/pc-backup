# テスト仕様書

## 1. 目的

`pc-backup`のテストは、実際のHOMEや本番バックアップ先を変更せず、一時ディレクトリ内にMacの縮小環境を作成して検証する。

テストではバックアップ結果の存在だけでなく、元のHOMEを空にした状態から復元し、ファイル内容、Git状態、暗号化データを検査する。

## 2. テストの分類

### 2.1 静的検査

- Bashスクリプトの構文: `bash -n`
- `backup.yaml`と`backup.yaml.example`のスキーマ検証
- `git diff --check`
- `make`がhellpのみを表示すること
- `make -n run`が手動運用と同じコマンド列になること

### 2.2 統合テスト

`tests/integration.sh`が一時HOMEと一時バックアップ先を作り、本物のスクリプトとコマンドを実行する。Git、rsync、tar、GPGはモックに置き換えない。

### 2.3 本番E2E確認

実際のOneDrive、Keychain、LaunchAgent、ユーザーデータ全量の確認は自動統合テストと分ける。本番確認は利用者のmacOSセッションで実行する。

## 3. 実行方法

```bash
make test
```

または直接実行する。

```bash
./tests/integration.sh
```

成功時の最終表示:

```text
Integration test passed.
```

途中のコマンド、比較、検証のいずれかが失敗すると非0で終了する。

## 4. 隔離環境

`mktemp -d`で作る`TEST_ROOT`の下に次を作成する。

```text
<TEST_ROOT>/
├── home/                 # テスト用HOME
├── backup/               # テスト用保存先
├── gnupg/                # テスト用GNUPGHOME
└── url-project-remote.git # URL-only用bare remote
```

テストプロセスに次を渡す。

```text
HOME=<TEST_ROOT>/home
TEST_HOME=<TEST_ROOT>/home
TEST_BACKUP_ROOT=<TEST_ROOT>/backup
PC_BACKUP_CONFIG=tests/integration.yaml
GNUPGHOME=<TEST_ROOT>/gnupg
PC_BACKUP_GPG_PASS=<テスト専用文字列>
```

実際のHOME、GnuPG home、Keychain、本番バックアップ先は使用しない。終了時は`trap`で`TEST_ROOT`を削除する。

## 5. フィクスチャ

### 5.1 通常ファイル

```text
home/Documents/example.txt
home/dev/notes.txt
```

`notes.txt`は`files.mirror`と`git.roots`が重なる`dev`の下に置き、非Gitデータの扱いを検査する。

### 5.2 通常Gitリポジトリ

```text
home/dev/project/
├── .git/
├── tracked.txt           # commit後にunstaged変更
├── untracked.txt         # 未追跡
└── local-config.yaml      # gitignore + files.mirror直接指定
```

### 5.3 未commitリポジトリ

commitがまだ一つもないGitリポジトリも作成する。unborn branchを破損したHEADと誤認せず、未追跡ファイルを保存・復元できることを検査する。

```text
home/dev/unborn-project/
├── .git/
└── local-only.txt        # 未追跡
```

### 5.4 URL-onlyリポジトリ

bare remoteとそのcloneを作り、commitをpushしたcleanな状態にする。

```text
home/dev/url-project/
```

### 5.5 `full`親ディレクトリ

`git.full`にリポジトリ自体ではなく親ディレクトリを設定する。

```text
home/dev/full-container/full-project/
├── .git/
├── tracked.txt
├── .gitignore
└── ignored-local.txt      # gitignore対象だが完全コピー対象
```

### 5.6 機密情報

```text
home/.secret-data/token.txt
```

## 6. 統合テストの処理順序

### 6.1 事前検査

1. `tests/invalid.yaml`をローダーへ渡し、拒否されることを確認する。
2. `setup-dependencies.sh --check`を実行する。
3. 保存元と保存先が同一または親子関係の設定を拒否することを確認する。

### 6.2 初回バックアップ

1. `init-backup-destination.sh`を実行する。
2. `PC_BACKUP_DRY_RUN=1`で`backup.sh`を実行する。
3. Dry Run後に`.pc-backup/`が作られていないことを確認する。
4. 本番モードで`backup.sh`を実行する。
5. `verify-backup.sh`を実行する。

### 6.3 生成物の検査

- `Documents/example.txt`がコピーされている。
- `dev/notes.txt`がコピーされている。
- `dev/project/tracked.txt`が通常コピーされていない。
- `dev/project/.git/`にbare Gitミラーがある。
- `.pc-backup/git-state/dev/project/unstaged.patch`がある。
- `.pc-backup/git-state/dev/project/untracked.tar.gz`がある。
- `dev/project/local-config.yaml`が個別コピーされている。
- 未commitリポジトリのGitミラーと未追跡ファイルの保存データがある。
- URL-onlyの`.repo-info`があり、Gitミラーがない。
- `full-container/full-project/.git/`と`ignored-local.txt`がある。
- `.secret-data/encrypted-backup.tar.gpg`がある。
- Gitミラーが`git fsck --full`に成功する。

### 6.4 更新バックアップ

1. 通常Gitリポジトリの変更をcommitする。
2. 新しいunstaged変更と未追跡ファイルを作る。
3. `backup.sh`を再実行する。
4. `verify-backup.sh`を再実行する。
5. `refs/backup-snapshots/`に更新前refがあることを確認する。
6. 元から削除した通常ファイルと`git-full`ファイルがミラーから削除されていることを確認する。

### 6.5 完全復元

1. 元の`home/`を`source-home/`へ移動する。
2. 新しい空の`home/`を作る。
3. `restore.sh --yes --all`を実行する。
4. 通常文書の内容を比較する。
5. Gitのbranch、tracked内容、unstaged差分、未追跡ファイルを検査する。
6. Git内の個別コピーファイルを検査する。
7. URL-onlyリポジトリの内容を検査する。
8. `full`対象のgitignoreファイルを検査する。
9. 復号した`token.txt`の内容を比較する。

### 6.6 非bare保存先の拒否

1. `dev/project/.git/`のミラーを削除し、復元済みリポジトリの非bare`.git/`をコピーして置き換える（`git-full`から`git-mirror`へ切り替えた後の旧コピーを模擬）。
2. `backup.sh`を実行し、終了コードが0以外であることを確認する。
3. 出力に`existing Git destination is not a bare repository`が含まれることを確認する。
4. 置き換えた`.git/`のrefsが変更されていないことを確認する。

## 7. 成功条件

次をすべて満たした場合だけ成功とする。

- 意図的に失敗させる6.6の`backup.sh`を除き、全スクリプトが終了コード0で完了する。
- 必要な生成物が存在する。
- 保存してはいけないGit作業ツリーが通常コピーされていない。
- Git `fsck`が成功する。
- GPG暗号化アーカイブを復号できる。
- 空のHOMEへ復元した結果が元の内容と一致する。

## 8. 自動テストの対象外

次は隔離統合テストでは検査しない。

- 実際のOneDriveへの書き込みと同期完了
- 実際のユーザーデータ全量
- macOS Keychainからのパスフレーズ取得
- LaunchAgentが指定時刻に起動すること
- Homebrewパッケージの実インストール
- クラウド側のバージョン履歴
- 通常ファイル全件のハッシュ比較

## 9. 本番確認手順

### 9.1 Dry Run

```bash
make dry-run
```

次を目視確認する。

- 読み込まれた保存先
- 通常ファイルの元パスと保存パス
- Gitリポジトリ数
- `git-mirror`、`git-url`、`git-full`、`skip`の判定
- Gitリポジトリが親ディレクトリの通常コピーから除外されること

### 9.2 本番バックアップと検証

```bash
make run
```

実行後に次を確認する。

```text
PC backup complete
Verification complete (0 warning(s))
```

OneDriveの同期状態はFinderまたはOneDriveクライアントで別途確認する。

### 9.3 復元Dry Run

```bash
make restore-dry-run
```

実データの本番復元演習は、上書きリスクを避けるため、別のテストユーザーまたは別ボリュームで計画して実施する。
