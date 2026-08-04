#!/bin/bash
set -e

DRY_SHA=$(git rev-parse HEAD)
ENV=$1  # e.g., "production"
PROPOSED_BRANCH="environment/${ENV}-next"
REPO_URL="https://github.com/org/repo"
NOTES_REF="refs/notes/hydrator.metadata"

# Fetch the proposed branch and notes
git fetch origin ${PROPOSED_BRANCH} 2>/dev/null || {
  echo "Proposed branch doesn't exist yet, will create it"
  BRANCH_EXISTS=false
}
BRANCH_EXISTS=${BRANCH_EXISTS:-true}

push_note_with_retry() {
  local commit_sha=$1
  local note_content="{\"drySha\": \"${DRY_SHA}\"}"

  for attempt in 1 2 3 4 5 6 7 8; do
    git fetch origin +${NOTES_REF}:${NOTES_REF} 2>/dev/null || true
    git notes --ref=${NOTES_REF} add -f -m "${note_content}" ${commit_sha}
    if git push origin ${NOTES_REF}; then
      return 0
    fi
    sleep 0.1
  done

  echo "Failed to push git note after retries" >&2
  return 1
}

if [ "${BRANCH_EXISTS}" = "true" ]; then
  # Get the current hydrated commit SHA
  HYDRATED_SHA=$(git rev-parse origin/${PROPOSED_BRANCH})

  # Fetch and check the git note - if drySha matches, we can skip entirely
  git fetch origin +${NOTES_REF}:${NOTES_REF} 2>/dev/null || true
  EXISTING_NOTE=$(git notes --ref=${NOTES_REF} show ${HYDRATED_SHA} 2>/dev/null || echo "{}")
  EXISTING_DRY_SHA=$(echo "${EXISTING_NOTE}" | jq -r '.drySha // ""')

  if [ "${EXISTING_DRY_SHA}" = "${DRY_SHA}" ]; then
    echo "Already hydrated ${ENV} from ${DRY_SHA:0:7}, skipping"
    exit 0
  fi
fi

#
# Note didn't match - need to render and check for changes
#
echo "Rendering manifests for ${ENV} from ${DRY_SHA:0:7}"

# Render manifests
NEW_MANIFESTS=$(mktemp)
kustomize build ./environments/overlays/${ENV} > ${NEW_MANIFESTS}
# Or for Helm:
# helm template my-app ./chart --values ./chart/values-${ENV}.yaml > ${NEW_MANIFESTS}

# Get current manifests from proposed branch for comparison
CURRENT_MANIFESTS=$(mktemp)
if [ "${BRANCH_EXISTS}" = "true" ]; then
  git show origin/${PROPOSED_BRANCH}:manifests.yaml > ${CURRENT_MANIFESTS} 2>/dev/null || true
fi

NEW_GITHUB_WORKFLOW=$(mktemp -d)
cp -r .github $NEW_GITHUB_WORKFLOW/.github

# Compare rendered output
if [ "${BRANCH_EXISTS}" = "true" ] && diff -q ${NEW_MANIFESTS} ${CURRENT_MANIFESTS} > /dev/null 2>&1; then
  #
  # No changes to manifests - just update the git note
  #
  echo "No manifest changes for ${ENV}, updating git note only"

  push_note_with_retry ${HYDRATED_SHA}

  echo "Updated git note on ${HYDRATED_SHA} with drySha ${DRY_SHA}"
else
  #
  # Manifests changed - create new commit with metadata and note
  #
  echo "Manifests changed for ${ENV}, creating new hydrated commit"

  # Checkout proposed branch
  git checkout ${PROPOSED_BRANCH} 2>/dev/null || \
    git checkout -b ${PROPOSED_BRANCH} origin/${PROPOSED_BRANCH} 2>/dev/null || \
    git checkout --orphan ${PROPOSED_BRANCH}

  # Clear existing files and copy new manifests but leave .github folder in place for validation
  git rm -rf . 2>/dev/null || true

  cp ${NEW_MANIFESTS} manifests.yaml
  cp -r $NEW_GITHUB_WORKFLOW/.github .github

  # Create hydrator.metadata with full commit info
  cat > hydrator.metadata << EOF
{
  "drySha": "${DRY_SHA}",
  "repoURL": "${REPO_URL}",
  "author": "$(git show -s --format='%an <%ae>' ${DRY_SHA})",
  "date": "$(git show -s --format='%aI' ${DRY_SHA})",
  "subject": $(git show -s --format='%s' ${DRY_SHA} | jq -Rs .),
  "body": $(git show -s --format='%b' ${DRY_SHA} | jq -Rs .)
}
EOF

  # Commit
  git add -A
  git commit -m "Hydrate ${ENV} from ${DRY_SHA:0:7}"

  HYDRATED_SHA=$(git rev-parse HEAD)

  # Push branch, then update notes ref with retry for concurrent writers
  git push origin ${PROPOSED_BRANCH}
  push_note_with_retry ${HYDRATED_SHA}

  echo "Created hydrated commit ${HYDRATED_SHA}"
fi

rm -f ${NEW_MANIFESTS} ${CURRENT_MANIFESTS}
