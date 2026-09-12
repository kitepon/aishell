#!/usr/bin/env node

import { cp, mkdir, rm } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const projectDirectory = path.dirname(scriptDirectory);
const packageScript = path.join(projectDirectory, "scripts", "package-app.sh");
const builtApp = path.join(projectDirectory, "build", "AIShell.app");
const distributionDirectory = path.join(projectDirectory, "dist");
const distributionApp = path.join(distributionDirectory, "AIShell.app");

const build = spawnSync(packageScript, ["release"], {
  cwd: projectDirectory,
  stdio: "inherit"
});

if (build.error) {
  throw build.error;
}

if (build.status !== 0) {
  throw new Error(`Release build failed with status ${build.status}`);
}

await rm(distributionDirectory, { recursive: true, force: true });
await mkdir(distributionDirectory, { recursive: true });
await cp(builtApp, distributionApp, {
  recursive: true,
  preserveTimestamps: true
});

console.log(distributionApp);
