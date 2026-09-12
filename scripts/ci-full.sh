#!/usr/bin/env bash
set -euo pipefail

swift --version
node --version
npm --version
npm test
npm run test:package
