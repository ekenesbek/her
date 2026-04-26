# Meta App

## Project Notes

- Future memory references: [docs/memory-landscape.md](docs/memory-landscape.md)
- Web MCP product focus: [docs/web-mcp-focus.md](docs/web-mcp-focus.md)
- Credential broker: [docs/credential-broker.md](docs/credential-broker.md)
- Todo: [docs/todo.md](docs/todo.md)

## Getting Started

Product launch with browser runtime checks:

```bash
pnpm launch
```

Plain Next.js dev server without setup checks:

```bash
pnpm dev
```

Browser setup and diagnostics:

```bash
pnpm browser:setup
pnpm browser:doctor
```

`pnpm launch` starts Next.js with `CHROME_MCP_URL=http://127.0.0.1:12306/mcp`. `browser:setup` registers the Chrome native messaging host and writes `.env.local` if needed.

Open [http://localhost:3000](http://localhost:3000) after launch.

## Browser Agents

Agents with `chrome_browser` use the live Chrome MCP endpoint. Claude and Codex receive that endpoint from the app at runtime.

Codex also receives `mcp_servers.chrome.default_tools_approval_mode="approve"` so MCP browser calls do not fail as `user cancelled MCP tool call` in headless execution.

Safety rule: agents may navigate, search, fill drafts, and read pages, but must stop before irreversible actions such as send, archive, delete, purchase, or taxi order confirmation.

## Testing

```bash
pnpm lint
pnpm build
```
