#!/usr/bin/env bash
set -euo pipefail

# Warns when the pinned openai-harmony submodule is behind the upstream OpenAI
# harmony repo's latest release.
#
# It compares against the *live upstream repo* (openai/harmony) — not the local
# submodule checkout, which may be uninitialized or stale — by reading the commit
# we pin in HEAD's gitlink and comparing it to upstream's latest published
# release (falling back to the newest tag, then the default branch's HEAD).
#
# When we're behind it opens (or refreshes) a single tracking issue so the drift
# is visible without digging through Actions logs; when we catch up it closes
# that issue. It never rebuilds anything — rebuilding + committing the
# xcframework is the separate, manual build-xcframework.yml job. This only tells
# you *when* to run that job.
#
# Requires: gh (authenticated via GH_TOKEN) and jq. Configurable via env:
#   UPSTREAM        upstream repo            (default openai/harmony)
#   SUBMODULE_PATH  path of the gitlink      (default rust/openai-harmony)
#   ISSUE_LABEL     tracking-issue label     (default upstream-drift)
#   ISSUE_TITLE     tracking-issue title     (default below)

UPSTREAM="${UPSTREAM:-openai/harmony}"
SUBMODULE_PATH="${SUBMODULE_PATH:-rust/openai-harmony}"
ISSUE_LABEL="${ISSUE_LABEL:-upstream-drift}"
ISSUE_TITLE="${ISSUE_TITLE:-openai-harmony submodule is behind upstream}"

# The commit we pin, read from HEAD's gitlink (no submodule checkout needed).
pinned="$(git ls-tree HEAD "$SUBMODULE_PATH" | awk '$2 == "commit" {print $3}')"
if [ -z "$pinned" ]; then
  echo "::error::Could not read a pinned commit for '$SUBMODULE_PATH' from HEAD (is it a submodule?)."
  exit 1
fi
echo "Pinned $SUBMODULE_PATH commit: $pinned"

# Resolve upstream's latest reference: prefer a published release, then the
# newest tag, then the default branch's HEAD.
ref_kind=""
ref_name=""
if tag_name="$(gh api "repos/$UPSTREAM/releases/latest" --jq '.tag_name // empty' 2>/dev/null)" && [ -n "$tag_name" ]; then
  ref_kind="release"
  ref_name="$tag_name"
elif tag_name="$(gh api "repos/$UPSTREAM/tags?per_page=1" --jq '.[0].name // empty' 2>/dev/null)" && [ -n "$tag_name" ]; then
  ref_kind="tag"
  ref_name="$tag_name"
else
  ref_kind="branch"
  ref_name="$(gh api "repos/$UPSTREAM" --jq '.default_branch // empty')"
fi

# `// empty` above yields an empty string (never the literal "null") on a missing
# field, so a failed resolution is caught here rather than silently comparing
# against a bogus reference.
if [ -z "$ref_name" ] || [ "$ref_name" = "null" ]; then
  echo "::error::Could not resolve an upstream reference for '$UPSTREAM'."
  exit 1
fi

# Dereference the reference to its commit SHA (handles annotated tags, since the
# commits endpoint resolves the ref to the commit it ultimately points at).
upstream_sha="$(gh api "repos/$UPSTREAM/commits/$ref_name" --jq '.sha // empty')"
if [ -z "$upstream_sha" ] || [ "$upstream_sha" = "null" ]; then
  echo "::error::Could not resolve a commit SHA for '$UPSTREAM' $ref_kind '$ref_name'."
  exit 1
fi
echo "Upstream latest ($ref_kind $ref_name): $upstream_sha"

# A single reused tracking issue (matched by label). Ensure the label exists so
# create/list never fail on a missing label.
gh label create "$ISSUE_LABEL" \
  --color BFD4F2 \
  --description "Pinned openai-harmony is behind upstream" >/dev/null 2>&1 || true
existing="$(gh issue list --label "$ISSUE_LABEL" --state open --json number --jq '.[0].number // empty')"

if [ "$pinned" = "$upstream_sha" ]; then
  echo "Up to date with upstream $ref_kind $ref_name."
  if [ -n "$existing" ]; then
    gh issue close "$existing" \
      --comment "Pinned openai-harmony now matches upstream $ref_kind \`$ref_name\` ($upstream_sha). Closing automatically."
    echo "Closed stale tracking issue #$existing."
  fi
  exit 0
fi

# We differ from upstream's latest release/tag, so we're (almost certainly)
# behind. Emit a warning annotation and open/refresh the tracking issue.
compare_url="https://github.com/$UPSTREAM/compare/${pinned}...${ref_name}"
echo "::warning::Pinned openai-harmony ($pinned) is behind upstream $ref_kind $ref_name ($upstream_sha)."

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT
cat >"$body_file" <<EOF
The \`$SUBMODULE_PATH\` submodule is behind upstream [\`$UPSTREAM\`](https://github.com/$UPSTREAM).

| | commit | reference |
|---|---|---|
| Pinned here | \`$pinned\` | — |
| Upstream latest | \`$upstream_sha\` | $ref_kind \`$ref_name\` |

Upstream changes since our pin: $compare_url

**To update:**
1. \`git -C $SUBMODULE_PATH fetch --tags && git -C $SUBMODULE_PATH checkout $ref_name\`
2. Commit the submodule bump on a branch.
3. Manually run **Build XCFramework** (Actions → Build XCFramework → Run workflow) on that branch to rebuild and commit the binaries.

<sub>Maintained automatically by \`.github/workflows/check-upstream-harmony.yml\`.</sub>
EOF

if [ -n "$existing" ]; then
  gh issue edit "$existing" --body-file "$body_file"
  echo "Updated tracking issue #$existing."
else
  gh issue create --title "$ISSUE_TITLE" --label "$ISSUE_LABEL" --body-file "$body_file"
fi
