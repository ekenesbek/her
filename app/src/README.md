# Source Layers

`src/app` is the Next.js routing layer. It owns pages, layouts, and API route entrypoints.

`src/ui` contains client and presentational components. UI code can import `src/shared` and `src/client`, but must not import `src/server`.

`src/server` contains backend code: auth, database access, filesystem artifacts, agent runtime helpers, and Web MCP storage.

`src/shared` contains serializable contracts, labels, templates, and validation schemas used across routes and UI.

`src/client` contains browser-only utilities such as localStorage and geolocation helpers.

Keep data flow explicit: UI calls API routes, API routes call `src/server`, and both sides share types/schemas through `src/shared`.
