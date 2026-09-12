#!/usr/bin/env bash
set -euo pipefail

swift --version
xcodebuild -version
node --version
npm --version
rg --version

npm test
npm run test:package
