#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { access, mkdir, mkdtemp, readFile, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const projectDirectory = path.dirname(scriptDirectory);
const packageMetadata = JSON.parse(
  await readFile(path.join(projectDirectory, "package.json"), "utf8")
);

assert.equal(packageMetadata.name, "@quolu/aishell");
// versionの単一正本はSwiftのAIShellProduct.version。package.jsonとの一致だけを検証し、
// releaseごとに書き換わるliteralをこのscriptへ二重化しない。
const factoryDiagnosticsSource = await readFile(
  path.join(projectDirectory, "Sources", "AIShellCore", "FactoryDiagnostics.swift"),
  "utf8"
);
const swiftVersion = factoryDiagnosticsSource.match(
  /public\s+static\s+let\s+version\s*=\s*"([^"]+)"/
)?.[1];
assert.ok(swiftVersion, "AIShellProduct.version must be declared in FactoryDiagnostics.swift");
assert.equal(packageMetadata.version, swiftVersion, "package.json must match AIShellProduct.version");
assert.deepEqual(packageMetadata.os, ["darwin"]);
assert.deepEqual(packageMetadata.cpu, ["arm64"]);
assert.equal(
  packageMetadata.bin["aishell-mcp"],
  "dist/AIShell.app/Contents/Helpers/aishell-mcp"
);
assert.equal(packageMetadata.bin["aishell-open"], "scripts/aishell-open.mjs");
assert.equal(packageMetadata.bin["aishell-setup"], "scripts/aishell-setup.mjs");
for (const file of ["scripts/aishell-setup.mjs", "scripts/setup/hosts.mjs", "scripts/setup/host-cli.mjs", "scripts/setup/setup.mjs", "scripts/setup/mcp-client.mjs", "scripts/setup/toml-registration.mjs"]) {
  assert.ok(packageMetadata.files.includes(file), `${file}をnpm payloadへ含める必要があります。`);
  await access(path.join(projectDirectory, file));
}

await access(path.join(projectDirectory, packageMetadata.bin["aishell-mcp"]));

// install scriptは持たない。npm 11.17.0はglobal installでも自package自身のinstall scriptを
// 既定でblockし（allow-scripts未設定で `npm warn allow-scripts` のみ出る）、宣言するだけで
// 全installへ警告行が増える。0.4.4のpostinstall警告を0.4.5で撤回した経緯はADR 0029に記録。
// 開いたままupgradeされた窓の検知はapp側（InstallationIntegrity）が正である。
assert.ok(
  !("postinstall" in (packageMetadata.scripts ?? {})),
  "no postinstall: npm blocks install scripts by default, so declaring one only adds a warning"
);
for (const lifecycle of ["preinstall", "install", "postinstall"]) {
  assert.ok(
    !(lifecycle in (packageMetadata.scripts ?? {})),
    `${lifecycle} must stay absent so a plain install runs no script`
  );
}

const infoPlist = await readFile(
  path.join(projectDirectory, "dist", "AIShell.app", "Contents", "Info.plist"),
  "utf8"
);

assert.match(
  infoPlist,
  new RegExp(`<key>CFBundleShortVersionString</key>\\s*<string>${packageMetadata.version}</string>`)
);
// CFBundleVersionはsemantic versionと独立したbuild番号なのでpackage.jsonから導出できない。
// Packaging/Info.plistを単一正本とし、payloadがそれと一致することだけを検証する。
const sourceInfoPlist = await readFile(
  path.join(projectDirectory, "Packaging", "Info.plist"),
  "utf8"
);
const bundleVersion = sourceInfoPlist.match(
  /<key>CFBundleVersion<\/key>\s*<string>(\d+)<\/string>/
)?.[1];
assert.ok(bundleVersion, "CFBundleVersion must be a positive integer in Packaging/Info.plist");
assert.match(
  infoPlist,
  new RegExp(`<key>CFBundleVersion</key>\\s*<string>${bundleVersion}</string>`)
);

// MCP hostは`aishell-mcp`をbare command名で起動する。argv[0]がpathを含まない起動形式でも
// AIShell.app bundleを解決できることを、payloadの実binaryで確認する。ここが緩むと工場診断が
// manager.application_bundle_unavailable を返し、reporterがAIShellをnot_readyと判定する。
const payloadBinary = path.join(
  projectDirectory, "dist", "AIShell.app", "Contents", "Helpers", "aishell-mcp"
);
const pathDirectory = await mkdtemp(path.join(tmpdir(), "aishell-verify-"));
try {
  await symlink(payloadBinary, path.join(pathDirectory, "aishell-mcp"));
  const request = [
    { jsonrpc: "2.0", id: 1, method: "initialize", params: {
      protocolVersion: "2025-11-25", capabilities: {},
      clientInfo: { name: "verify-npm-package", version: "1.0.0" }
    } },
    { jsonrpc: "2.0", method: "notifications/initialized" },
    { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "factory_diagnostics", arguments: {} } }
  ].map((message) => JSON.stringify(message)).join("\n");

  const stdout = await new Promise((resolve, reject) => {
    const child = spawn("aishell-mcp", [], {
      env: { ...process.env, PATH: `${pathDirectory}:${process.env.PATH}`, AISHELL_TOOL_PROFILE: "factory" },
      stdio: ["pipe", "pipe", "ignore"]
    });
    let output = "";
    child.stdout.on("data", (chunk) => { output += chunk; });
    child.on("error", reject);
    child.on("close", () => resolve(output));
    child.stdin.end(`${request}\n`);
  });

  const diagnostics = stdout.trim().split("\n")
    .flatMap((line) => { try { return [JSON.parse(line)]; } catch { return []; } })
    .find((entry) => entry.id === 2)?.result?.structuredContent;

  assert.ok(diagnostics, "factory_diagnostics must respond when launched by bare command name");
  assert.equal(diagnostics.product.version, packageMetadata.version);
  assert.equal(
    diagnostics.manager.applicationBundleState,
    "available",
    "AIShell.app must resolve when argv[0] carries no directory component"
  );
  assert.ok(
    Object.values(diagnostics.privacy).every((exposed) => exposed === false),
    "factory diagnostics must not expose paths, history, file contents, or process arguments"
  );
  assert.doesNotMatch(stdout, /\/Users\//, "factory diagnostics must not emit absolute paths");
} finally {
  await rm(pathDirectory, { recursive: true, force: true });
}

console.log("npm package metadata and payload are consistent.");

// 実際にpackした内容だけで依存解決とsetupのMCP確認が成立することを確かめる。
// 開発directoryのnode_modulesを参照した成功では、配布file漏れを検出できない。
const packedDirectory = await mkdtemp(path.join(tmpdir(), "aishell-packed-setup-"));
try {
  const packed = Object.values(JSON.parse(execFileSync("npm", ["pack", "--ignore-scripts", "--json", "--pack-destination", packedDirectory], {
    cwd: projectDirectory, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 120000
  })));
  const installDirectory = path.join(packedDirectory, "installed");
  execFileSync("npm", ["install", "--prefix", installDirectory, "--ignore-scripts", "--no-audit", "--no-fund", path.join(packedDirectory, packed[0].filename)], {
    encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 120000
  });
  const bin = path.join(installDirectory, "node_modules/.bin");
  const help = execFileSync(path.join(bin, "aishell-setup"), ["--help"], { encoding: "utf8", timeout: 10000 });
  assert.match(help, /--check/);
  const installedSetup = await import(pathToFileURL(path.join(installDirectory, "node_modules/@quolu/aishell/scripts/setup/setup.mjs")));
  const result = await installedSetup.smoke({ command: "aishell-mcp", args: [], env: { AISHELL_CAPABILITY_SET: "expanded-v1" } }, packageMetadata.version, {
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}` }
  });
  assert.equal(result.ready, true);
  const { withMCP } = await import(pathToFileURL(path.join(installDirectory, "node_modules/@quolu/aishell/scripts/setup/mcp-client.mjs")));
  const work = path.join(packedDirectory, "work"); await mkdir(work);
  await withMCP({ command: "aishell-mcp", args: [], env: { AISHELL_CAPABILITY_SET: "expanded-v1" } }, async ({ call }) => {
    let status = (await call("run_check", {
      schema: "aishell.run-check.v2", cache: "off",
      dispatch: { mode: "start", client_run_key: "packed-bare-supervisor" },
      execution_policy: { timeout_ms: 10000, retention_seconds: 60 },
      invocation: { mode: "direct", executable: "/usr/bin/true", arguments: [], working_directory: work },
      selection: { binding: "prepare" }
    })).structuredContent;
    while (["starting", "running", "finalizing"].includes(status.state)) {
      status = (await call("run_observe", { action: "wait", run_handle: status.runHandle, after_state_revision: status.stateRevision, timeout_ms: 1000 })).structuredContent.status;
    }
    assert.equal(status.state, "passed", "bare起動から同梱supervisorを起動して完了を確認する");
  }, { cwd: work, env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, AISHELL_STATE_DIRECTORY: path.join(packedDirectory, "state") } });
  console.log("配布packageだけでsetup入口・依存解決・MCP実操作を確認しました。");
} finally {
  await rm(packedDirectory, { recursive: true, force: true });
}
