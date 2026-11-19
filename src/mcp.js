#!/usr/bin/env node
// Portboard MCP server (stdio). Lets Claude label which feature is running on which localhost port.
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import { getBoard, register, updateLabel, remove } from './board.js';

const server = new McpServer(
  { name: 'portboard', version: '0.1.0' },
  {
    instructions:
      'Portboard tracks which feature/branch is running on which localhost port and shows it in the macOS menu bar. ' +
      'Whenever you start a local dev server (or the user says one is running), call register_server with its port and a short title ' +
      'describing the feature being tested. Use list_servers to answer "what is on port X?".',
  },
);

const json = (obj) => ({ content: [{ type: 'text', text: JSON.stringify(obj, null, 2) }] });
const fail = (err) => ({ content: [{ type: 'text', text: `Error: ${err.message}` }], isError: true });
const port = z.number().int().min(1).max(65535).describe('localhost port, e.g. 3001');

server.registerTool(
  'register_server',
  {
    title: 'Register dev server',
    description:
      'Label a running local dev server with the feature it is serving. Branch and working directory are detected automatically. ' +
      'Waits up to 10s for the port to start listening. Overwrites any existing label on that port.',
    inputSchema: {
      port,
      title: z.string().min(1).max(80).describe('Short (≤8 words) feature summary, e.g. "Upload retry flow"'),
      description: z.string().max(500).optional().describe('Optional 1–2 sentence detail of what to test'),
    },
  },
  async (args) => {
    try {
      return json({ registered: await register(args) });
    } catch (err) {
      return fail(err);
    }
  },
);

server.registerTool(
  'update_server',
  {
    title: 'Update dev server label',
    description: 'Change the title and/or description of an already-registered port.',
    inputSchema: { port, title: z.string().min(1).max(80).optional(), description: z.string().max(500).optional() },
  },
  async (args) => {
    try {
      return json({ updated: updateLabel(args) });
    } catch (err) {
      return fail(err);
    }
  },
);

server.registerTool(
  'remove_server',
  {
    title: 'Remove dev server label',
    description: 'Clear the label for a port (does not stop the server).',
    inputSchema: { port },
  },
  async ({ port }) => json({ removed: remove(port) }),
);

server.registerTool(
  'list_servers',
  {
    title: 'List dev servers',
    description:
      'List every listening local dev server (ports 3000–9999) with its label, branch, repo folder and status ' +
      '(labeled | unlabeled | stale — stale means a different checkout now owns the port).',
    inputSchema: {},
  },
  async () => {
    try {
      return json({ servers: getBoard() });
    } catch (err) {
      return fail(err);
    }
  },
);

await server.connect(new StdioServerTransport());
