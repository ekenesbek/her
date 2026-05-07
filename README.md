# Her

Personal agent prototype for Ray-Ban glasses.

## Structure

The main Next.js app lives in [app](./app).

## Run locally

```bash
./launch
```

`./launch` installs app dependencies if needed, configures the Chrome MCP URL, checks the local browser bridge, and starts the app at `http://localhost:3000`.

If you want the explicit steps instead:

```bash
cd app
pnpm browser:setup
pnpm launch
```

## Browser Agents

Browser workflows are a core product goal; see [Browser workflow test plan](./TEST_PLAN_BROWSER_WORKFLOWS.md).

For agents with `chrome_browser`, the app expects a Chrome MCP endpoint. The launch flow writes the default endpoint automatically:

```text
CHROME_MCP_URL=http://127.0.0.1:12306/mcp
```

Diagnostics:

```bash
cd app
pnpm browser:doctor
```

If the endpoint is not connected, open the Chrome MCP extension in Chrome and click `Connect`. Chrome does not allow a local app to silently install or click-enable an extension, so that is the one user-mediated browser step.

Once configured, Claude and Codex-backed browser agents receive the MCP server at runtime and should execute tasks in the user's live browser session instead of replying with external setup instructions.

## Docs

- [Browser workflow test plan](./TEST_PLAN_BROWSER_WORKFLOWS.md)
