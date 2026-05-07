# Web MCP Server Modules

Web MCP is split into small layers so reusable website-memory logic does not depend on the Her product runtime.

## `core/`

Pure Web MCP domain code:

- `types.ts` contains the shared domain DTOs.
- `url.ts` contains site-family, page-key, canonical URL, and artifact-path identity logic.

Core files must not import app auth, chat, identity, Next.js routes, browser runtime, or `.data` filesystem policy.

## `product/`

Integration with this product:

- `storage.ts` binds Web MCP to `.data/web-mcp`.
- `runtime-context.ts` builds the prompt/runtime context injected into agents.
- `chrome-recorder.ts` adapts Chrome MCP tool results into Web MCP snapshots.

Product files may import core, app persistence, and runtime-specific behavior.

## Compatibility Entrypoints

Top-level `storage.ts`, `recording.ts`, and `types.ts` re-export the product/core modules. They keep existing imports stable while new code should prefer the explicit `core/` or `product/` path when it matters.
