#!/usr/bin/env bash
# Mirror an HTTPS upstream repository (and optionally its Wiki) to Codeberg.
# Before replacing/deleting destination refs, archive their old Git objects as
# immutable tags: refs/tags/__mirror_backup__/<run>/branches|tags/<name>.
# Requires: Bash 4+, git, curl, jq; git-lfs only when LFS options are enabled.
# NOTE: this is a one-way mirror. Never edit the Codeberg copy directly.
set -euo pipefail

: "${SOURCE_URL:?Required: SOURCE_URL (public HTTPS clone URL)}"
: "${DEST_PATH:?Required: DEST_PATH (owner/repository)}"
: "${CODEBERG_USERNAME:?Required: CODEBERG_USERNAME}"
: "${CODEBERG_TOKEN:?Required: CODEBERG_TOKEN}"

WITH_LFS="${WITH_LFS:-false}"
WITH_WIKI="${WITH_WIKI:-false}"
WITH_WIKI_LFS="${WITH_WIKI_LFS:-false}"
CREATE_PRIVATE="${CREATE_PRIVATE:-false}"
BACKUP_PREFIX='__mirror_backup__'
API_URL='https://codeberg.org/api/v1'

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
notice() { printf '%s\n' "$*" >&2; }
check_https_url() {
  local url="$1" server
  [[ "$url" == https://* ]] || fail 'Upstream URL must use HTTPS.'
  server="${url#https://}"
  server="${server%%/*}"
  [[ -n "$server" && "$server" != *'@'* && "$url" != *[[:space:]]* ]] ||
    fail 'Upstream HTTPS URL must not contain credentials or whitespace.'
}

[[ "$DEST_PATH" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "Invalid DEST_PATH: $DEST_PATH"
for option in WITH_LFS WITH_WIKI WITH_WIKI_LFS CREATE_PRIVATE; do
  value="${!option}"
  [[ "$value" == true || "$value" == false ]] || fail "$option must be true or false"
done
check_https_url "$SOURCE_URL"
for bin in git curl jq; do command -v "$bin" >/dev/null 2>&1 || fail "Missing command: $bin"; done
if [[ "$WITH_LFS" == true || ( "$WITH_WIKI" == true && "$WITH_WIKI_LFS" == true ) ]]; then
  git lfs version >/dev/null 2>&1 || fail 'Git LFS is required but not installed.'
fi

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
umask 077
cat > "$WORK/askpass" <<'ASKPASS'
#!/usr/bin/env bash
case "${1:-}" in
  *Username*) printf '%s\n' "$CODEBERG_USERNAME" ;;
  *Password*) printf '%s\n' "$CODEBERG_TOKEN" ;;
  *) exit 1 ;;
esac
ASKPASS
chmod 700 "$WORK/askpass"
printf 'Authorization: token %s\n' "$CODEBERG_TOKEN" > "$WORK/api-header"

# Credentials are NOT embedded in remote URLs or in shell command arguments.
# Only operations explicitly wrapped in cb_git use the Codeberg askpass script.
cb_git() { GIT_ASKPASS="$WORK/askpass" git "$@"; }
export GIT_TERMINAL_PROMPT=0 GIT_LFS_SKIP_SMUDGE=1
TARGET_URL="${TARGET_URL_OVERRIDE:-https://codeberg.org/${DEST_PATH}.git}"
TARGET_WIKI_URL="${TARGET_WIKI_URL_OVERRIDE:-https://codeberg.org/${DEST_PATH}.wiki.git}"
# Local integration tests may supply file:// or pathname overrides; in this
# mode no Codeberg API is called, and destination repositories must exist.
API_ENABLED=true
[[ -z "${TARGET_URL_OVERRIDE:-}" && -z "${TARGET_WIKI_URL_OVERRIDE:-}" ]] || API_ENABLED=false

api_request() {
  local method="$1" path="$2" body="${3:-}" status
  local -a args=(--silent --show-error --connect-timeout 15 --max-time 90
    --header "@$WORK/api-header" --header 'Accept: application/json'
    --header 'Content-Type: application/json' --output "$WORK/api-response.json"
    --write-out '%{http_code}' --request "$method")
  [[ -z "$body" ]] || args+=(--data-binary "@$body")
  status="$(curl "${args[@]}" "$API_URL/$path")" || fail "HTTP transport error: $method $path"
  API_STATUS="$status"
}
api_expect() {
  local expected="$1" action="$2"
  if [[ "$API_STATUS" != "$expected" ]]; then
    notice "API $action failed (HTTP $API_STATUS):"
    cat "$WORK/api-response.json" >&2 || true
    fail "$action"
  fi
}
repo_api_path="repos/$DEST_PATH"
load_repo() {
  api_request GET "$repo_api_path"
  api_expect 200 "Read Codeberg repository $DEST_PATH"
  cp "$WORK/api-response.json" "$WORK/repo.json"
}
ensure_repository() {
  local owner="${DEST_PATH%%/*}" name="${DEST_PATH#*/}" endpoint
  [[ "$API_ENABLED" == true ]] || return 0
  api_request GET "$repo_api_path"
  case "$API_STATUS" in
    200) notice "Codeberg repository exists: $DEST_PATH"; return 0 ;;
    404) notice "Creating Codeberg repository: $DEST_PATH" ;;
    *) api_expect 200 'Check repository permissions' ;;
  esac
  if [[ "${owner,,}" == "${CODEBERG_USERNAME,,}" ]]; then
    endpoint='user/repos'
  else
    endpoint="orgs/$owner/repos"
  fi
  jq -n --arg name "$name" --argjson private "$CREATE_PRIVATE" \
    '{name:$name, private:$private, auto_init:false}' > "$WORK/create-repo.json"
  api_request POST "$endpoint" "$WORK/create-repo.json"
  api_expect 201 "Create repository $DEST_PATH (token must have create permission)"
  notice "Created https://codeberg.org/$DEST_PATH"
}

# Set a description only when Codeberg does not already have one.
ensure_repo_description() {
  [[ "$API_ENABLED" == true ]] || return 0
  load_repo

  local desc new_desc
  desc=$(jq -r '(.description // "") | gsub("^\\s+|\\s+$"; "")' \
    "$WORK/repo.json")

  if [[ -n "$desc" && "$desc" == *"$SOURCE_URL"* ]]; then
    notice 'Codeberg repository description already contains SOURCE_URL; leaving it unchanged.'
    return 0
  fi

  if [[ -z "$desc" ]]; then
    new_desc="Backup of $SOURCE_URL by OZ"
  else
    new_desc="$desc | Backup of $SOURCE_URL by OZ"
  fi

  jq -n --arg description "$new_desc" \
    '{description:$description}' > "$WORK/repo-description.json"

  api_request PATCH "$repo_api_path" "$WORK/repo-description.json"
  api_expect 200 "Set description for $DEST_PATH"

  notice "Set Codeberg repository description: $new_desc"
}

# For a repo created in Codeberg, enable its Wiki and create a minimal Home
# page when the separate wiki.git does not yet have any Git branches.
ensure_wiki() {
  local wanted="$1" current_refs
  [[ "$API_ENABLED" == true ]] || return 0
  load_repo
  if jq -e '.external_wiki != null' "$WORK/repo.json" >/dev/null; then
    fail 'Destination uses an external Wiki; refusing to replace its configuration.'
  fi
  if [[ "$(jq -r '.has_wiki // false' "$WORK/repo.json")" != true ]]; then
    notice 'Enabling Codeberg Wiki...'
    printf '{"has_wiki":true}\n' > "$WORK/wiki-settings.json"
    api_request PATCH "$repo_api_path" "$WORK/wiki-settings.json"
    api_expect 200 'Enable Wiki'
  fi

  # Checking --heads (rather than HEAD) works with a repository whose HEAD is
  # not yet advertised. Authentication failures must not be mistaken for empty.
  if current_refs="$(cb_git ls-remote --heads "$TARGET_WIKI_URL" 2>"$WORK/wiki-ls-error")"; then
    if [[ -n "$current_refs" ]]; then
      notice 'Destination Wiki already initialized.'
      return 0
    fi
  else
    notice 'Wiki Git remote not initialized yet; trying Wiki creation API.'
  fi

  # Set the Wiki branch BEFORE creating its first commit. Forgejo uses the
  # configured Wiki branch when initializing its separate bare Git repo.
  jq -n --arg branch "$wanted" '{wiki_branch:$branch}' > "$WORK/wiki-branch-init.json"
  api_request PATCH "$repo_api_path" "$WORK/wiki-branch-init.json"
  api_expect 200 'Configure initial Wiki branch'
  notice 'Initializing Codeberg Wiki Home page via API...'
  jq -n --arg body $'# Home\n\nInitial page for Wiki mirroring.\n' \
    '{title:"Home",content_base64:($body|@base64),message:"Initialize Wiki for mirror"}' \
    > "$WORK/wiki-home.json"
  api_request POST "$repo_api_path/wiki/new" "$WORK/wiki-home.json"
  case "$API_STATUS" in
    200|201) ;;
    *) notice "Wiki initialization HTTP $API_STATUS:"; cat "$WORK/api-response.json" >&2; fail 'Initialize Wiki' ;;
  esac
  cb_git ls-remote --exit-code --heads "$TARGET_WIKI_URL" >/dev/null ||
    fail 'Wiki API succeeded but Wiki Git remote has no branches.'
}

# Determine the source default HEAD ref; if missing, use the first source head.
source_default_branch() {
  local head
  head="$(git symbolic-ref -q --short HEAD || true)"
  if [[ -n "$head" ]] && git show-ref -q --verify "refs/heads/$head"; then
    printf '%s\n' "$head"
  else
    git for-each-ref --format='%(refname:strip=2)' refs/heads | head -n 1
  fi
}

# After the desired branch has been pushed, change the branch shown by Codeberg
# BEFORE trying to delete its previous default branch.
set_destination_default() {
  local kind="$1" wanted="$2" field current
  [[ "$API_ENABLED" == true ]] || return 0
  load_repo
  if [[ "$kind" == wiki ]]; then field='wiki_branch'; else field='default_branch'; fi
  current="$(jq -r --arg field "$field" '.[$field] // ""' "$WORK/repo.json")"
  if [[ "$wanted" == "$current" ]]; then return 0; fi
  notice "Changing Codeberg $field from '${current:-<unset>}' to '$wanted'..."
  jq -n --arg field "$field" --arg branch "$wanted" '{($field):$branch}' > "$WORK/default-branch.json"
  api_request PATCH "$repo_api_path" "$WORK/default-branch.json"
  api_expect 200 "Change $field to $wanted"
  load_repo
  current="$(jq -r --arg field "$field" '.[$field] // ""' "$WORK/repo.json")"
  [[ "$current" == "$wanted" ]] || fail "Codeberg did not accept $field=$wanted"
}

# Push with an exact object-ID lease for EVERY destination ref, including new
# refs (empty lease). This rejects concurrent writes without silently erasing
# commits or tags which were not included in our backup snapshot.
mirror_git() (
  local kind="$1" src="$2" dest="$3" lfs="$4"
  local repo_dir="$WORK/${kind}.git" old new name ref archive current default
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$$-$RANDOM"
  local -a src_heads=() src_tags=() dst_heads=() dst_tags=()
  local -a backup_specs=() backup_leases=() update_specs=() update_leases=()
  local -a delete_specs=() delete_leases=()
  local -A old_heads=() old_tags=()
  local backups=0

  notice "::group::Mirror $kind: $src -> $dest"
  git clone --bare -- "$src" "$repo_dir"
  cd "$repo_dir"
  git remote add codeberg "$dest"
  mapfile -t src_heads < <(git for-each-ref --format='%(refname)' refs/heads)
  (( ${#src_heads[@]} > 0 )) || fail "Upstream $kind has no branches. No destination refs changed."
  mapfile -t src_tags < <(git for-each-ref --format='%(refname)' refs/tags)
  if git for-each-ref --format='%(refname)' refs/tags | grep -q -E "^refs/tags/${BACKUP_PREFIX}(/|$)"; then
    fail "Upstream has tags under reserved name: $BACKUP_PREFIX"
  fi
  default="$(source_default_branch)"
  notice "Upstream $kind default branch: $default"

  # Download source LFS FIRST, before adding any Codeberg-only refs locally.
  if [[ "$lfs" == true ]]; then
    notice 'Fetching source LFS history...'
    git lfs fetch --all origin
  fi

  if [[ "$kind" == repository ]]; then
    ensure_repository
    ensure_repo_description
  else
    ensure_wiki "$default"
  fi

  # Fetch destination branches and tags into a separate namespace so source
  # refs remain untouched, including annotated tag objects.
  cb_git fetch --no-tags codeberg \
    '+refs/heads/*:refs/destination/heads/*' \
    '+refs/tags/*:refs/destination/tags/*'
  while read -r ref old; do
    [[ -n "${ref:-}" ]] || continue
    name="${ref#refs/destination/heads/}"
    dst_heads+=("$name")
    old_heads["$name"]="$old"
  done < <(git for-each-ref --format='%(refname) %(objectname)' refs/destination/heads)
  while read -r ref old; do
    [[ -n "${ref:-}" ]] || continue
    name="${ref#refs/destination/tags/}"
    dst_tags+=("$name")
    old_tags["$name"]="$old"
  done < <(git for-each-ref --format='%(refname) %(objectname)' refs/destination/tags)

  # Previous backups can refer to LFS objects unavailable at the source.
  if [[ "$lfs" == true && $(( ${#dst_heads[@]} + ${#dst_tags[@]} )) -gt 0 ]]; then
    notice 'Fetching destination LFS history, including previous backups...'
    {
      for name in "${dst_heads[@]}"; do printf 'refs/destination/heads/%s\n' "$name"; done
      for name in "${dst_tags[@]}"; do printf 'refs/destination/tags/%s\n' "$name"; done
    } | cb_git -c "lfs.url=${dest%/}/info/lfs" lfs fetch --all codeberg --stdin
  fi

  # Archive changed/deleted destination branches, except fast-forwards.
  for name in "${dst_heads[@]}"; do
    old="${old_heads[$name]}"
    if git show-ref -q --verify "refs/heads/$name"; then
      new="$(git rev-parse "refs/heads/$name")"
      if git merge-base --is-ancestor "$old" "$new"; then continue; fi
    fi
    archive="refs/tags/$BACKUP_PREFIX/$stamp/branches/$name"
    git update-ref "$archive" "$old"
    backup_specs+=("$archive:$archive")
    backup_leases+=("--force-with-lease=$archive:")
    ((backups+=1))
    notice "Archived previous branch: $name ($old)"
  done

  # Back up changed/deleted annotated OR lightweight tags.
  for name in "${dst_tags[@]}"; do
    [[ "$name" == "$BACKUP_PREFIX/"* ]] && continue
    old="${old_tags[$name]}"
    if git show-ref -q --verify "refs/tags/$name" &&
       [[ "$old" == "$(git rev-parse "refs/tags/$name")" ]]; then
      continue
    fi
    archive="refs/tags/$BACKUP_PREFIX/$stamp/tags/$name"
    git update-ref "$archive" "$old"
    backup_specs+=("$archive:$archive")
    backup_leases+=("--force-with-lease=$archive:")
    ((backups+=1))
    notice "Archived previous tag: $name ($old)"
  done

  # Upload LFS while live Git refs are still intact. With --all, active source
  # refs and newly created backup tags are included.
  if [[ "$lfs" == true ]]; then
    notice 'Uploading source and archived LFS to Codeberg...'
    cb_git -c "lfs.url=${dest%/}/info/lfs" lfs push --all codeberg
  fi

  # First publish immutable backup refs; never force-replace a prior backup.
  if (( ${#backup_specs[@]} > 0 )); then
    cb_git push --atomic "${backup_leases[@]}" codeberg "${backup_specs[@]}"
  fi

  # Publish ALL desired upstream branches, safely leased to the snapshot.
  # Do not prune yet; destination's old default might need to be changed first.
  for ref in "${src_heads[@]}"; do
    name="${ref#refs/heads/}"
    update_specs+=("+$ref:$ref")
    update_leases+=("--force-with-lease=$ref:${old_heads[$name]:-}")
  done
  cb_git push --atomic "${update_leases[@]}" codeberg "${update_specs[@]}"

  # Changing the default is only possible after the wanted branch exists.
  set_destination_default "$kind" "$default"

  # Some forges may report a new default in their API while the bare Git
  # remote still advertises the old HEAD. Never attempt to delete that HEAD.
  local advertised_head
  advertised_head="$(cb_git ls-remote --symref codeberg HEAD | awk '$1 == "ref:" && $3 == "HEAD" {sub(/^refs\/heads\//, "", $2); print $2; exit}')"

  # Prune only previous destination heads absent from the source.
  for name in "${dst_heads[@]}"; do
    if ! git show-ref -q --verify "refs/heads/$name"; then
      if [[ "$name" == "$advertised_head" ]]; then
        notice "::warning::Not deleting $kind/$name: destination Git HEAD still points to it."
        continue
      fi
      ref="refs/heads/$name"
      delete_specs+=(":$ref")
      delete_leases+=("--force-with-lease=$ref:${old_heads[$name]}")
    fi
  done
  # Sync source tags without touching any destination backup archive.
  for ref in "${src_tags[@]}"; do
    name="${ref#refs/tags/}"
    delete_specs+=("+$ref:$ref")
    delete_leases+=("--force-with-lease=$ref:${old_tags[$name]:-}")
  done
  for name in "${dst_tags[@]}"; do
    [[ "$name" == "$BACKUP_PREFIX/"* ]] && continue
    if ! git show-ref -q --verify "refs/tags/$name"; then
      ref="refs/tags/$name"
      delete_specs+=(":$ref")
      delete_leases+=("--force-with-lease=$ref:${old_tags[$name]}")
    fi
  done
  if (( ${#delete_specs[@]} > 0 )); then
    cb_git push --atomic "${delete_leases[@]}" codeberg "${delete_specs[@]}"
  fi

  notice "DONE: $kind, created $backups new immutable backup tag(s)."
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf -- '- **%s** `%s` -> `%s`: %s backup tag(s); LFS=%s\n' \
      "$kind" "$src" "$dest" "$backups" "$lfs" >> "$GITHUB_STEP_SUMMARY"
  fi
  notice '::endgroup::'
)

mirror_git repository "$SOURCE_URL" "$TARGET_URL" "$WITH_LFS"

if [[ "$WITH_WIKI" == true ]]; then
  source_root="${SOURCE_URL%/}"
  source_root="${source_root%.git}"
  source_wiki="${SOURCE_WIKI_URL:-${source_root}.wiki.git}"
  check_https_url "$source_wiki"
  # A Wiki may have branches without an advertised symbolic HEAD.
  if wiki_refs="$(git ls-remote --heads "$source_wiki" 2>/dev/null)" && [[ -n "$wiki_refs" ]]; then
    notice "Source Wiki found: $source_wiki"
    mirror_git wiki "$source_wiki" "$TARGET_WIKI_URL" "$WITH_WIKI_LFS"
  else
    notice "::warning::Source Wiki missing, empty, or inaccessible: $source_wiki; destination Wiki left untouched."
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      printf -- '- **wiki**: source absent/empty/inaccessible; destination Wiki untouched.\n' >> "$GITHUB_STEP_SUMMARY"
    fi
  fi
fi
