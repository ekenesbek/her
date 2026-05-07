# Credential Broker

Product and implementation note for brokered credential use by browser agents.

## Current Shape

Credential Broker is a privileged approval layer between the agent and user credentials.

The agent does not receive plaintext passwords, passkeys, cookies, recovery codes, or keychain material in its prompt, tool result, trace, or Web MCP memory.

The first implementation supports:

- `credential_broker` agent capability
- user-scoped credential approval requests
- approve/deny UI in the task timeline
- Claude SDK MCP tool: `her_credentials.request_credential_approval`
- task status transition to `waiting_for_user` while approval is pending
- audit-friendly request records with origin, account hint, reason, action, status, timestamps

## Security Model

The broker is origin-bound and approval-driven.

The UI should always show:

- origin
- current URL, when known
- account hint, when known
- requested action
- reason
- request expiry

The model sees only the approval result and non-secret metadata.

Do not store or expose:

- plaintext password
- passkey private material
- session cookies
- auth headers
- payment card data
- recovery codes

## Current Limitation

This app does not yet have a native Apple Passwords or Keychain bridge.

That means approval currently gives the agent permission to continue the browser task with user-mediated credential access. It does not let the Next.js app read Apple Keychain or silently inject a saved password by itself.

Actual password fill from Apple Passwords requires a separate privileged component, such as:

- native helper
- browser extension integration
- OS-level credential provider integration

That component must keep the same invariant: secrets are applied to the browser surface but never returned to the LLM.

## Next Layer

For real autonomous scheduled jobs, add:

1. Native credential provider bridge.
2. Origin-bound fill operation.
3. Scheduled read-only grants with expiry and revoke.
4. Credential usage audit log.
5. Web MCP auth metadata:
   - `authMode`
   - `scheduledAllowed`
   - `requiresUserPresence`
   - `sensitivity`
   - `lastCredentialUseAt`

Scheduled jobs should be read-only by default and must still stop before irreversible actions.
