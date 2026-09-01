# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-09-01

### Added

- ファイル rsync ミラーバックアップ
- Git プロジェクトのミラー・URL記録・フルコピー対応
- 未コミット状態（staged/unstaged/untracked）の保存
- GPG AES-256 による機密情報の暗号化バックアップ
- Homebrew Brewfile のバックアップ
- 保存先識別子による誤書き込み防止
- 排他ロックによる二重起動防止
- バックアップ→検証の一貫実行（`make run`）
- LaunchAgent によるスケジュール実行対応
- 復元スクリプト（`restore.sh`）
- 統合テスト（`tests/integration.sh`）
