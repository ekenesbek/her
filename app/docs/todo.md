# Todo

## Product MCP Registry and Connected Services

- Add a product MCP registry for services such as Notion, GitHub, Gmail, Slack, and similar products.
- Research existing registry/catalog options before building a custom registry.
- Store registry metadata:
  - product name and domains
  - MCP server package or endpoint
  - official/community/provider status
  - auth method: OAuth, browser login, API token, or user-provided secret
  - required scopes and capabilities
  - safety boundaries for read/write/irreversible actions
  - setup status and last health check
- Before using a website-only flow, the agent should check whether the requested product has a known MCP integration.
- If an MCP exists for the product, the agent should start the connection flow:
  - open the product auth/setup page in the browser when user presence is required
  - let the user complete login, consent, passkey, or 2FA steps
  - guide API token creation when OAuth is not available
  - never expose plaintext tokens, passwords, cookies, or recovery codes to the model
- After authorization, add the product to Connected Services with:
  - product name
  - connection type: MCP
  - granted scopes/capabilities
  - account hint
  - status, expiry, and revoke action
- Connected Services should show both web/browser products and MCP-backed products.
- If no MCP integration is available, continue with the existing Web MCP/browser workflow and optionally record a registry candidate for later.
- Use Credential Broker rules for all secret handling and approval events.
- Keep Web MCP graph memory separate from product MCP credentials, but allow Connected Services to link them by product/domain.
