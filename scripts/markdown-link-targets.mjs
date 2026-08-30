import { posix } from "node:path";
import { parseFragment } from "parse5";
import parseSrcset from "parse-srcset";
import remarkGfm from "remark-gfm";
import remarkParse from "remark-parse";
import { unified } from "unified";

const markdownParser = unified().use(remarkParse).use(remarkGfm);

export function documentTargets(source) {
  const tree = markdownParser.parse(source);
  const definitions = new Map();
  walkMarkdown(tree, (node) => {
    if (
      node.type === "definition"
      && typeof node.identifier === "string"
      && typeof node.url === "string"
      && !definitions.has(node.identifier)
    ) {
      definitions.set(node.identifier, node.url);
    }
  });

  const targets = [];
  walkMarkdown(tree, (node) => {
    if ((node.type === "link" || node.type === "image") && typeof node.url === "string") {
      targets.push(node.url);
    } else if (
      (node.type === "linkReference" || node.type === "imageReference")
      && typeof node.identifier === "string"
    ) {
      const target = definitions.get(node.identifier);
      if (target !== undefined) targets.push(target);
    } else if (node.type === "html" && typeof node.value === "string") {
      targets.push(...htmlTargets(node.value));
    }
  });
  return targets;
}

export function localMarkdownTargets(source) {
  return documentTargets(source)
    .filter((target) => target && !/^(?:[a-z][a-z0-9+.-]*:|#|\/\/)/i.test(target))
    .map((target) => {
      const pathname = target.split("#", 1)[0].split("?", 1)[0];
      if (!pathname) return null;
      try {
        return decodeURIComponent(pathname);
      } catch {
        throw new Error(`不正なlink URIがあります: ${target}`);
      }
    })
    .filter(Boolean);
}

export function assertPackedMarkdownClosed(files, markdownPath, source) {
  const packedFiles = [...files];
  for (const raw of localMarkdownTargets(source)) {
    const normalized = posix.normalize(raw.startsWith("/")
      ? raw.slice(1)
      : posix.join(posix.dirname(markdownPath), raw));
    const target = normalized === "." ? normalized : normalized.replace(/\/+$/, "");
    if (target === ".") continue;
    if (target === ".." || target.startsWith("../")) {
      throw new Error(`package外を参照しています: ${raw}`);
    }
    if (!files.has(target) && !packedFiles.some((file) => file.startsWith(`${target}/`))) {
      throw new Error(`${markdownPath} -> ${raw}`);
    }
  }
}

function htmlTargets(source) {
  const targets = [];
  walkHtml(parseFragment(source), (node) => {
    for (const attribute of node.attrs ?? []) {
      if (attribute.name === "href" || attribute.name === "src") {
        targets.push(attribute.value);
      } else if (attribute.name === "srcset") {
        targets.push(...parseSrcset(attribute.value).map((candidate) => candidate.url));
      }
    }
  });
  return targets;
}

function walkMarkdown(node, visit) {
  visit(node);
  for (const child of node.children ?? []) walkMarkdown(child, visit);
}

function walkHtml(node, visit) {
  visit(node);
  for (const child of node.childNodes ?? []) walkHtml(child, visit);
  if (node.content) walkHtml(node.content, visit);
}
