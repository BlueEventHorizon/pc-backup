SHELL := /bin/bash
.DEFAULT_GOAL := help
.NOTPARALLEL:

.PHONY: help setup check init dry-run backup verify run first-backup \
	restore-dry-run restore test install-schedule

help:
	@printf '%s\n' \
	  'pc-backup commands:' \
	  '  make setup            Python/PyYAMLを準備' \
	  '  make check            依存関係と設定・保存先・対象を確認（書き込みなし）' \
	  '  make init             バックアップ先を初期化' \
	  '  make dry-run          保存先との差分を表示（書き込みなし）' \
	  '  make backup           本番バックアップ' \
	  '  make verify           バックアップの整合性を検証' \
	  '  make run              本番バックアップ → 検証' \
	  '  make first-backup     準備 → 初期化 → 確認 → 本番 → 検証' \
	  '  make restore-dry-run  全復元のDry Run' \
	  '  make restore          全復元（実行前に確認あり）' \
	  '  make test             隔離環境で統合テスト' \
	  '  make install-schedule LaunchAgentを登録'

setup:
	./scripts/setup-dependencies.sh

check:
	./scripts/setup-dependencies.sh --check
	PC_BACKUP_CHECK_ONLY=1 ./scripts/backup.sh

init:
	./scripts/init-backup-destination.sh

dry-run:
	PC_BACKUP_DRY_RUN=1 ./scripts/backup.sh

backup:
	caffeinate -i ./scripts/backup.sh

verify:
	./scripts/verify-backup.sh

run: backup verify

first-backup: setup init check backup verify

restore-dry-run:
	./scripts/restore.sh --dry-run --all

restore:
	./scripts/restore.sh --all

test:
	./tests/integration.sh

install-schedule:
	./scripts/install-launch-agent.sh
