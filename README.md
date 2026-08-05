# pc-backup

任意の同期先ディレクトリへ、設定・AI資産を rsync ミラーするツール。

## 構成

```
pc-backup/
  backup.conf.example      # デフォルト（パス一覧含む）→ 先に source
  backup.conf.local        # 必須・gitignore（ROOT / GPG / 上書き）
  scripts/
    backup.sh
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

`MIRROR` は `$PC_BACKUP_ROOT/mirror`。

```bash
# Dotfiles / AI 資産など（必要なものだけ）
rsync -a "$MIRROR"/dotfiles/ ~/
rsync -a "$MIRROR"/cursor/ ~/.cursor/
rsync -a "$MIRROR"/agents/ ~/.agents/
rsync -a "$MIRROR"/exocortex/ ~/.exocortex/
rsync -a "$MIRROR"/claude/ ~/.claude/
rsync -a "$MIRROR"/config/ ~/.config/
ln -sf ~/.cursor/skills ~/.claude/skills

# Secrets
gpg --output /tmp/secrets.tar -d "$MIRROR"/encrypted/secrets-latest.tar.gpg
tar -xf /tmp/secrets.tar -C ~
chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_* 2>/dev/null || true
rm -f /tmp/secrets.tar

# Homebrew
brew bundle --file="$MIRROR"/brew/Brewfile

# 再認証（ファイルでは復元不可）
# gh auth login / AWS SSO / Slack・Atlassian MCP など
```

Cursor User Rules（Settings）は `~/.cursor/rules` とは別なので手動再設定。
