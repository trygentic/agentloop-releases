#!/bin/bash
set -euo pipefail
umask 077
[[ "$BUILD_RUN" =~ ^[0-9]+$ && "$RELEASE_TAG" =~ ^launcher-v[0-9]+\.[0-9]+\.[0-9]+-pilot\.[1-9][0-9]*$ ]]
mkdir "$RUNNER_TEMP/launcher"
cd "$RUNNER_TEMP/launcher"
test "$(gh api "repos/$SOURCE" --jq .private)" = true
gh api "repos/$SOURCE/actions/runs/$BUILD_RUN" > run.json
jq -e --arg repo "$SOURCE" '
  .repository.full_name == $repo and .head_repository.full_name == $repo and
  .head_branch == "main" and .event == "workflow_dispatch" and
  .path == ".github/workflows/unrest-founder-chat-release.yml" and
  .status == "completed" and .conclusion == "success" and .run_attempt == 1
' run.json >/dev/null
sha=$(jq -er '.head_sha | select(test("^[0-9a-f]{40}$"))' run.json)
# Main may have advanced while the application was compiling.
gh api "repos/$SOURCE/compare/$sha...main" --jq .status | grep -Eq '^(ahead|identical)$'
test -z "$(gh api "repos/$SOURCE/git/matching-refs/tags/$RELEASE_TAG" | jq -r --arg ref "refs/tags/$RELEASE_TAG" '.[] | select(.ref == $ref) | .ref')"
printf '%s\n' "$sha" > source-sha
gh api "repos/$SOURCE/actions/runs/$BUILD_RUN/artifacts" | jq -e '
  [.artifacts[] | select(.name == "intermediate-unsigned" and .expired == false)] |
  select(length == 1) | first' > artifact.json
id=$(jq -er '.id | numbers' artifact.json)
digest=$(jq -er '.digest | select(test("^sha256:[a-f0-9]{64}$")) | ltrimstr("sha256:")' artifact.json)
gh api "repos/$SOURCE/actions/artifacts/$id/zip" > artifact.zip
printf '%s  artifact.zip\n' "$digest" | shasum -a 256 -c -
unzip -p artifact.zip unsigned-for-notarization.zip > app.zip
ditto -x -k app.zip unpacked
app='unpacked/Unrest Founder Chat.app'
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")" = ai.trygentic.unrest.founder-pilot
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ "$RELEASE_TAG" == "launcher-v$version-pilot."* ]]
# Only run the reviewed signing helper. Never execute the downloaded application in the signer.
gh api -H 'Accept: application/vnd.github.raw+json' \
  "repos/$SOURCE/contents/unrest-launcher/scripts/reader-release/sign_runtime.py?ref=$sha" > sign_runtime.py
echo 'dd70a5d199344c149b811aff59d0450501d175020864c83725c1f7600dc385ae  sign_runtime.py' | shasum -a 256 -c -
