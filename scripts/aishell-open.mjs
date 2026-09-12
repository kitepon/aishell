#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const packageDirectory = path.dirname(scriptDirectory);
const appPath = path.join(packageDirectory, "dist", "AIShell.app");

const result = spawnSync("/usr/bin/open", [appPath], {
  stdio: "inherit"
});

if (result.error) {
  throw result.error;
}

if (result.status !== 0) {
  throw new Error(`AIShell.app launch failed with status ${result.status}`);
}
