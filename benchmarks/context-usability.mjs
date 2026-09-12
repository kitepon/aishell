// 固定した実在repoで、同じ本文を得るまでのMCP応答量を測る。provider tokenの計測ではない。
import assert from 'node:assert/strict';
import { readFile, mkdtemp, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { withMCP } from '../scripts/setup/mcp-client.mjs';
const [command = 'aishell-mcp', source, output] = process.argv.slice(2);
assert(source && output, 'binary、固定fixture、出力JSONを指定してください。');
const root = resolve(source);
const state = await mkdtemp('/tmp/aishell-context-measure-');
const paths = ['PLAN.md', 'bin/setup-windows-native-factory.ps1', 'bin/agents-update.sh'];
const files = await Promise.all(paths.map(path => readFile(resolve(root, path), 'utf8')));
const fixtureSHA256 = createHash('sha256').update(files.join('\0')).digest('hex');
const summary = { fixtureSHA256, budgets: { read: 15000, search: 14000 }, measurements: {} };
await withMCP({command, args: [], env: {AISHELL_CAPABILITY_SET:'expanded-v1', AISHELL_STATE_DIRECTORY:state}}, async ({initialized,call}) => {
 summary.version = initialized.serverInfo.version;
 function measure() { return { calls:0, contentBytes:0, structuredBytes:0, responseBytes:0 }; }
 async function invoke(metric,name,args) {
  const result = await call(name,args);
  metric.calls++;
  metric.contentBytes += Buffer.byteLength(JSON.stringify(result.content));
  metric.structuredBytes += Buffer.byteLength(JSON.stringify(result.structuredContent));
  metric.responseBytes += Buffer.byteLength(JSON.stringify(result));
  return result;
 }
 const snapshot = await call('workspace_snapshot',{path:root,context_budget:6500,entry_limit:20,project_profile:{mode:'none'},git_diff:{mode:'worktree',include_patch:false,byte_budget:2000}});
 summary.snapshot = { responseBytes:Buffer.byteLength(JSON.stringify(snapshot)), paths:snapshot.structuredContent.context.map(item=>item.path) };
 const readMetric = measure(); let continuation; const received = new Map();
 const requiredPrefixes = files.map(text => text.replace(/^\uFEFF/, '').slice(0,1000));
 do {
  const result = await invoke(readMetric,'read_context',{targets:paths.map(path=>resolve(root,path)),byte_budget:15000,...(continuation?{continuation}:{})});
  const body = result.content.map(item=>item.text??'').join('\n');
  for(const [index,path] of paths.entries()) if(body.includes(requiredPrefixes[index])) received.set(path,true);
  continuation=result.structuredContent.continuation;
  if(received.size===paths.length) break;
 } while(continuation);
 assert.equal(received.size,paths.length,'全対象の先頭1000文字が届くこと');
 summary.measurements.read = {...readMetric,requiredBytes:requiredPrefixes.reduce((n,text)=>n+Buffer.byteLength(text),0),coveredTargets:received.size};
 const broadMetric=measure();
 const broad=await invoke(broadMetric,'search_context',{path:root,queries:[{id:'windows',kind:'regex',
  pattern:'npm|codex-sidecar|Start-Process|scheduled|Log|MultipleInstances|agent-update',include_globs:paths.slice(1),
  before_lines:2,after_lines:3}],byte_budget:14000,max_results:50});
 summary.measurements.broadSearch={...broadMetric,returnedMatches:broad.structuredContent.returnedMatches,
  omittedMatches:broad.structuredContent.omittedMatches,contextBlocks:broad.structuredContent.contextBlocks.length};
 const patterns=['npm','resolve_npm_global_bin()'];
 const selected=files.slice(1);
 const excerpts=selected.map((text,index)=>{
  const lines=text.split('\n');const match=lines.findIndex(line=>line.includes(patterns[index]));assert(match>=0);
  return lines.slice(Math.max(0,match-2),match+4).join('\n');
 });
 const searchMetric=measure();let text='';continuation=undefined;
 do {
  const args=continuation?{continuation}:{path:root,queries:patterns.map((pattern,index)=>({id:`query-${index}`,kind:'fixed',pattern,include_globs:[paths[index+1]],before_lines:2,after_lines:3})),byte_budget:14000,max_results:2};
  const result=await invoke(searchMetric,'search_context',args);
  text+='\n'+result.content.map(item=>item.text??'').join('\n');
  continuation=result.structuredContent.continuation;
  if(excerpts.every(excerpt=>text.includes(excerpt))) break;
 } while(continuation);
 // 周辺コードが検索本文にない旧版は、同じ対象を公開readで取得する。
 if(!excerpts.every(excerpt=>text.includes(excerpt))) {
  continuation=undefined;
  do {
   const result=await invoke(searchMetric,'read_context',{targets:paths.slice(1).map(path=>resolve(root,path)),byte_budget:14000,...(continuation?{continuation}:{})});
   text+='\n'+result.content.map(item=>item.text??'').join('\n');
   continuation=result.structuredContent.continuation;
   if(excerpts.every(excerpt=>text.includes(excerpt))) break;
  } while(continuation);
 }
 assert(excerpts.every(excerpt=>text.includes(excerpt)),'両queryの一致行と前2行・後3行が届くこと');
 summary.measurements.search={...searchMetric,requiredBytes:excerpts.reduce((n,item)=>n+Buffer.byteLength(item),0),coveredQueries:2};
},{cwd:root,timeout:180000});
await writeFile(output,JSON.stringify(summary,null,2)+'\n');
console.log(JSON.stringify(summary));
