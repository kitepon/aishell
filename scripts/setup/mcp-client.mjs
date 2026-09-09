import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

export class SetupError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

// 読戻した登録をそのまま起動する。env値と子process出力は診断へ転載しない。
export async function withMCP(registration, operation, { cwd, env = process.env, timeout = 30000 } = {}) {
  const child = spawn(registration.command, registration.args ?? [], {
    cwd, env: { ...env, ...registration.env }, stdio: ['pipe', 'pipe', 'pipe'],
  });
  const pending = new Map();
  let sequence = 0;
  let failure;
  const fail = (error) => {
    failure = error;
    for (const item of pending.values()) item.reject(error);
    pending.clear();
  };
  child.on('error', () => fail(new SetupError('MCP_START_FAILED', '登録されたMCPを起動できません。PATHと導入状態を確認してください。')));
  child.stdin.on('error', () => fail(new SetupError('MCP_CLOSED', 'MCPの入力が閉じました。')));
  child.stderr.resume();
  const closed = new Promise(resolve => child.once('close', resolve));
  child.once('close', () => fail(new SetupError('MCP_CLOSED', 'MCPが応答完了前に終了しました。')));
  const lines = createInterface({ input: child.stdout });
  lines.on('line', line => {
    let response;
    try { response = JSON.parse(line); }
    catch { fail(new SetupError('MCP_PROTOCOL_INVALID', 'MCPがJSON以外を返しました。')); return; }
    const item = pending.get(response.id);
    if (!item) return;
    pending.delete(response.id);
    if (response.error || response.result?.isError) item.reject(new SetupError('MCP_OPERATION_FAILED', `${item.method}が失敗しました。`));
    else item.resolve(response.result);
  });
  const timer = setTimeout(() => {
    fail(new SetupError('MCP_TIMEOUT', 'MCP応答が制限時間を超えました。'));
    child.kill('SIGTERM');
  }, timeout);
  const request = (method, params) => new Promise((resolve, reject) => {
    if (failure) { reject(failure); return; }
    const id = ++sequence;
    pending.set(id, { resolve, reject, method });
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
  try {
    const initialized = await request('initialize', {
      protocolVersion: '2025-11-25', capabilities: {},
      clientInfo: { name: 'aishell-setup', version: '1' },
    });
    if (initialized?.protocolVersion !== '2025-11-25') throw new SetupError('MCP_PROTOCOL_INVALID', 'MCP protocol versionが一致しません。');
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
    return await operation({ initialized, request, call: (name, args = {}) => request('tools/call', { name, arguments: args }) });
  } finally {
    clearTimeout(timer);
    child.stdin.end();
    const killTimer = setTimeout(() => child.kill('SIGKILL'), 1000);
    child.kill('SIGTERM');
    await closed;
    clearTimeout(killTimer);
    lines.close();
  }
}
