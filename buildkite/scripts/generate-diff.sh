#!/bin/bash

# Base against origin/develop by default, but use pull-request base otherwise
BASE=${BUILDKITE_PULL_REQUEST_BASE_BRANCH:-origin/develop}

# Finds the commit hash of HEAD of $BASE branch
BASECOMMIT=$(git log $BASE -1 --pretty=format:%H)
# Finds the commit hash of HEAD of the current branch
COMMIT=$(git log -1 --pretty=format:%H)
# Use buildkite commit instead when its defined
[[ -n "$BUILDKITE_COMMIT" ]] && COMMIT=${BUILDKITE_COMMIT}

# Print it for logging/debugging
echo "Diffing current commit: ${COMMIT} against commit: ${BASECOMMIT} from branch: ${BASE} ."

# Compare base to the current commit
if [[ $BASECOMMIT != $COMMIT ]]; then
  # Get the files that have diverged from $BASE
  git diff $BASECOMMIT --name-only
else
  # TODO: Dump commits as artifacts when build succeeds so we can diff against
  # that on develop instead of always running all the tests
  git ls-files
fi

