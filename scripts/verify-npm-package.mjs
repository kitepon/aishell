#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { access, mkdir, mkdtemp, readFile, readdir, rm, symlink } from "node:fs/promises";
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
  "dist/aishell-mcp"
);
assert.equal(packageMetadata.bin["aishell-open"], undefined);
assert.ok(packageMetadata.files.includes("dist/aishell-run-supervisor"));
assert.equal(packageMetadata.bin["aishell-setup"], "scripts/aishell-setup.mjs");
for (const file of ["scripts/aishell-setup.mjs", "scripts/setup/hosts.mjs", "scripts/setup/host-cli.mjs", "scripts/setup/setup.mjs", "scripts/setup/mcp-client.mjs", "scripts/setup/toml-registration.mjs"]) {
  assert.ok(packageMetadata.files.includes(file), `${file}をnpm payloadへ含める必要があります。`);
  await access(path.join(projectDirectory, file));
}

await access(path.join(projectDirectory, packageMetadata.bin["aishell-mcp"]));

// install scriptは持たない。npm 11.17.0はglobal installでも自package自身のinstall scriptを
// 既定でblockし（allow-scripts未設定で `npm warn allow-scripts` のみ出る）、宣言するだけで
// 全installへ警告行が増える。0.4.4のpostinstall警告を0.4.5で撤回した経緯はADR 0029に記録。
// setupと通常利用は管理UIを起動しない。
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

// bare commandで配布物を起動し、UIがなくても診断がreadyになることを確かめる。
const payloadBinary = path.join(projectDirectory, "dist", "aishell-mcp");
const symbols = execFileSync("/usr/bin/nm", ["-u", payloadBinary], { encoding: "utf8" });
assert.doesNotMatch(symbols, /SecItem|SecKeychain/, "配布binaryはKeychain APIへ依存しない");
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
      env: { ...process.env, PATH: `${pathDirectory}:${process.env.PATH}`, AISHELL_TOOL_PROFILE: "factory", AISHELL_CAPABILITY_SET: undefined },
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
    "not_required",
    "管理UIは配布とreadyの条件にしない"
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
  await withMCP({ command: "aishell-mcp", args: [], env: { AISHELL_CAPABILITY_SET: "expanded-v1", AISHELL_TOOL_PROFILE: "full" } }, async ({ call, request }) => {
    assert.equal((await request("tools/list", {})).tools.length, 29, "削除前の全tool名を配布物でも保持する");
    const snapshot = (await call("workspace_snapshot", { path: work, context_budget: 0, entry_limit: 10, project_profile: { mode: "none" } })).structuredContent;
    const content = "認証なしの編集\n日本語 $HOME; *";
    const applied = (await call("apply_change_set", {
      path: work, workspace_cursor: snapshot.cursor,
      changes: [{ change_id: "packed-create", operation: "create", path: "edited.txt",
        expected: { state: "absent" }, content: { encoding: "utf8", data: content } }]
    })).structuredContent;
    assert.equal(applied.status, "committed");
    assert.equal(await readFile(path.join(work, "edited.txt"), "utf8"), content);
    const stateParent = path.join(packedDirectory, "state", "apply-change-set-local-v1");
    const roots = await readdir(stateParent);
    assert.equal(roots.length, 1);
    const stateRoot = path.join(stateParent, roots[0]);
    await assert.rejects(access(path.join(stateRoot, "state-key")), { code: "ENOENT" });
    const stored = JSON.parse(await readFile(path.join(stateRoot, "apply-change-set-state.enc.json"), "utf8"));
    assert.equal(stored.schema, "aishell.apply-change-set-core-state.v1");
    assert.equal(stored.ciphertext, undefined, "編集状態は鍵を作らずJSONで保存する");
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
