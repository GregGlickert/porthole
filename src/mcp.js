#!/usr/bin/env node
// Porthole MCP server (stdio). Lets Claude label which feature is running on which localhost port.
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import fs from 'node:fs';
import { getBoard, register, updateLabel, remove, suggestFreePorts } from './board.js';

const PKG = JSON.parse(fs.readFileSync(new URL('../package.json', import.meta.url), 'utf8'));

const server = new McpServer(
  { name: 'porthole', version: PKG.version },
  {
    instructions:
      'Porthole tracks which feature/branch is running on which localhost port and shows it in the macOS menu bar. ' +
      'Whenever you start a local dev server (or the user says one is running), call register_server with its port and a short title ' +
      'describing the feature being tested. Before picking a port for a new dev server, call suggest_free_port to avoid collisions. ' +
      'Use list_servers to answer "what is on port X?".',
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
  async ({ port }) => {
    try {
      return json({ removed: remove(port) });
    } catch (err) {
      return fail(err);
    }
  },
);

server.registerTool(
  'list_servers',
  {
    title: 'List dev servers',
    description:
      'List every listening local dev server (ports 3000–9999) with its label, branch, repo folder, uptimeSec and status ' +
      '(labeled | unlabeled | stale — stale means a different checkout now owns the port). ' +
      'Docker-published ports include docker: {container, image, project, service, containerPort}. Pass port to get just one.',
    inputSchema: { port: port.optional() },
  },
  async ({ port: only } = {}) => {
    try {
      const servers = getBoard();
      return json({ servers: only ? servers.filter((s) => s.port === only) : servers });
    } catch (err) {
      return fail(err);
    }
  },
);

server.registerTool(
  'suggest_free_port',
  {
    title: 'Suggest free port',
    description:
      'Return free localhost port(s) in the dev range (default 3000–9999) that nothing is listening on and no label claims. ' +
      'Call this before starting a new dev server so parallel checkouts do not collide.',
    inputSchema: {
      preferred: port.optional().describe('Start searching here, e.g. the framework default 3000'),
      count: z.number().int().min(1).max(20).optional().describe('How many ports to return (default 1)'),
    },
  },
  async ({ preferred, count }) => {
    try {
      return json({ ports: suggestFreePorts({ preferred, count }) });
    } catch (err) {
      return fail(err);
    }
  },
);

await server.connect(new StdioServerTransport());
