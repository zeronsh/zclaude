// A minimal MCP server over stdio with one tool, `ask_name`, that asks the user for
// a name through an elicitation. Used by the integration tests:
//
//   claude --mcp-config '{"mcpServers":{"elicit":{"command":"bun","args":["<this file>"]}}}'
//
// No SDK, so the test has no dependencies: JSON-RPC 2.0, one message per line.
import { createInterface } from 'node:readline';

type Message = { jsonrpc: '2.0'; id?: number | string; method?: string; params?: any; result?: any; error?: any };

const send = (message: Omit<Message, 'jsonrpc'>) => process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', ...message })}\n`);
const waiting = new Map<number | string, (message: Message) => void>();
let nextId = 1;

function request(method: string, params: unknown): Promise<Message> {
  const id = `server-${nextId++}`;
  send({ id, method, params });
  return new Promise((resolve) => waiting.set(id, resolve));
}

async function handle(message: Message): Promise<void> {
  if (message.method === undefined) {
    waiting.get(message.id!)?.(message);
    waiting.delete(message.id!);
    return;
  }
  switch (message.method) {
    case 'initialize':
      send({
        id: message.id,
        result: {
          protocolVersion: message.params?.protocolVersion ?? '2025-06-18',
          capabilities: { tools: {} },
          serverInfo: { name: 'elicit', version: '1.0.0' },
        },
      });
      return;
    case 'tools/list':
      send({
        id: message.id,
        result: {
          tools: [
            {
              name: 'ask_name',
              description: 'Asks the user for their name and returns it.',
              inputSchema: { type: 'object', properties: {} },
            },
          ],
        },
      });
      return;
    case 'tools/call': {
      const reply = await request('elicitation/create', {
        message: 'What is your name?',
        requestedSchema: { type: 'object', properties: { name: { type: 'string', title: 'Name' } }, required: ['name'] },
      });
      const action = reply.result?.action ?? 'error';
      const text = action === 'accept' ? `name=${reply.result?.content?.name}` : `elicitation ${action}`;
      send({ id: message.id, result: { content: [{ type: 'text', text }] } });
      return;
    }
    case 'ping':
      send({ id: message.id, result: {} });
      return;
    default:
      if (message.id !== undefined) send({ id: message.id, error: { code: -32601, message: `unknown method ${message.method}` } });
  }
}

createInterface({ input: process.stdin }).on('line', (line) => {
  if (!line.trim()) return;
  try {
    void handle(JSON.parse(line));
  } catch {}
});
