#!/usr/bin/env bash

# Git backup functions. This file is sourced by backup.sh.

pc_git_mode_for_repo() {
  local repo="$1"
  if pc_contains_path "${repo}" "${PC_BACKUP_GIT_SKIP_PATHS[@]}"; then
    printf 'skip\n'
  elif pc_path_is_equal_or_below_any "${repo}" "${PC_BACKUP_GIT_FULL_PATHS[@]}"; then
    printf 'git-full\n'
  elif pc_contains_path "${repo}" "${PC_BACKUP_GIT_URL_ONLY_PATHS[@]}"; then
    printf 'git-url\n'
  else
    printf '%s\n' "${PC_BACKUP_GIT_DEFAULT_MODE:-git-mirror}"
  fi
}

pc_git_origin_url() {
  local repo="$1" remote
  if git -C "${repo}" remote get-url origin 2>/dev/null; then
    return 0
  fi
  remote=$(git -C "${repo}" remote 2>/dev/null | sed -n '1p')
  [[ -n "${remote}" ]] && git -C "${repo}" remote get-url "${remote}" 2>/dev/null || true
}

pc_git_count_nul() {
  tr -cd '\000' | wc -c | tr -d ' '
}

pc_git_inspect_state() {
  local repo="$1"
  PC_GIT_STAGED=false
  PC_GIT_UNSTAGED=false
  git -C "${repo}" diff --cached --quiet --ignore-submodules -- || PC_GIT_STAGED=true
  git -C "${repo}" diff --quiet --ignore-submodules -- || PC_GIT_UNSTAGED=true
  PC_GIT_UNTRACKED_COUNT=$(git -C "${repo}" ls-files --others --exclude-standard -z | pc_git_count_nul)
  PC_GIT_STASH_COUNT=$(git -C "${repo}" stash list 2>/dev/null | wc -l | tr -d ' ')
}

pc_git_store_state() {
  local repo="$1" state_dir="$2" capture_files="$3"
  local tmp_parent tmp_dir list_file previous

  tmp_parent=$(dirname -- "${state_dir}")
  mkdir -p "${tmp_parent}"
  tmp_dir=$(mktemp -d "${tmp_parent}/.git-state.XXXXXX")

  if [[ "${capture_files}" == "1" && "${PC_GIT_STAGED}" == "true" ]]; then
    git -C "${repo}" diff --cached --binary --full-index > "${tmp_dir}/staged.patch"
  fi
  if [[ "${capture_files}" == "1" && "${PC_GIT_UNSTAGED}" == "true" ]]; then
    git -C "${repo}" diff --binary --full-index > "${tmp_dir}/unstaged.patch"
  fi
  if [[ "${capture_files}" == "1" && "${PC_GIT_UNTRACKED_COUNT}" -gt 0 ]]; then
    list_file="${tmp_dir}/untracked.list"
    git -C "${repo}" ls-files --others --exclude-standard -z > "${list_file}"
    tar -czf "${tmp_dir}/untracked.tar.gz" -C "${repo}" --null -T "${list_file}"
    rm -f "${list_file}"
  fi

  {
    printf '{"staged":%s,"unstaged":%s,"untracked_count":%s,"stash_count":%s,"timestamp":' \
      "${PC_GIT_STAGED}" "${PC_GIT_UNSTAGED}" "${PC_GIT_UNTRACKED_COUNT}" "${PC_GIT_STASH_COUNT}"
    pc_json_string "$(pc_iso_time)"
    printf '}\n'
  } > "${tmp_dir}/status.json"

  previous="${state_dir}.previous.$$"
  if [[ -d "${state_dir}" ]]; then
    mv "${state_dir}" "${previous}"
  fi
  mv "${tmp_dir}" "${state_dir}"
  [[ ! -d "${previous}" ]] || rm -rf "${previous}"
}

pc_git_branch_safety() {
  local repo="$1" branch upstream ahead
  PC_GIT_AHEAD_COUNT=0
  PC_GIT_LOCAL_BRANCH_COUNT=0
  while IFS=$'\t' read -r branch upstream; do
    [[ -n "${branch}" ]] || continue
    if [[ -z "${upstream}" ]]; then
      PC_GIT_LOCAL_BRANCH_COUNT=$((PC_GIT_LOCAL_BRANCH_COUNT + 1))
      continue
    fi
    ahead=$(git -C "${repo}" rev-list --count "${upstream}..${branch}" 2>/dev/null || printf '1')
    PC_GIT_AHEAD_COUNT=$((PC_GIT_AHEAD_COUNT + ahead))
  done < <(git -C "${repo}" for-each-ref --format='%(refname:short)%09%(upstream:short)' refs/heads)
}

pc_git_snapshot_refs() {
  local mirror="$1" timestamp="$2" object ref suffix
  while IFS=' ' read -r object ref; do
    [[ -n "${object}" && -n "${ref}" ]] || continue
    suffix="${ref#refs/}"
    git -C "${mirror}" update-ref "refs/backup-snapshots/${timestamp}/${suffix}" "${object}"
  done < <(git -C "${mirror}" for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags refs/stash)
}

pc_git_repair_commit_graph() {
  local mirror="$1"
  if git -C "${mirror}" commit-graph verify >/dev/null 2>&1; then
    return 0
  fi
  pc_log "Git mirror: rebuilding stale commit graph: ${mirror#${PC_BACKUP_ROOT}/}"
  # Commit graphs are derived metadata. Remove the invalid monolithic or split
  # graph first so Git does not consult it while walking reachable commits.
  rm -f -- "${mirror}/objects/info/commit-graph"
  rm -rf -- "${mirror}/objects/info/commit-graphs"
  git -C "${mirror}" commit-graph write --reachable
}

pc_git_copy_local_lfs() {
  local repo="$1" mirror="$2" source_lfs
  [[ "${PC_BACKUP_GIT_LFS_MODE:-local}" != "skip" ]] || return 0
  source_lfs=$(git -C "${repo}" rev-parse --git-path lfs/objects 2>/dev/null || true)
  [[ -n "${source_lfs}" ]] || return 0
  if [[ "${source_lfs}" != /* ]]; then
    source_lfs="${repo}/${source_lfs}"
  fi
  [[ -d "${source_lfs}" ]] || return 0
  if [[ "${PC_BACKUP_GIT_LFS_MODE:-local}" == "warn" ]]; then
    pc_warn "Git LFS objects detected but not copied: ${repo}"
    return 0
  fi
  mkdir -p "${mirror}/lfs/objects"
  rsync -a "${source_lfs}/" "${mirror}/lfs/objects/"
}

# True when a source ref is missing from the mirror or points elsewhere, i.e.
# a fetch would change something. Refs that exist only in the mirror (deleted
# branches, snapshots) do not count: fetch never removes them. Any failure to
# list refs counts as "needs fetch" so an unreadable mirror is never skipped.
pc_git_mirror_needs_fetch() {
  local repo="$1" mirror="$2" source_refs mirror_refs
  source_refs=$(git -C "${repo}" for-each-ref --format='%(objectname) %(refname)' 2>/dev/null) || return 0
  mirror_refs=$(git -C "${mirror}" for-each-ref --format='%(objectname) %(refname)' 2>/dev/null) || return 0
  [[ -n "$(comm -23 <(printf '%s\n' "${source_refs}" | sort) <(printf '%s\n' "${mirror_refs}" | sort))" ]]
}

pc_git_set_mirror_config() {
  local mirror="$1" repo="$2" origin="$3" rel="$4"
  git -C "${mirror}" config backup.originalPath "${repo}"
  git -C "${mirror}" config backup.originalOrigin "${origin}"
  git -C "${mirror}" config backup.mode git-mirror
  git -C "${mirror}" config backup.statePath ".pc-backup/git-state/${rel}"
}

pc_git_mirror_config_current() {
  local mirror="$1" repo="$2" origin="$3"
  [[ "$(git -C "${mirror}" config --get backup.originalPath 2>/dev/null || true)" == "${repo}" ]] \
    && [[ "$(git -C "${mirror}" config --get backup.originalOrigin 2>/dev/null || true)" == "${origin}" ]] \
    && [[ "$(git -C "${mirror}" config --get backup.mode 2>/dev/null || true)" == "git-mirror" ]]
}

# A clean repository whose recorded state is already "clean" needs no rewrite.
# Dirty repositories are always rewritten so patch and untracked content stay
# current.
pc_git_state_is_current() {
  local state_dir="$1"
  [[ "${PC_GIT_STAGED}" == "false" && "${PC_GIT_UNSTAGED}" == "false" && "${PC_GIT_UNTRACKED_COUNT}" -eq 0 ]] || return 1
  [[ -f "${state_dir}/status.json" ]] || return 1
  [[ ! -e "${state_dir}/staged.patch" && ! -e "${state_dir}/unstaged.patch" && ! -e "${state_dir}/untracked.tar.gz" ]] || return 1
  grep -q "\"staged\":false,\"unstaged\":false,\"untracked_count\":0,\"stash_count\":${PC_GIT_STASH_COUNT}," "${state_dir}/status.json"
}

pc_git_write_manifest_entry() {
  local repo="$1" storage_rel="$2" mode="$3" origin="$4" head="$5" branch="$6" verification="$7"
  {
    printf '{"original_path":'; pc_json_string "${repo}"
    printf ',"storage_path":'; pc_json_string "${storage_rel}"
    printf ',"mode":'; pc_json_string "${mode}"
    printf ',"origin_url":'; pc_json_string "${origin}"
    printf ',"head":'; pc_json_string "${head}"
    printf ',"branch":'; pc_json_string "${branch}"
    printf ',"staged":%s,"unstaged":%s,"untracked_count":%s,"ahead":%s,"local_branches_without_upstream":%s,"stash_count":%s' \
      "${PC_GIT_STAGED:-false}" "${PC_GIT_UNSTAGED:-false}" "${PC_GIT_UNTRACKED_COUNT:-0}" \
      "${PC_GIT_AHEAD_COUNT:-0}" "${PC_GIT_LOCAL_BRANCH_COUNT:-0}" "${PC_GIT_STASH_COUNT:-0}"
    printf ',"verification":'; pc_json_string "${verification}"
    printf '}\n'
  } >> "${PC_MANIFEST_REPOS_FILE}"
}

pc_git_confirm() {
  local prompt="$1" answer
  [[ "${PC_BACKUP_ASSUME_YES:-0}" != "1" ]] || return 0
  [[ -t 0 || -t 1 || -t 2 ]] || return 1
  printf '%s [y/N] ' "${prompt}" > /dev/tty
  IFS= read -r answer < /dev/tty || return 1
  case "${answer}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# Like pc_git_confirm, but "a" answers yes for every remaining stale mirror.
pc_git_confirm_remove_stale() {
  local prompt="$1" answer
  [[ "${PC_BACKUP_ASSUME_YES:-0}" != "1" ]] || return 0
  [[ "${PC_GIT_STALE_REMOVE_ALL:-0}" != "1" ]] || return 0
  [[ -t 0 || -t 1 || -t 2 ]] || return 1
  printf '%s [y/N/a(ll)] ' "${prompt}" > /dev/tty
  IFS= read -r answer < /dev/tty || return 1
  case "${answer}" in
    a|A|all|ALL) PC_GIT_STALE_REMOVE_ALL=1; return 0 ;;
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# A repository switched from git-mirror to git-url keeps its old mirror in the
# destination. Restore clones mirrors before git-url records and skips
# destinations that already exist, so the stale mirror would win over the
# current record. Remove it only after confirmation: history kept only in the
# mirror (refs/backup-snapshots) is lost with it. Non-interactive runs keep it
# and warn.
pc_git_remove_stale_mirror() {
  local rel="$1" mirror
  mirror="${PC_BACKUP_ROOT}/${rel}/.git"
  [[ -d "${mirror}" ]] || return 0
  [[ "$(git -C "${mirror}" config --get backup.mode 2>/dev/null || true)" == "git-mirror" ]] || return 0
  [[ "$(git -C "${mirror}" rev-parse --is-bare-repository 2>/dev/null || true)" == "true" ]] || return 0

  if pc_dry_run_diff; then
    pc_log "DRY-RUN: would ask to remove stale Git mirror (now git-url): ${rel}/.git"
    PC_DRY_RUN_CHANGED=$((PC_DRY_RUN_CHANGED + 1))
    return 0
  fi
  if ! pc_git_confirm_remove_stale "Git mirror left from before switching to git-url: ${mirror}
Delete it? Restore uses the git-url record instead. History kept only in the mirror (refs/backup-snapshots) is lost."; then
    pc_warn "stale Git mirror kept; restore would prefer it over the git-url record. Run make backup in a terminal to remove it, or remove it manually: ${mirror}"
    return 0
  fi
  if rm -rf -- "${mirror}"; then
    rmdir "${PC_BACKUP_ROOT}/${rel}" 2>/dev/null || true
    pc_log "Removed stale Git mirror: ${rel}/.git"
  else
    pc_warn "failed to remove stale Git mirror: ${mirror}"
    PC_BACKUP_FAILURES=$((PC_BACKUP_FAILURES + 1))
  fi
}

# Replace a non-bare copy (e.g. left after switching git-full to git-mirror)
# at a mirror destination. The source repository still exists, so the copy is
# removed only after the user confirms and a new mirror has been built.
# Explicit files.mirror entries inside the repository are carried over.
pc_git_replace_nonbare_mirror() {
  local repo="$1" rel="$2" mirror="$3"
  local copy_dir="${PC_BACKUP_ROOT}/${rel}" other entry entry_rel tmp_dir tmp_mirror held_dir
  for other in "${PC_GIT_REPOSITORIES[@]}"; do
    if [[ "${other}" == "${repo}/"* ]]; then
      pc_warn "existing Git destination is not a bare repository and contains nested repository data; remove it manually: ${copy_dir}"
      return 1
    fi
  done
  if ! pc_git_confirm "Existing Git destination is not a bare repository (e.g. a leftover git-full copy): ${copy_dir}
Delete it and recreate a Git mirror from ${repo}? Files only in this copy, such as gitignored files, are removed from the backup."; then
    pc_warn "existing Git destination is not a bare repository (e.g. a leftover git-full copy); run make backup in a terminal to replace it, or remove it manually: ${copy_dir}"
    return 1
  fi

  tmp_dir=$(mktemp -d "${PC_BACKUP_ROOT}/.pc-backup/.git-replace.XXXXXX")
  tmp_mirror="${tmp_dir}/repository.git"
  held_dir="${tmp_dir}/previous"
  if ! git clone --mirror --no-hardlinks "${repo}" "${tmp_mirror}"; then
    rm -rf -- "${tmp_dir}"
    pc_warn "failed to create Git mirror: ${repo}"
    return 1
  fi
  if ! mv -- "${copy_dir}" "${held_dir}"; then
    rm -rf -- "${tmp_dir}"
    pc_warn "failed to move aside non-bare Git destination: ${copy_dir}"
    return 1
  fi
  if ! mkdir -p -- "${copy_dir}" || ! mv -- "${tmp_mirror}" "${mirror}"; then
    pc_warn "failed to place new Git mirror; previous copy kept at: ${held_dir}"
    return 1
  fi
  for entry in "${PC_BACKUP_MIRROR_PATHS[@]}"; do
    entry=$(pc_absolute_path "${entry}" 2>/dev/null || printf '%s' "${entry%/}")
    [[ "${entry}" == "${repo}/"* ]] || continue
    entry_rel="${entry#${repo}/}"
    [[ -e "${held_dir}/${entry_rel}" ]] || continue
    if ! mkdir -p -- "$(dirname -- "${copy_dir}/${entry_rel}")" \
      || ! mv -- "${held_dir}/${entry_rel}" "${copy_dir}/${entry_rel}"; then
      pc_warn "failed to carry over explicit file; previous copy kept at: ${held_dir}"
      return 1
    fi
  done
  rm -f -- "${PC_BACKUP_ROOT}/.pc-backup/git-full/${rel}.repo-info"
  rm -rf -- "${tmp_dir}"
  pc_log "Replaced non-bare Git destination with a new mirror: ${rel}"
}

pc_backup_one_git_repo() {
  local repo="$1" mode rel mirror state_dir origin head branch storage_rel verification="not-run"
  local tmp_dir tmp_mirror head_ref head_value info_file is_bare capture_state=0 reject_dirty=0

  mode=$(pc_git_mode_for_repo "${repo}")
  rel=$(pc_visible_storage_rel "${repo}")
  origin=$(pc_git_origin_url "${repo}")
  # `git rev-parse HEAD` prints the literal string "HEAD" even when an unborn
  # branch has no commit. Only accept a verified object ID as the recorded HEAD.
  head_value=$(git -C "${repo}" rev-parse --verify --quiet HEAD 2>/dev/null || true)
  head=$(git -C "${repo}" rev-parse --verify --quiet 'HEAD^{object}' 2>/dev/null || true)
  branch=$(git -C "${repo}" symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'DETACHED')

  PC_GIT_STAGED=false
  PC_GIT_UNSTAGED=false
  PC_GIT_UNTRACKED_COUNT=0
  PC_GIT_STASH_COUNT=0
  PC_GIT_AHEAD_COUNT=0
  PC_GIT_LOCAL_BRANCH_COUNT=0

  # A repository can have a valid-looking HEAD while its object store is
  # unreadable (for example, a stale objects/info/alternates path). Treat that
  # as a backup failure instead of misreporting Git command errors as changes.
  if [[ -n "${head_value}" && -z "${head}" ]]; then
    pc_warn "Git repository object store is unreadable: ${repo}"
    PC_BACKUP_FAILURES=$((PC_BACKUP_FAILURES + 1))
    pc_git_write_manifest_entry "${repo}" "" "${mode}" "${origin}" "${head}" "${branch}" "source-unreadable"
    return 0
  fi

  state_dir="${PC_BACKUP_ROOT}/.pc-backup/git-state/${rel}"
  is_bare=$(git -C "${repo}" rev-parse --is-bare-repository 2>/dev/null || printf 'false')
  if [[ "${is_bare}" == "true" ]]; then
    PC_GIT_STASH_COUNT=$(git -C "${repo}" rev-list --count refs/stash 2>/dev/null || printf '0')
  else
    pc_git_inspect_state "${repo}"
  fi
  pc_git_branch_safety "${repo}"

  if [[ "${PC_GIT_STAGED}" == "true" || "${PC_GIT_UNSTAGED}" == "true" || "${PC_GIT_UNTRACKED_COUNT}" -gt 0 ]]; then
    case "${PC_BACKUP_GIT_DIRTY_MODE:-backup}" in
      backup)
        capture_state=1
        if [[ "${PC_BACKUP_DRY_RUN:-0}" == "1" ]]; then
          pc_log "DRY-RUN: would capture Git local changes: ${repo}"
          pc_dry_run_diff && PC_DRY_RUN_CHANGED=$((PC_DRY_RUN_CHANGED + 1))
        else
          pc_log "Git local changes captured: ${repo}"
        fi
        ;;
      warn) pc_warn "Git repository has local changes: ${repo}" ;;
      fail) pc_warn "Git repository rejected because it has local changes: ${repo}"; reject_dirty=1 ;;
      *) pc_die "invalid PC_BACKUP_GIT_DIRTY_MODE: ${PC_BACKUP_GIT_DIRTY_MODE}" ;;
    esac
  fi

  if [[ "${is_bare}" != "true" && "${PC_BACKUP_DRY_RUN:-0}" != "1" ]] \
    && ! pc_git_state_is_current "${state_dir}"; then
    pc_git_store_state "${repo}" "${state_dir}" "${capture_state}"
  fi
  if [[ ${reject_dirty} -eq 1 ]]; then
    PC_BACKUP_FAILURES=$((PC_BACKUP_FAILURES + 1))
    return 0
  fi

  if [[ "${mode}" == "git-url" ]]; then
    local unsafe_reasons=""
    [[ -n "${origin}" ]] || unsafe_reasons="${unsafe_reasons} no-remote"
    # Local changes are safe for git-url only when they are saved as patches
    # (dirty_mode backup); restore clones, checks out the recorded HEAD and
    # applies them. With warn they would be lost, so promote to git-mirror.
    if [[ ${capture_state} -ne 1 ]]; then
      [[ "${PC_GIT_STAGED}" == "false" && "${PC_GIT_UNSTAGED}" == "false" && "${PC_GIT_UNTRACKED_COUNT}" -eq 0 ]] \
        || unsafe_reasons="${unsafe_reasons} local-changes"
    fi
    [[ "${PC_GIT_AHEAD_COUNT}" -eq 0 ]] || unsafe_reasons="${unsafe_reasons} unpushed-commits(${PC_GIT_AHEAD_COUNT})"
    [[ "${PC_GIT_LOCAL_BRANCH_COUNT}" -eq 0 ]] || unsafe_reasons="${unsafe_reasons} branches-without-upstream(${PC_GIT_LOCAL_BRANCH_COUNT})"
    [[ "${PC_GIT_STASH_COUNT}" -eq 0 ]] || unsafe_reasons="${unsafe_reasons} stash(${PC_GIT_STASH_COUNT})"
    if [[ -n "${unsafe_reasons}" ]]; then
      pc_warn "git-url is unsafe (${unsafe_reasons# }); promoted to git-mirror: ${repo}"
      mode="git-mirror"
    fi
  fi

  case "${mode}" in
    skip)
      pc_dry_run_diff || pc_log "Git skip: ${repo}"
      pc_git_write_manifest_entry "${repo}" "" "skip" "${origin}" "${head}" "${branch}" "skipped"
      ;;
    git-url)
      info_file="${PC_BACKUP_ROOT}/.pc-backup/git-url/${rel}.repo-info"
      storage_rel="${info_file#${PC_BACKUP_ROOT}/}"
      if pc_dry_run_diff; then
        if [[ "$(cat -- "${info_file}" 2>/dev/null || true)" != "$(printf '%s\n%s\n%s\n%s' "${repo}" "${origin}" "${head}" "${branch}")" ]]; then
          pc_log "DRY-RUN: Git URL inventory would change: ${repo} (HEAD ${head:-none}, branch ${branch})"
          PC_DRY_RUN_CHANGED=$((PC_DRY_RUN_CHANGED + 1))
        fi
      else
        pc_log "Git URL inventory: ${repo}"
      fi
      if [[ "${PC_BACKUP_DRY_RUN:-0}" != "1" ]] \
        && [[ "$(cat -- "${info_file}" 2>/dev/null || true)" != "$(printf '%s\n%s\n%s\n%s' "${repo}" "${origin}" "${head}" "${branch}")" ]]; then
        # Rewriting an identical file still makes cloud storage sync it.
        mkdir -p "$(dirname -- "${info_file}")"
        {
          printf '%s\n' "${repo}"
          printf '%s\n' "${origin}"
          printf '%s\n' "${head}"
          printf '%s\n' "${branch}"
        } > "${info_file}"
        chmod 600 "${info_file}"
      fi
      # make check must not read the destination (see the git-mirror branch).
      if [[ "${PC_BACKUP_CHECK_ONLY:-0}" != "1" ]]; then
        pc_git_remove_stale_mirror "${rel}"
      fi
      pc_git_write_manifest_entry "${repo}" "${storage_rel}" "git-url" "${origin}" "${head}" "${branch}" "metadata-only"
      ;;
    git-full)
      mirror="${PC_BACKUP_ROOT}/${rel}"
      info_file="${PC_BACKUP_ROOT}/.pc-backup/git-full/${rel}.repo-info"
      storage_rel="${mirror#${PC_BACKUP_ROOT}/}"
      local full_rsync_opts=(-a)
      [[ "${PC_BACKUP_RSYNC_DELETE:-1}" == "1" ]] && full_rsync_opts+=(--delete)
      if pc_dry_run_diff; then
        pc_dry_run_rsync "Git full rsync: ${repo} -> ${storage_rel}" "${repo}/" "${mirror}/" "${full_rsync_opts[@]}"
      else
        pc_log "Git full rsync: ${repo} -> ${storage_rel}"
      fi
      if [[ "${PC_BACKUP_DRY_RUN:-0}" != "1" ]]; then
        mkdir -p "${mirror}" "$(dirname -- "${info_file}")"
        rsync "${full_rsync_opts[@]}" "${repo}/" "${mirror}/" \
          || PC_BACKUP_FAILURES=$((PC_BACKUP_FAILURES + 1))
        {
          printf '%s\n' "${repo}"
          printf '%s\n' "${origin}"
          printf '%s\n' "${head}"
          printf '%s\n' "${branch}"
          printf '%s\n' "${mirror}"
        } > "${info_file}"
        chmod 600 "${info_file}"
      fi
      pc_git_write_manifest_entry "${repo}" "${storage_rel}" "git-full" "${origin}" "${head}" "${branch}" "copied"
      ;;
    git-mirror)
      mirror="${PC_BACKUP_ROOT}/${rel}/.git"
      storage_rel="${mirror#${PC_BACKUP_ROOT}/}"
      pc_dry_run_diff || pc_log "Git mirror: ${repo} -> ${storage_rel}"
      if [[ "${PC_BACKUP_DRY_RUN:-0}" != "1" ]]; then
        mkdir -p "$(dirname -- "${mirror}")"
        local mirror_is_bare="true" mirror_state="updated" local_mirror=""
        if [[ -d "${mirror}" ]]; then
          # rev-parse succeeds for non-bare .git directories too, so compare
          # its output. A leftover git-full copy must not receive mirror refs.
          mirror_is_bare=$(git -C "${mirror}" rev-parse --is-bare-repository 2>/dev/null || true)
        elif [[ -e "${mirror}" || -L "${mirror}" ]]; then
          # A linked worktree copied by git-full has a .git file.
          mirror_is_bare="false"
        fi
        if [[ "${mirror_is_bare}" != "true" ]]; then
          if ! pc_git_replace_nonbare_mirror "${repo}" "${rel}" "${mirror}"; then
            PC_BACKUP_FAILURES=$((PC_BACKUP_FAILURES + 1))
            return 0
          fi
          mirror_state="replaced"
        elif [[ ! -d "${mirror}" ]]; then
          # Build and verify a new mirror on local disk, then place the checked
          # copy in the destination. Reading a whole mirror back from cloud
          # storage (fsck) takes minutes per repository.
          local_mirror=$(mktemp -d "${PC_LOCAL_WORK_DIR}/mirror.XXXXXX")/repository.git
          if ! git clone --mirror --no-hardlinks "${repo}" "${local_mirror}"; then
            rm -rf -- "$(dirname -- "${local_mirror}")"
            pc_warn "failed to create Git mirror: ${repo}"
            PC_BACKUP_FAILURES=$((PC_BACKUP_FAILURES + 1))
            return 0
          fi
          if [[ "${PC_BACKUP_GIT_VERIFY:-1}" == "1" ]]; then
            if git -C "${local_mirror}" fsck --full >/dev/null; then
              verification="ok"
            else
              rm -rf -- "$(dirname -- "${local_mirror}")"
              pc_warn "new Git mirror failed verification; not saved: ${repo}"
              PC_BACKUP_FAILURES=$((PC_BACKUP_FAILURES + 1))
              pc_git_write_manifest_entry "${repo}" "${storage_rel}" "git-mirror" "${origin}" "${head}" "${branch}" "failed"
              return 0
            fi
          fi
          pc_git_set_mirror_config "${local_mirror}" "${repo}" "${origin}" "${rel}"
          tmp_dir=$(mktemp -d "$(dirname -- "${mirror}")/.git-mirror.XXXXXX")
          if ! rsync -a "${local_mirror}/" "${tmp_dir}/repository.git/" \
            || ! mv "${tmp_dir}/repository.git" "${mirror}"; then
            rm -rf -- "${tmp_dir}" "$(dirname -- "${local_mirror}")"
            pc_warn "failed to place Git mirror: ${repo}"
            PC_BACKUP_FAILURES=$((PC_BACKUP_FAILURES + 1))
            return 0
          fi
          rmdir "${tmp_dir}"
          rm -rf -- "$(dirname -- "${local_mirror}")"
          mirror_state="created"
        elif pc_git_mirror_needs_fetch "${repo}" "${mirror}"; then
          pc_git_snapshot_refs "${mirror}" "${PC_BACKUP_TIMESTAMP}"
          # Do not launch detached maintenance from this fetch: with many linked
          # worktrees sharing one object store its repack can still be running
          # when verify-backup.sh checks the mirror.
          if ! git -C "${mirror}" fetch --no-auto-maintenance --no-write-commit-graph \
            "${repo}" '+refs/*:refs/*'; then
            pc_warn "failed to update Git mirror: ${repo}"
            PC_BACKUP_FAILURES=$((PC_BACKUP_FAILURES + 1))
            return 0
          fi
          mirror_state="updated"
        else
          mirror_state="unchanged"
        fi

        # HEAD can change (branch switch) without any ref changing.
        head_ref=$(git -C "${repo}" symbolic-ref --quiet HEAD 2>/dev/null || true)
        if [[ -n "${head_ref}" && "$(git -C "${mirror}" symbolic-ref --quiet HEAD 2>/dev/null || true)" != "${head_ref}" ]]; then
          git -C "${mirror}" symbolic-ref HEAD "${head_ref}"
        fi
        if [[ "${mirror_state}" != "created" ]] && ! pc_git_mirror_config_current "${mirror}" "${repo}" "${origin}"; then
          pc_git_set_mirror_config "${mirror}" "${repo}" "${origin}" "${rel}"
        fi
        pc_git_copy_local_lfs "${repo}" "${mirror}"
        case "${mirror_state}" in
          unchanged)
            verification="unchanged"
            ;;
          updated)
            pc_git_repair_commit_graph "${mirror}" || true
            # fetch already checks pack integrity and connectivity of what it
            # received. A full fsck of an existing mirror reads every object
            # back from the destination; verify-backup.sh does that instead.
            verification="fetched"
            ;;
          replaced)
            pc_git_repair_commit_graph "${mirror}" || true
            if [[ "${PC_BACKUP_GIT_VERIFY:-1}" == "1" ]]; then
              if git -C "${mirror}" fsck --full >/dev/null; then
                verification="ok"
              else
                verification="failed"
                PC_BACKUP_FAILURES=$((PC_BACKUP_FAILURES + 1))
              fi
            fi
            ;;
        esac
      else
        # make check (PC_BACKUP_CHECK_ONLY=1) must not read the destination:
        # on File Provider storage such as OneDrive, reading a mirror can block
        # while the file is downloaded. Only the dry-run comparison does that.
        if pc_dry_run_diff; then
          if [[ -e "${mirror}" || -L "${mirror}" ]] \
            && [[ "$(git -C "${mirror}" rev-parse --is-bare-repository 2>/dev/null || true)" != "true" ]]; then
            pc_log "DRY-RUN: would ask to replace non-bare Git destination: ${PC_BACKUP_ROOT}/${rel}"
            PC_DRY_RUN_CHANGED=$((PC_DRY_RUN_CHANGED + 1))
          else
            pc_git_dry_run_mirror_refs "${repo}" "${mirror}" "${storage_rel}"
          fi
        fi
        verification="dry-run"
      fi
      pc_git_write_manifest_entry "${repo}" "${storage_rel}" "git-mirror" "${origin}" "${head}" "${branch}" "${verification}"
      ;;
    *)
      pc_die "invalid Git backup mode: ${mode}"
      ;;
  esac
}

# Show the refs a mirror fetch would create or move. Refs that exist only in
# the mirror (snapshots, refs deleted from the source) are kept by fetch and
# therefore not reported.
pc_git_dry_run_mirror_refs() {
  local repo="$1" mirror="$2" storage_rel="$3" source_refs mirror_refs changes count
  if [[ ! -d "${mirror}" ]]; then
    count=$(git -C "${repo}" for-each-ref --format='%(refname)' | wc -l | tr -d ' ')
    pc_log "DRY-RUN: would create Git mirror: ${repo} -> ${storage_rel} (${count} ref(s))"
    PC_DRY_RUN_CHANGED=$((PC_DRY_RUN_CHANGED + 1))
    return 0
  fi
  source_refs="${PC_WORK_DIR}/dry-run-source-refs"
  mirror_refs="${PC_WORK_DIR}/dry-run-mirror-refs"
  git -C "${repo}" for-each-ref --format='%(objectname) %(refname)' > "${source_refs}"
  git -C "${mirror}" for-each-ref --format='%(objectname) %(refname)' > "${mirror_refs}"
  changes=$(awk 'NR == FNR { known[$2] = $1; next }
    !($2 in known) { print "new    " $2; next }
    known[$2] != $1 { print "update " $2 " " substr(known[$2], 1, 12) ".." substr($1, 1, 12) }' \
    "${mirror_refs}" "${source_refs}")
  [[ -n "${changes}" ]] || return 0
  count=$(printf '%s\n' "${changes}" | wc -l | tr -d ' ')
  pc_log "DRY-RUN: Git mirror: ${repo} -> ${storage_rel} (${count} ref change(s))"
  printf '%s\n' "${changes}" | sed 's/^/    /'
  PC_DRY_RUN_CHANGED=$((PC_DRY_RUN_CHANGED + 1))
}

pc_git_repo_seen() {
  local needle="$1" item
  for item in "${PC_GIT_REPOSITORIES[@]}"; do
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

pc_discover_git_repositories() {
  local root git_marker repo exclude separator
  local find_args
  PC_GIT_REPOSITORIES=()
  for root in "${PC_BACKUP_GIT_ROOTS[@]}"; do
    [[ -d "${root}" ]] || { pc_warn "Git root missing: ${root}"; continue; }
    root=$(cd -- "${root}" && pwd -P)
    if [[ "$(git -C "${root}" rev-parse --is-bare-repository 2>/dev/null || true)" == "true" ]]; then
      pc_git_repo_seen "${root}" || PC_GIT_REPOSITORIES+=("${root}")
    fi
    find_args=("${root}" "(")
    separator=0
    for exclude in "${PC_BACKUP_EXCLUDE_NAMES[@]}"; do
      [[ ${separator} -eq 0 ]] || find_args+=(-o)
      find_args+=(-name "${exclude}")
      separator=1
    done
    if [[ ${separator} -eq 0 ]]; then
      find_args=("${root}" -name .git -print0)
    else
      find_args+=(")" -prune -o -name .git -print0)
    fi
    while IFS= read -r -d '' git_marker; do
      repo=$(dirname -- "${git_marker}")
      repo=$(git -C "${repo}" rev-parse --show-toplevel 2>/dev/null || true)
      [[ -n "${repo}" ]] || continue
      pc_git_repo_seen "${repo}" || PC_GIT_REPOSITORIES+=("${repo}")
    done < <(find "${find_args[@]}")
  done
}

pc_prepare_git_repositories() {
  [[ "${PC_GIT_DISCOVERY_READY:-0}" == "1" ]] && return 0
  PC_GIT_DISCOVERY_READY=1
  PC_GIT_REPOSITORIES=()
  if [[ ${#PC_BACKUP_GIT_ROOTS[@]} -eq 0 ]]; then
    pc_log "Git backup: no roots configured"
    return 0
  fi
  pc_require_cmd git
  pc_discover_git_repositories
  pc_log "Git repositories discovered: ${#PC_GIT_REPOSITORIES[@]}"
}

pc_backup_git_repositories() {
  local repo
  pc_prepare_git_repositories
  for repo in "${PC_GIT_REPOSITORIES[@]}"; do
    pc_backup_one_git_repo "${repo}"
  done
}
