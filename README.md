# meta

Personal agent prototype for Ray-Ban glasses.

## Structure

The main Next.js app lives in [app](./app).

## Run locally

```bash
cd app
pnpm install
pnpm dev
```

## Browser Agents

Browser workflows are a core product goal; see [Browser workflow test plan](./TEST_PLAN_BROWSER_WORKFLOWS.md).

For agents with `chrome_browser`, the app now expects a Chrome MCP endpoint. Configure it either:

- in-app at `/settings/browser`
- globally via `CHROME_MCP_URL`

With `mcp-chrome-bridge`, the default local URL is `http://127.0.0.1:12306/mcp`. The older `CHROME_MCP_SSE_URL` env var is still accepted for compatibility with SSE-only setups.

Once configured, Claude and Codex-backed browser agents receive the MCP server at runtime and should execute tasks in the user's live browser session instead of replying with external setup instructions.

## Docs

- [Browser workflow test plan](./TEST_PLAN_BROWSER_WORKFLOWS.md)
