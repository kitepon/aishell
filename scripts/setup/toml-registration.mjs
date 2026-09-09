import { parseForESLint } from 'toml-eslint-parser';
import { stringify } from 'smol-toml';

const target = ['mcp_servers', 'aishell'];
const prefix = (left, right) => left.every((key, index) => right[index] === key);
const keyPath = node => node.keys.map(key => key.type === 'TOMLBare' ? key.name : key.value);

export function replaceTopLevelValue(text, key, value) {
  const { ast } = parseForESLint(text);
  const node = ast.body[0].body.find(node => node.type === 'TOMLKeyValue' && keyPath(node.key).length === 1 && keyPath(node.key)[0] === key);
  if (!node) throw new Error('トップレベルの設定値を特定できません。');
  return text.slice(0, node.value.range[0]) + inline(value) + text.slice(node.value.range[1]);
}

function inline(value) {
  if (Array.isArray(value)) return `[${value.map(inline).join(', ')}]`;
  if (value && typeof value === 'object' && !(value instanceof Date)) return `{ ${Object.entries(value).map(([key, item]) => `${JSON.stringify(key)} = ${inline(item)}`).join(', ')} }`;
  return stringify({ value }).slice('value = '.length).trim();
}

// 構文木の範囲だけを変更し、別server、コメント、float/date表記をそのまま残す。
// 複数行文字列にある偽のtable headerを正規表現で誤認しない。
export function replaceTOMLRegistration(text, registration) {
  const { ast } = parseForESLint(text);
  const edits = [];
  let replaced = false;
  function visitKeyValue(node, base) {
    const keys = [...base, ...keyPath(node.key)];
    if (keys.length === target.length && prefix(target, keys)) {
      edits.push({ range: node.value.range, text: inline(registration) });
      replaced = true;
    } else if (prefix(target, keys)) {
      edits.push({ range: node.range, text: '' });
    } else if (prefix(keys, target) && node.value.type === 'TOMLInlineTable') {
      for (const child of node.value.body) visitKeyValue(child, keys);
      if (!replaced) {
        const at = node.value.range[1] - 1;
        edits.push({ range: [at, at], text: `${node.value.body.length ? ', ' : ''}${JSON.stringify(target.at(-1))} = ${inline(registration)}` });
        replaced = true;
      }
    }
  }
  for (const node of ast.body[0].body) {
    if (node.type === 'TOMLTable') {
      if (prefix(target, node.resolvedKey)) edits.push({ range: node.range, text: '' });
      else for (const child of node.body) visitKeyValue(child, node.resolvedKey);
    } else visitKeyValue(node, []);
  }
  let result = text;
  for (const edit of edits.sort((a, b) => b.range[0] - a.range[0])) result = result.slice(0, edit.range[0]) + edit.text + result.slice(edit.range[1]);
  if (!replaced) result += `\n${stringify({ mcp_servers: { aishell: registration } })}`;
  return result;
}
