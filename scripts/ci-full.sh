#!/usr/bin/env bash
set -euo pipefail

swift --version
xcodebuild -version
node --version
npm --version
rg --version

task_original_keychain="$(security default-keychain -d user | tr -d '"')"
task_keychain_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
task_keychain_dir="$(mktemp -d "$task_keychain_root/aishell-ci-keychain.XXXXXX")"
task_keychain_path="$task_keychain_dir/ci.keychain-db"

task_restore_keychain() {
  local task_status=$?
  trap - EXIT
  security default-keychain -d user -s "$task_original_keychain" || task_status=1
  security delete-keychain "$task_keychain_path" || task_status=1
  rmdir "$task_keychain_dir" || task_status=1
  exit "$task_status"
}
trap task_restore_keychain EXIT

security create-keychain -p '' "$task_keychain_path"
security set-keychain-settings -lut 1200 "$task_keychain_path"
security unlock-keychain -p '' "$task_keychain_path"
security default-keychain -d user -s "$task_keychain_path"

swift test
scripts/package-app.sh release
npm pack --dry-run
