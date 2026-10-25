# One-way Git backup to Codeberg

Edit **`repos`** to choose the upstream repositories. Each non-comment line is:

```text
https://github.com/R0rt1z2/kaeru.git#wiki=1|lfs=1|wiki_lfs=1|private=1
```

- `wiki`: copy the source Wiki (1 = yes, 0 = no).
- `lfs`: copy Git LFS history for the main repository (1 = yes, 0 = no).
- `wiki_lfs`: copy LFS history for the Wiki, if `wiki=1` (1 = yes, 0 = no).
- `private`: create a private Codeberg repository when it **does not exist yet** (1 = private, 0 = public). **Existing Codeberg repositories are not made private/public by this flag.**
- Lines beginning with `#` (optionally after whitespace) and blank lines are ignored.
- All four options must be present, and values must be `0` or `1`. Option order may vary.
- HTTPS clone URLs must be `/USERNAME/REPOSITORY` or `/USERNAME/REPOSITORY.git`; GitHub, GitLab or Forgejo URLs with that structure work. Nested groups/subgroups are not supported by this parser.

**Destination name**: original repository name + `_` + lowercase source username; the repository name keeps its original case.

Example: `https://github.com/R0rt1z2/kaeru.git` becomes `https://codeberg.org/ozsx/kaeru_r0rt1z2` when `CODEBERG_USERNAME=ozsx`.

## Workflow

`.github/workflows/sync.yml` first validates `repos` and builds a job matrix; each entry then calls the **unchanged** `scripts/sync-repo.sh` with the parsed flags. It runs every 3 hours UTC or on manual dispatch, using the same concurrency guard as before.

Set repository variable `CODEBERG_USERNAME` and secret `CODEBERG_TOKEN` in GitHub Actions settings. The token needs Codeberg repository creation and push privileges.

Run a local configuration check:

```bash
python3 scripts/parse_repos.py repos
```

**Important:** This naming scheme creates **new** Codeberg repositories with suffixed names if they do not exist. The old unsuffixed Codeberg mirrors are not automatically renamed or deleted. The mirror intentionally force-updates destination refs based on the upstream and preserves its original archive-before-replacement behavior.
