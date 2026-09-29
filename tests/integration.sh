#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pc-backup-test.XXXXXX")
export TEST_HOME="${TEST_ROOT}/home"
export TEST_BACKUP_ROOT="${TEST_ROOT}/backup"
export PC_BACKUP_CONFIG="${PROJECT_ROOT}/tests/integration.yaml"
export PC_BACKUP_GPG_PASS="integration-test-passphrase"
export GNUPGHOME="${TEST_ROOT}/gnupg"
TEST_PYTHON="${PROJECT_ROOT}/.venv/bin/python"
[[ -x "${TEST_PYTHON}" ]] || TEST_PYTHON="python3"

cleanup() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

if "${TEST_PYTHON}" "${PROJECT_ROOT}/scripts/load-config.py" \
  "${PROJECT_ROOT}/tests/invalid.yaml" >/dev/null 2>&1; then
  fail "invalid YAML configuration was accepted"
fi
"${PROJECT_ROOT}/scripts/setup-dependencies.sh" --check >/dev/null

mkdir -p "${TEST_HOME}/Documents" "${TEST_HOME}/dev/project" "${TEST_HOME}/.secret-data" "${GNUPGHOME}"
chmod 700 "${GNUPGHOME}"
printf 'document data\n' > "${TEST_HOME}/Documents/example.txt"
printf 'remove after initial backup\n' > "${TEST_HOME}/Documents/deleted-after-first.txt"
printf 'secret data\n' > "${TEST_HOME}/.secret-data/token.txt"
"${TEST_PYTHON}" -c 'import socket, sys; sock = socket.socket(socket.AF_UNIX); sock.bind(sys.argv[1]); sock.close()' \
  "${TEST_HOME}/.secret-data/agent.sock"

git -C "${TEST_HOME}/dev/project" init -q
git -C "${TEST_HOME}/dev/project" config user.name "PC Backup Test"
git -C "${TEST_HOME}/dev/project" config user.email "pc-backup@example.invalid"
git -C "${TEST_HOME}/dev/project" config commit.gpgsign false
printf 'base\n' > "${TEST_HOME}/dev/project/tracked.txt"
git -C "${TEST_HOME}/dev/project" add tracked.txt
git -C "${TEST_HOME}/dev/project" commit -qm "initial"
git -C "${TEST_HOME}/dev/project" branch -M main
printf 'local change\n' >> "${TEST_HOME}/dev/project/tracked.txt"
printf 'untracked\n' > "${TEST_HOME}/dev/project/untracked.txt"
printf 'local config\n' > "${TEST_HOME}/dev/project/local-config.yaml"
printf 'local-config.yaml\n' >> "${TEST_HOME}/dev/project/.git/info/exclude"
printf 'non-git document\n' > "${TEST_HOME}/dev/notes.txt"

# Linked worktrees share the main repository's object store. Each backup
# mirror must remain independently readable when several of them are updated
# and verified in succession.
mkdir -p "${TEST_HOME}/dev/worktree-main"
git -C "${TEST_HOME}/dev/worktree-main" init -q
git -C "${TEST_HOME}/dev/worktree-main" config user.name "PC Backup Test"
git -C "${TEST_HOME}/dev/worktree-main" config user.email "pc-backup@example.invalid"
git -C "${TEST_HOME}/dev/worktree-main" config commit.gpgsign false
printf 'worktree base\n' > "${TEST_HOME}/dev/worktree-main/tracked.txt"
git -C "${TEST_HOME}/dev/worktree-main" add tracked.txt
git -C "${TEST_HOME}/dev/worktree-main" commit -qm "worktree initial"
git -C "${TEST_HOME}/dev/worktree-main" worktree add -qb linked \
  "${TEST_HOME}/dev/worktree-linked"

# A newly initialized repository has an unborn branch and no HEAD commit. Its
# untracked files must still be backed up and restored.
mkdir -p "${TEST_HOME}/dev/unborn-project"
git -C "${TEST_HOME}/dev/unborn-project" init -q
printf 'unborn local data\n' > "${TEST_HOME}/dev/unborn-project/local-only.txt"

git init -q --bare "${TEST_ROOT}/url-project-remote.git"
git clone -q "${TEST_ROOT}/url-project-remote.git" "${TEST_HOME}/dev/url-project"
git -C "${TEST_HOME}/dev/url-project" config user.name "PC Backup Test"
git -C "${TEST_HOME}/dev/url-project" config user.email "pc-backup@example.invalid"
git -C "${TEST_HOME}/dev/url-project" config commit.gpgsign false
printf 'remote-backed\n' > "${TEST_HOME}/dev/url-project/README.md"
git -C "${TEST_HOME}/dev/url-project" add README.md
git -C "${TEST_HOME}/dev/url-project" commit -qm "initial remote-backed project"
git -C "${TEST_HOME}/dev/url-project" branch -M main
git -C "${TEST_HOME}/dev/url-project" push -qu origin main
git -C "${TEST_ROOT}/url-project-remote.git" symbolic-ref HEAD refs/heads/main

# A full rule may name a parent directory containing repositories.
mkdir -p "${TEST_HOME}/dev/full-container/full-project"
git -C "${TEST_HOME}/dev/full-container/full-project" init -q
git -C "${TEST_HOME}/dev/full-container/full-project" config user.name "PC Backup Test"
git -C "${TEST_HOME}/dev/full-container/full-project" config user.email "pc-backup@example.invalid"
git -C "${TEST_HOME}/dev/full-container/full-project" config commit.gpgsign false
printf 'full tracked\n' > "${TEST_HOME}/dev/full-container/full-project/tracked.txt"
printf 'ignored-local.txt\n' > "${TEST_HOME}/dev/full-container/full-project/.gitignore"
git -C "${TEST_HOME}/dev/full-container/full-project" add tracked.txt .gitignore
git -C "${TEST_HOME}/dev/full-container/full-project" commit -qm "initial full project"
printf 'full ignored local data\n' > "${TEST_HOME}/dev/full-container/full-project/ignored-local.txt"
printf 'remove full data after initial backup\n' \
  > "${TEST_HOME}/dev/full-container/full-project/deleted-after-first.txt"

HOME="${TEST_HOME}" "${PROJECT_ROOT}/scripts/init-backup-destination.sh"

# A source equal to, above or below the destination must be rejected to avoid
# recursively backing up the backup itself.
if bash -c 'source "$1"; PC_BACKUP_ROOT="$2"; pc_validate_source_destination_separation test "$3"' \
  _ "${PROJECT_ROOT}/scripts/lib/common.sh" "${TEST_BACKUP_ROOT}" "${TEST_ROOT}" \
  >/dev/null 2>&1; then
  fail "source/destination overlap was accepted"
fi

# make check validates and lists targets without comparing or writing.
check_output="${TEST_ROOT}/check.log"
PC_BACKUP_CHECK_ONLY=1 HOME="${TEST_HOME}" "${PROJECT_ROOT}/scripts/backup.sh" >"${check_output}"
[[ ! -e "${TEST_BACKUP_ROOT}/.pc-backup" ]] || fail "check wrote backup metadata"
grep -q '/Documents -> Documents$' "${check_output}" \
  || fail "check did not list regular file targets"
grep -q 'example.txt' "${check_output}" && fail "check unexpectedly listed file differences"

# make dry-run compares with the (still empty) destination without writing.
dry_run_output="${TEST_ROOT}/dry-run-initial.log"
PC_BACKUP_DRY_RUN=1 HOME="${TEST_HOME}" "${PROJECT_ROOT}/scripts/backup.sh" >"${dry_run_output}"
[[ ! -e "${TEST_BACKUP_ROOT}/.pc-backup" ]] || fail "dry-run wrote backup metadata"
[[ ! -e "${TEST_BACKUP_ROOT}/Documents" ]] || fail "dry-run copied regular files"
grep -q '>f+++++++++ example.txt' "${dry_run_output}" \
  || fail "dry-run did not show a new regular file"
grep -q 'would create Git mirror: .*/dev/project -> ' "${dry_run_output}" \
  || fail "dry-run did not show a new Git mirror"
grep -q 'Git full rsync: .*full-project' "${dry_run_output}" \
  || fail "dry-run did not show a new git-full copy"
HOME="${TEST_HOME}" "${PROJECT_ROOT}/scripts/backup.sh"
HOME="${TEST_HOME}" "${PROJECT_ROOT}/scripts/verify-backup.sh"

mirror="${TEST_BACKUP_ROOT}/dev/project/.git"
state="${TEST_BACKUP_ROOT}/.pc-backup/git-state/dev/project"
[[ -d "${mirror}" ]] || fail "Git mirror was not created"
[[ -f "${state}/unstaged.patch" ]] || fail "unstaged patch was not created"
[[ -f "${state}/untracked.tar.gz" ]] || fail "untracked archive was not created"
[[ -f "${TEST_BACKUP_ROOT}/Documents/example.txt" ]] \
  || fail "regular file was not copied"
[[ -f "${TEST_BACKUP_ROOT}/dev/notes.txt" ]] \
  || fail "non-Git file below overlapping files/git roots was not copied"
[[ ! -f "${TEST_BACKUP_ROOT}/dev/project/tracked.txt" ]] \
  || fail "Git checkout was copied by the overlapping regular mirror"
[[ -f "${TEST_BACKUP_ROOT}/dev/project/local-config.yaml" ]] \
  || fail "explicit regular file inside a Git repository was not copied"
[[ -d "${TEST_BACKUP_ROOT}/dev/unborn-project/.git" ]] \
  || fail "unborn Git repository mirror was not created"
[[ -f "${TEST_BACKUP_ROOT}/.pc-backup/git-state/dev/unborn-project/untracked.tar.gz" ]] \
  || fail "unborn Git repository files were not captured"
[[ -d "${TEST_BACKUP_ROOT}/dev/worktree-linked/.git" ]] \
  || fail "linked worktree Git mirror was not created"
[[ -f "${TEST_BACKUP_ROOT}/.secret-data/encrypted-backup.tar.gpg" ]] \
  || fail "encrypted secrets archive was not created"
[[ -f "${TEST_BACKUP_ROOT}/.pc-backup/git-url/dev/url-project.repo-info" ]] \
  || fail "URL-only repository metadata was not created"
[[ ! -d "${TEST_BACKUP_ROOT}/dev/url-project/.git" ]] \
  || fail "URL-only repository was unexpectedly mirrored"
[[ -d "${TEST_BACKUP_ROOT}/dev/full-container/full-project/.git" ]] \
  || fail "full repository below configured parent was not copied"
[[ -f "${TEST_BACKUP_ROOT}/dev/full-container/full-project/ignored-local.txt" ]] \
  || fail "ignored file in full repository was not copied"
tool_bundle="${TEST_BACKUP_ROOT}/.pc-backup/tool"
for bundled in Makefile requirements.txt scripts/restore.sh scripts/lib/config.sh scripts/load-config.py; do
  [[ -f "${tool_bundle}/${bundled}" ]] || fail "tool bundle is missing ${bundled}"
done
cmp -s "${PC_BACKUP_CONFIG}" "${tool_bundle}/backup.yaml" \
  || fail "active configuration was not bundled as backup.yaml"
[[ ! -e "${tool_bundle}/.venv" && ! -e "${tool_bundle}/.git" && ! -e "${tool_bundle}/tests" ]] \
  || fail "tool bundle contains local-only project files"
git -C "${mirror}" fsck --full >/dev/null
git -C "${TEST_BACKUP_ROOT}/dev/worktree-main/.git" fsck --full >/dev/null
git -C "${TEST_BACKUP_ROOT}/dev/worktree-linked/.git" fsck --full >/dev/null

# make check must not read Git mirrors in the destination (they can block on
# OneDrive-style storage). An unreadable mirror must not change its result.
chmod 000 "${mirror}"
check_output="${TEST_ROOT}/check-unreadable.log"
check_rc=0
PC_BACKUP_CHECK_ONLY=1 HOME="${TEST_HOME}" "${PROJECT_ROOT}/scripts/backup.sh" >"${check_output}" 2>&1 || check_rc=$?
chmod 755 "${mirror}"
[[ ${check_rc} -eq 0 ]] || fail "check failed while a destination mirror was unreadable"
grep -q 'non-bare' "${check_output}" && fail "check inspected a destination Git mirror"

# Right after a backup, targets without changes are not shown by dry-run.
dry_run_output="${TEST_ROOT}/dry-run-current.log"
PC_BACKUP_DRY_RUN=1 HOME="${TEST_HOME}" "${PROJECT_ROOT}/scripts/backup.sh" >"${dry_run_output}"
grep -q 'rsync: ' "${dry_run_output}" && fail "dry-run showed unchanged regular files"
grep -q 'Git mirror: ' "${dry_run_output}" && fail "dry-run showed unchanged Git mirrors"
grep -q 'Git full rsync: ' "${dry_run_output}" && fail "dry-run showed an unchanged git-full copy"
grep -q 'Git URL inventory' "${dry_run_output}" && fail "dry-run showed unchanged URL-only metadata"

# Simulate stale derived metadata left by an interrupted/background maintenance
# run. The next backup must rebuild it from this mirror's reachable commits.
git -C "${TEST_HOME}/dev/worktree-main" commit-graph write --reachable
cp "${TEST_HOME}/dev/worktree-main/.git/objects/info/commit-graph" \
  "${mirror}/objects/info/commit-graph"
if git -C "${mirror}" commit-graph verify >/dev/null 2>&1; then
  fail "foreign commit graph was unexpectedly valid"
fi

# Exercise an update of an existing mirror and preservation of pre-update refs.
git -C "${TEST_HOME}/dev/project" add tracked.txt untracked.txt
git -C "${TEST_HOME}/dev/project" commit -qm "local committed state"
printf 'second local change\n' >> "${TEST_HOME}/dev/project/tracked.txt"
printf 'second untracked\n' > "${TEST_HOME}/dev/project/untracked-second.txt"
rm "${TEST_HOME}/Documents/deleted-after-first.txt"
rm "${TEST_HOME}/dev/full-container/full-project/deleted-after-first.txt"

# dry-run shows exactly the pending changes and leaves the backup untouched.
dry_run_output="${TEST_ROOT}/dry-run-changed.log"
manifest_before=$(cksum < "${TEST_BACKUP_ROOT}/.pc-backup/manifests/manifest-latest.json")
refs_before=$(git -C "${mirror}" for-each-ref | cksum)
PC_BACKUP_DRY_RUN=1 HOME="${TEST_HOME}" "${PROJECT_ROOT}/scripts/backup.sh" >"${dry_run_output}"
grep -qF '/Documents -> Documents (1 change(s))' "${dry_run_output}" \
  || fail "dry-run did not summarize regular file changes"
grep -q '\*deleting *deleted-after-first.txt' "${dry_run_output}" \
  || fail "dry-run did not show a regular file deletion"
grep -q 'update refs/heads/main' "${dry_run_output}" \
  || fail "dry-run did not show an updated Git ref"
grep -q 'deleting *deleted-after-first.txt' <(grep -A20 'Git full rsync' "${dry_run_output}") \
  || fail "dry-run did not show a git-full deletion"
grep -q 'worktree-main' "${dry_run_output}" && fail "dry-run showed an unchanged repository"
[[ "$(cksum < "${TEST_BACKUP_ROOT}/.pc-backup/manifests/manifest-latest.json")" == "${manifest_before}" ]] \
  || fail "dry-run updated the manifest"
[[ "$(git -C "${mirror}" for-each-ref | cksum)" == "${refs_before}" ]] \
  || fail "dry-run updated Git mirror refs"
[[ -e "${TEST_BACKUP_ROOT}/Documents/deleted-after-first.txt" ]] \
  || fail "dry-run deleted a regular file from the backup"

HOME="${TEST_HOME}" "${PROJECT_ROOT}/scripts/backup.sh"
HOME="${TEST_HOME}" "${PROJECT_ROOT}/scripts/verify-backup.sh"
snapshot_count=$(git -C "${mirror}" for-each-ref --count=1 refs/backup-snapshots | wc -l | tr -d ' ')
[[ "${snapshot_count}" -gt 0 ]] || fail "pre-update Git refs were not preserved"
[[ ! -e "${TEST_BACKUP_ROOT}/Documents/deleted-after-first.txt" ]] \
  || fail "deleted regular file remained in backup"
[[ ! -e "${TEST_BACKUP_ROOT}/dev/full-container/full-project/deleted-after-first.txt" ]] \
  || fail "deleted git-full file remained in backup"

# Restore as on a new Mac: copy the tool bundle out of the backup and run it
# with its bundled backup.yaml instead of this checkout's scripts/config.
mv "${TEST_HOME}" "${TEST_ROOT}/source-home"
mkdir -p "${TEST_HOME}"
cp -R "${tool_bundle}" "${TEST_ROOT}/restored-tool"
restore_output="${TEST_ROOT}/restore.log"
env -u PC_BACKUP_CONFIG PC_BACKUP_PYTHON="${TEST_PYTHON}" HOME="${TEST_HOME}" \
  "${TEST_ROOT}/restored-tool/scripts/restore.sh" --yes --all | tee "${restore_output}"

# Secrets are restored before files, and files before Git, so that git-url
# clones can use the restored SSH keys.
secrets_line=$(grep -n 'Decrypting secrets archive' "${restore_output}" | head -1 | cut -d: -f1)
files_line=$(grep -n 'rsync restore: ' "${restore_output}" | head -1 | cut -d: -f1)
git_line=$(grep -n 'Git restore: \|Git URL restore: ' "${restore_output}" | head -1 | cut -d: -f1)
[[ -n "${secrets_line}" && -n "${files_line}" && -n "${git_line}" ]] \
  || fail "restore log is missing a secrets, files or Git step"
[[ "${secrets_line}" -lt "${files_line}" && "${files_line}" -lt "${git_line}" ]] \
  || fail "restore order is not secrets, files, Git"

[[ "$(cat "${TEST_HOME}/Documents/example.txt")" == "document data" ]] \
  || fail "regular file restore differs"
[[ "$(cat "${TEST_HOME}/dev/notes.txt")" == "non-git document" ]] \
  || fail "non-Git file below overlapping roots was not restored"
[[ "$(cat "${TEST_HOME}/dev/project/local-config.yaml")" == "local config" ]] \
  || fail "explicit regular file inside Git repository was not restored"
[[ "$(cat "${TEST_HOME}/dev/full-container/full-project/ignored-local.txt")" == "full ignored local data" ]] \
  || fail "full repository below configured parent was not restored"
grep -q 'local change' "${TEST_HOME}/dev/project/tracked.txt" \
  || fail "unstaged change was not restored"
grep -q 'second local change' "${TEST_HOME}/dev/project/tracked.txt" \
  || fail "latest unstaged change was not restored"
[[ "$(cat "${TEST_HOME}/dev/project/untracked.txt")" == "untracked" ]] \
  || fail "untracked file was not restored"
[[ "$(cat "${TEST_HOME}/dev/project/untracked-second.txt")" == "second untracked" ]] \
  || fail "latest untracked file was not restored"
[[ "$(cat "${TEST_HOME}/dev/unborn-project/local-only.txt")" == "unborn local data" ]] \
  || fail "unborn Git repository files were not restored"
git -C "${TEST_HOME}/dev/unborn-project" rev-parse --verify --quiet HEAD >/dev/null 2>&1 \
  && fail "restored unborn Git repository unexpectedly has a commit"
[[ "$(cat "${TEST_HOME}/.secret-data/token.txt")" == "secret data" ]] \
  || fail "encrypted secret was not restored"
[[ ! -e "${TEST_HOME}/.secret-data/agent.sock" ]] \
  || fail "Unix socket from secret data was unexpectedly restored"
[[ "$(git -C "${TEST_HOME}/dev/project" branch --show-current)" == "main" ]] \
  || fail "Git branch was not restored"
[[ "$(cat "${TEST_HOME}/dev/url-project/README.md")" == "remote-backed" ]] \
  || fail "URL-only repository was not restored"

# A failing git clone (here: the remote of the URL-only repository is gone)
# must not stop the remaining repositories. The restore lists the failure and
# exits non-zero; repositories restored before and after it are intact.
mv "${TEST_HOME}" "${TEST_ROOT}/restored-home"
mkdir -p "${TEST_HOME}"
mv "${TEST_ROOT}/url-project-remote.git" "${TEST_ROOT}/url-project-remote.git.away"
partial_output="${TEST_ROOT}/restore-partial.log"
if env -u PC_BACKUP_CONFIG PC_BACKUP_PYTHON="${TEST_PYTHON}" HOME="${TEST_HOME}" \
  "${TEST_ROOT}/restored-tool/scripts/restore.sh" --yes --all >"${partial_output}" 2>&1; then
  fail "restore succeeded although a Git clone failed"
fi
grep -q 'ERROR: Git clone failed: .*url-project' "${partial_output}" \
  || fail "failed Git clone was not reported"
grep -q '  failed: Git clone failed: .*url-project' "${partial_output}" \
  || fail "restore did not list the failed item at the end"
[[ "$(git -C "${TEST_HOME}/dev/project" branch --show-current)" == "main" ]] \
  || fail "repository restored before the failed clone is missing"
[[ "$(cat "${TEST_HOME}/dev/full-container/full-project/ignored-local.txt")" == "full ignored local data" ]] \
  || fail "git-full repository after the failed clone was not restored"
[[ ! -e "${TEST_HOME}/dev/url-project" ]] || fail "failed clone left a directory behind"
rm -rf -- "${TEST_HOME}"
mv "${TEST_ROOT}/restored-home" "${TEST_HOME}"
mv "${TEST_ROOT}/url-project-remote.git.away" "${TEST_ROOT}/url-project-remote.git"

# Copies left at mirror destinations after switching from git-full to
# git-mirror must not receive mirror refs. Without confirmation the backup
# fails and leaves them untouched; with confirmation they are replaced by new
# mirrors while explicit files.mirror entries inside the repository are kept.
project_copy="${TEST_BACKUP_ROOT}/dev/project"
linked_copy="${TEST_BACKUP_ROOT}/dev/worktree-linked"
stale_full_info="${TEST_BACKUP_ROOT}/.pc-backup/git-full/dev/project.repo-info"
rm -rf "${project_copy}" "${linked_copy}"
cp -R "${TEST_HOME}/dev/project" "${project_copy}"
mkdir -p "${linked_copy}" "$(dirname -- "${stale_full_info}")"
printf 'gitdir: /nonexistent/worktrees/linked\n' > "${linked_copy}/.git"
printf 'stale\n' > "${stale_full_info}"
nonbare_refs_before=$(git -C "${mirror}" for-each-ref | cksum)
nonbare_output="${TEST_ROOT}/nonbare-backup.log"
if HOME="${TEST_HOME}" "${PROJECT_ROOT}/scripts/backup.sh" \
  </dev/null >"${nonbare_output}" 2>&1; then
  fail "backup succeeded over a non-bare Git destination"
fi
[[ "$(grep -c 'existing Git destination is not a bare repository' "${nonbare_output}")" -eq 2 ]] \
  || fail "non-bare Git destinations were not reported"
[[ "$(git -C "${mirror}" for-each-ref | cksum)" == "${nonbare_refs_before}" ]] \
  || fail "non-bare Git destination refs were modified"
[[ -f "${linked_copy}/.git" ]] || fail "unconfirmed .git file destination was modified"

PC_BACKUP_ASSUME_YES=1 HOME="${TEST_HOME}" "${PROJECT_ROOT}/scripts/backup.sh" </dev/null
HOME="${TEST_HOME}" "${PROJECT_ROOT}/scripts/verify-backup.sh"
[[ "$(git -C "${mirror}" rev-parse --is-bare-repository)" == "true" ]] \
  || fail "non-bare Git destination was not replaced by a mirror"
[[ "$(git -C "${linked_copy}/.git" rev-parse --is-bare-repository)" == "true" ]] \
  || fail ".git file destination was not replaced by a mirror"
[[ ! -e "${project_copy}/tracked.txt" ]] \
  || fail "working tree of the replaced copy remained"
[[ "$(cat "${project_copy}/local-config.yaml")" == "local config" ]] \
  || fail "explicit file inside the replaced copy was not kept"
[[ ! -e "${stale_full_info}" ]] || fail "stale git-full metadata remained"
compgen -G "${TEST_BACKUP_ROOT}/.pc-backup/.git-replace.*" >/dev/null \
  && fail "temporary replacement directory remained"

printf 'Integration test passed.\n'
