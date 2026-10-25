#!/usr/bin/env bash
# Synchronize one upstream Git repo and optional wiki to Codeberg.
# Disappearing / rewritten destination history is first kept as immutable backup tags.
set -euo pipefail

: "${SOURCE_URL:?Required: SOURCE_URL}"
: "${DEST_PATH:?Required: DEST_PATH (owner/repository)}"
: "${CODEBERG_USERNAME:?Required: GitHub variable CODEBERG_USERNAME}"
: "${CODEBERG_TOKEN:?Required: GitHub secret CODEBERG_TOKEN}"

WITH_LFS="${WITH_LFS:-false}"
WITH_WIKI="${WITH_WIKI:-false}"
WITH_WIKI_LFS="${WITH_WIKI_LFS:-false}"
BACKUP_PREFIX='__mirror_backup__'

if [[ ! "$DEST_PATH" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "Invalid DEST_PATH; use Codeberg owner/repo only: $DEST_PATH" >&2
  exit 2
fi
if [[ ! "$SOURCE_URL" == https://* ]]; then
  echo 'SOURCE_URL must be a public HTTPS Git clone URL (no credentials).' >&2
  exit 2
fi

# Credentials never occur in a remote URL or a process command line.
# CODEBERG_USERNAME can differ from DEST_PATH owner (org repositories).
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/askpass" <<'ASKPASS'
#!/usr/bin/env bash
case "$1" in
  *Username*) printf '%s\n' "$CODEBERG_USERNAME" ;;
  *Password*) printf '%s\n' "$CODEBERG_TOKEN" ;;
  *) exit 1 ;;
esac
ASKPASS
chmod 700 "$WORK/askpass"
# Only destination operations get the Codeberg token. The upstream repository
# and its LFS endpoint must NEVER receive this credential.
cb_git() { GIT_ASKPASS="$WORK/askpass" git "$@"; }
export GIT_TERMINAL_PROMPT=0
export GIT_LFS_SKIP_SMUDGE=1

TARGET_URL="https://codeberg.org/${DEST_PATH}.git"
TARGET_WIKI_URL="https://codeberg.org/${DEST_PATH}.wiki.git"
# These optional overrides are for local integration testing only.
TARGET_URL="${TARGET_URL_OVERRIDE:-$TARGET_URL}"
TARGET_WIKI_URL="${TARGET_WIKI_URL_OVERRIDE:-$TARGET_WIKI_URL}"

# Return the symref name pointed to by the remote HEAD, if advertised.
remote_default_branch() {
  cb_git ls-remote --symref "$1" HEAD | awk '$1 == "ref:" && $3 == "HEAD" {sub(/^refs\/heads\//, "", $2); print $2; exit}'
}

mirror_git() {
  local kind="$1" src="$2" dest="$3" lfs="$4"
  local repo_dir="$WORK/${kind}.git" remote_branch local_branch old new backup
  local stamp="$(date -u +%Y%m%dT%H%M%SZ)-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
  local -a destination_heads=() destination_tags=() backup_specs=() deleted_tags=()
  local dest_ref tag

  echo "::group::Mirror $kind: $src -> $dest"
  git clone --bare -- "$src" "$repo_dir"
  (
    cd "$repo_dir"
    git remote add codeberg "$dest"
    # Repositories that are accidentally empty must not erase a valid destination.
    if [[ -z "$(git for-each-ref --format='%(refname)' refs/heads)" ]]; then
      echo "ERROR: Upstream $kind has no branches; refusing destructive sync." >&2
      exit 1
    fi

    # 1) LFS already referenced by the UPSTREAM, including older commits.
    # Do this before adding destination-only refs, otherwise --all might ask
    # the source for LFS objects that ONLY exist at Codeberg.
    if [[ "$lfs" == 'true' ]]; then
      echo 'Fetching upstream LFS history...'
      git lfs fetch --all origin
    fi

    # 2) Collect ALL destination heads and tags (including previous backup tags).
    # Keep their object histories in this temporary clone for preservation.
    cb_git fetch --no-tags codeberg \
      '+refs/heads/*:refs/destination/heads/*' \
      '+refs/tags/*:refs/destination/tags/*'

    mapfile -t destination_heads < <(git for-each-ref --format='%(refname)' refs/destination/heads)
    mapfile -t destination_tags < <(git for-each-ref --format='%(refname)' refs/destination/tags)

    # 3) Fetch old LFS data FROM CODEBERG before deleting/replacing refs.
    # Crucial: old commits may no longer be reachable/available upstream.
    if [[ "$lfs" == 'true' ]] && (( ${#destination_heads[@]} + ${#destination_tags[@]} > 0 )); then
      echo 'Fetching existing Codeberg LFS history and previous backups...'
      printf '%s\n' "${destination_heads[@]}" "${destination_tags[@]}" | cb_git lfs fetch --all codeberg --stdin
    fi

    # Reserve our backup prefix so upstream cannot overwrite our archives.
    if [[ -n "$(git for-each-ref --format='%(refname)' "refs/tags/${BACKUP_PREFIX}")" ]]; then
      echo "ERROR: Upstream already has tags under reserved ${BACKUP_PREFIX}/ prefix." >&2
      exit 1
    fi

    # Special case: GitLab Wiki default branch is often main, Codeberg Wiki
    # is often master. Map upstream HEAD to destination HEAD so pages render.
    if [[ "$kind" == 'wiki' ]]; then
      local src_head dst_head src_oid
      src_head="$(git symbolic-ref -q --short HEAD || true)"
      dst_head="$(remote_default_branch codeberg)"
      if [[ -n "$src_head" && -n "$dst_head" && "$src_head" != "$dst_head" ]]; then
        if git show-ref --verify --quiet "refs/heads/$dst_head"; then
          echo "ERROR: Wiki upstream has both '$src_head' and '$dst_head'; branch mapping ambiguous." >&2
          exit 1
        fi
        src_oid="$(git rev-parse "refs/heads/$src_head")"
        git update-ref "refs/heads/$dst_head" "$src_oid"
        git update-ref -d "refs/heads/$src_head"
        echo "Mapped Wiki default branch $src_head -> $dst_head for Codeberg display."
      fi
    fi

    # 4) Archive any branch about to be DELETED or NON-FAST-FORWARD changed.
    # Normal fast-forwards do not need a backup (old commits remain reachable).
    for dest_ref in "${destination_heads[@]}"; do
      old="$(git rev-parse "$dest_ref")"
      remote_branch="${dest_ref#refs/destination/heads/}"
      local_branch="refs/heads/$remote_branch"
      if git show-ref --verify --quiet "$local_branch"; then
        new="$(git rev-parse "$local_branch")"
        if git merge-base --is-ancestor "$old" "$new"; then
          continue
        fi
      fi
      backup="refs/tags/${BACKUP_PREFIX}/${stamp}/branches/${remote_branch}"
      git update-ref "$backup" "$old"
      backup_specs+=("$backup:$backup")
      echo "Backup branch: $remote_branch (old=$old)"
    done

    # Archive tags that were deleted or changed, preserving annotated tag objects.
    # Previously generated backup tags are permanent, and never pruned.
    for dest_ref in "${destination_tags[@]}"; do
      tag="${dest_ref#refs/destination/tags/}"
      [[ "$tag" == "${BACKUP_PREFIX}/"* ]] && continue
      old="$(git rev-parse "$dest_ref")"
      if git show-ref --verify --quiet "refs/tags/$tag"; then
        [[ "$old" == "$(git rev-parse "refs/tags/$tag")" ]] && continue
      else
        deleted_tags+=(":refs/tags/$tag")
      fi
      backup="refs/tags/${BACKUP_PREFIX}/${stamp}/tags/${tag}"
      git update-ref "$backup" "$old"
      backup_specs+=("$backup:$backup")
      echo "Backup tag: $tag (old=$old)"
    done

    # 5) Upload all LFS objects for active source refs + new backup tags.
    # Fail BEFORE rewriting any Git refs if LFS transfer fails.
    if [[ "$lfs" == 'true' ]]; then
      echo 'Uploading live + archived Git LFS objects to Codeberg...'
      cb_git lfs push --all codeberg
    fi

    # 6) Commit backups to Codeberg FIRST. Abort on error (no force-push yet).
    if (( ${#backup_specs[@]} > 0 )); then
      cb_git push codeberg "${backup_specs[@]}"
    fi

    # 7) Synchronize live branches. --prune removes deleted upstream branches;
    # leading + handles force-push/rebase. Backup tags remain untouched.
    cb_git push --prune codeberg '+refs/heads/*:refs/heads/*'

    # 8) Update tags and explicitly delete old live tags only.
    # NEVER prune backup tags; old backups fetched into refs/destination/tags.
    cb_git push codeberg '+refs/tags/*:refs/tags/*'
    if (( ${#deleted_tags[@]} > 0 )); then
      cb_git push codeberg "${deleted_tags[@]}"
    fi

    echo "DONE: $kind; created ${#backup_specs[@]} backup tag(s)."
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      printf -- '- **%s** `%s` → `%s`: %s new backup tag(s); LFS=%s\n' \
        "$kind" "$src" "$dest" "${#backup_specs[@]}" "$lfs" >> "$GITHUB_STEP_SUMMARY"
    fi
  )
  echo '::endgroup::'
}

mirror_git 'repository' "$SOURCE_URL" "$TARGET_URL" "$WITH_LFS"

if [[ "$WITH_WIKI" == 'true' ]]; then
  # Standard GitHub, Forgejo, GitLab wiki clone URLs: <repo>.wiki.git.
  clean_source="${SOURCE_URL%/}"
  clean_source="${clean_source%.git}"
  source_wiki="${SOURCE_WIKI_URL:-${clean_source}.wiki.git}"

  # A repository may not have a Wiki at all. Never wipe an existing Codeberg
  # Wiki when a source Wiki is missing or inaccessible.
  if git ls-remote "$source_wiki" HEAD >/dev/null 2>&1; then
    echo "Source wiki found: $source_wiki"
    # Codeberg Wiki must be enabled + initialized (create one Home page).
    if ! cb_git ls-remote "$TARGET_WIKI_URL" HEAD >/dev/null 2>&1; then
      echo "ERROR: Destination Wiki missing/inaccessible: $TARGET_WIKI_URL" >&2
      echo 'Enable Codeberg Wiki and create an initial Home page, then retry.' >&2
      exit 1
    fi
    mirror_git 'wiki' "$source_wiki" "$TARGET_WIKI_URL" "$WITH_WIKI_LFS"
  else
    echo "::warning::Wiki absent/inaccessible at $source_wiki; no Wiki changes made."
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      printf -- '- **wiki**: absent or inaccessible at `%s`; skipped (no destination changes).\n' "$source_wiki" >> "$GITHUB_STEP_SUMMARY"
    fi
  fi
fi
