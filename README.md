# pc-backup

任意の同期先ディレクトリへ、設定・AI資産を rsync ミラーするツール。

## 構成

```
pc-backup/
  backup.conf.example      # デフォルト（パス一覧含む）→ 先に source
  backup.conf.local        # 必須・gitignore（ROOT / GPG / 上書き）
  scripts/
    backup.sh
    restore.sh
    brewfile-update.sh
    install-launch-agent.sh
```

## バックアップ先

`PC_BACKUP_ROOT` 直下:

```
<PC_BACKUP_ROOT>/
  mirror/
    brew/Brewfile
    ...
    encrypted/secrets-latest.tar.gpg
  logs/
  changes/
```

対象パスは `PC_BACKUP_DIRS` / `FILES` / `SECRETS`（`backup.conf.example`）。
`.local` で同じ配列を定義すれば上書きできる。

## セットアップ

```bash
cd ~/Developer/my/pc-backup
cp backup.conf.example backup.conf.local
# PC_BACKUP_ROOT と PC_BACKUP_GPG_PASS を設定
security add-generic-password -a pc-backup -s pc-backup-gpg -w 'your-passphrase' -U

chmod +x scripts/*.sh
./scripts/backup.sh
./scripts/install-launch-agent.sh
```

## 手動実行

```bash
PC_BACKUP_DRY_RUN=1 ./scripts/backup.sh
./scripts/backup.sh
./scripts/brewfile-update.sh
```

## 復元

conf のパス一覧に従い、ミラーから `$HOME` へ戻す。

```bash
./scripts/restore.sh --dry-run          # 確認のみ
./scripts/restore.sh                    # 対話確認あり
./scripts/restore.sh --yes              # 確認スキップ
./scripts/restore.sh --yes --brew       # Homebrew も bundle
./scripts/restore.sh --yes --no-secrets # 平文ミラーのみ
```

再認証（gh / SSO / MCP 等）と Cursor User Rules（Settings）はファイルでは復元できない。
