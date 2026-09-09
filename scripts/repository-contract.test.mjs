import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { access, readFile, readdir, stat } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  assertPackedMarkdownClosed,
  documentTargets,
  localMarkdownTargets,
} from "./markdown-link-targets.mjs";

const projectDirectory = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

const markdownFiles = async (directory, prefix = "") => {
  const found = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if ([".git", ".build", "dist", "node_modules"].includes(entry.name)) continue;
    if (prefix === "rag" && entry.name === "raw") continue;
    const relative = path.posix.join(prefix, entry.name);
    const absolute = path.join(directory, entry.name);
    if (entry.isDirectory()) found.push(...await markdownFiles(absolute, relative));
    else if (/\.md$/i.test(entry.name)) found.push(relative);
  }
  return found;
};

test("CIは製品所有のlocal reusable workflowだけを呼ぶ", async () => {
  const ci = await readFile(path.join(projectDirectory, ".github/workflows/ci.yml"), "utf8");
  const productFull = await readFile(
    path.join(projectDirectory, ".github/workflows/product-full-ci.yml"),
    "utf8"
  );
  assert.match(ci, /uses:\s*\.\/\.github\/workflows\/product-full-ci\.yml/);
  assert.doesNotMatch(ci, /kitepon\/dotagents\/.github\/workflows/);
  assert.match(
    ci,
    /dependency-command:\s*npm ci --ignore-scripts --no-audit --no-fund/,
  );
  assert.match(
    ci,
    /documentation-command:\s*npm ci --force --ignore-scripts --no-audit --no-fund && node --test scripts\/repository-contract\.test\.mjs/,
  );
  assert.equal((productFull.match(/shell:\s*pwsh/g) ?? []).length, 3);
  assert.doesNotMatch(productFull, /Progra~1\\Git\\bin\\bash\.exe/);
  await access(path.join(projectDirectory, ".github/workflows/product-full-ci.yml"));
});

test("main pushのfull CIは後続pushで取り消さず、PRだけを更新できる", async () => {
  const ci = await readFile(path.join(projectDirectory, ".github/workflows/ci.yml"), "utf8");
  assert.match(
    ci,
    /cancel-in-progress:\s*\$\{\{\s*github\.event_name == 'pull_request'\s*\}\}/,
  );
  assert.doesNotMatch(ci, /cancel-in-progress:\s*true/);
});

test("repository内のMarkdownはローカルリンク切れを持たない", async () => {
  const missing = [];
  for (const markdownPath of await markdownFiles(projectDirectory)) {
    const markdown = await readFile(path.join(projectDirectory, markdownPath), "utf8");
    for (const target of localMarkdownTargets(markdown)) {
      const absolute = path.resolve(projectDirectory, path.dirname(markdownPath), target);
      try {
        await stat(absolute);
      } catch {
        missing.push(`${markdownPath} -> ${target}`);
      }
    }
  }
  assert.deepEqual(missing, []);
});

test("Markdown ASTは参照形式・入れ子・HTML資産を抽出しcode例を無視する", () => {
  const targets = documentTargets(`
[![badge](https://example.com/badge.svg)](docs/guide_(v1).md)
![hero][asset]

[asset]: images/hero.png

\`[code](missing-inline.md)\`

\`\`\`md
[code](missing-fence.md)
\`\`\`

<a href="docs/a&amp;b.md"><img src="images/direct.png" srcset="images/one.png 1x, images/two.png 2x"></a>
`);
  assert.deepEqual(targets, [
    "docs/guide_(v1).md",
    "https://example.com/badge.svg",
    "images/hero.png",
    "docs/a&b.md",
    "images/direct.png",
    "images/one.png",
    "images/two.png",
  ]);
  assert.deepEqual(localMarkdownTargets("[外部](https://example.com) [章](#x) [内部](docs/a.md?q=1#x)"), [
    "docs/a.md",
  ]);
});

test("参照形式の不足targetを配布閉包違反として拒否する", () => {
  assert.throws(
    () => assertPackedMarkdownClosed(
      new Set(["README.md"]),
      "README.md",
      "![hero][asset]\n\n[asset]: images/missing.png\n",
    ),
    /README\.md -> images\/missing\.png/,
  );
});

test("npm配布物に入るMarkdownのローカルリンクは配布物内で閉じる", async () => {
  // npm 12はpackage名をkeyにしたobject、旧版はarrayを返す。
  const reports = Object.values(JSON.parse(execFileSync("npm", ["pack", "--dry-run", "--ignore-scripts", "--json"], {
    cwd: projectDirectory,
    encoding: "utf8",
  })));
  assert.equal(reports.length, 1, "配布検査はこのpackageの結果1件を対象にする");
  const packed = reports[0];
  const files = new Set(packed.files.map((entry) => entry.path));
  const missing = [];
  for (const markdownPath of [...files].filter((file) => /\.md$/i.test(file))) {
    const markdown = await readFile(path.join(projectDirectory, markdownPath), "utf8");
    try {
      assertPackedMarkdownClosed(files, markdownPath, markdown);
    } catch (error) {
      missing.push(error.message);
    }
  }
  assert.deepEqual(missing, []);
});

test("CIの外部actionはimmutable commitへ固定する", async () => {
  const workflowDirectory = path.join(projectDirectory, ".github/workflows");
  const workflowNames = (await readdir(workflowDirectory))
    .filter((name) => /\.ya?ml$/.test(name));
  for (const workflowName of workflowNames) {
    const workflow = await readFile(path.join(workflowDirectory, workflowName), "utf8");
    for (const match of workflow.matchAll(/^\s*(?:-\s*)?uses:\s*([^\s#]+)/gm)) {
      const action = match[1];
      if (action.startsWith("./")) {
        continue;
      }
      assert.match(
        action,
        /^[^@\s]+@[0-9a-f]{40}$/i,
        `${workflowName}: external action must use an immutable 40-hex commit: ${action}`
      );
    }
  }
});

test("公開metadataと製品versionはcanonical座標へ揃う", async () => {
  const packageMetadata = JSON.parse(await readFile(path.join(projectDirectory, "package.json"), "utf8"));
  const productSource = await readFile(
    path.join(projectDirectory, "Sources/AIShellCore/FactoryDiagnostics.swift"),
    "utf8"
  );
  const productVersion = productSource.match(/public\s+static\s+let\s+version\s*=\s*"([^"]+)"/)?.[1];
  assert.equal(packageMetadata.version, productVersion);
  assert.equal(packageMetadata.repository.url, "git+https://github.com/kitepon/aishell.git");
  assert.equal(packageMetadata.bugs.url, "https://github.com/kitepon/aishell/issues");
  assert.equal(packageMetadata.homepage, "https://github.com/kitepon/aishell#readme");
  const issueConfig = await readFile(
    path.join(projectDirectory, ".github/ISSUE_TEMPLATE/config.yml"),
    "utf8"
  );
  assert.doesNotMatch(issueConfig, /kitepon-rgb/);
});
