const RIDE_HAILING_PATTERN =
  /(?:такси|таксомотор|машин[ауые]|поездк[ауи]|ехать|доехать|домой|ride[-\s]?hail|ride\s?share|\btaxi\b|\bcab\b|\buber\b|\blyft\b|\bbolt\b|\bindrive\b)/i;

const ORDER_INTENT_PATTERN =
  /(?:закажи|заказать|вызови|вызвать|оформи|оформить|подбери|выбери|найди|book|order|call|get|request|find)/i;

const HOME_DESTINATION_PATTERN = /(?:домой|до\s+дома|\bhome\b)/i;
const WORK_DESTINATION_PATTERN = /(?:на\s+работу|до\s+офиса|в\s+офис|\bwork\b|\boffice\b)/i;

export function detectBrowserWorkflow(message) {
  const normalized = normalize(message);
  if (!normalized) return null;

  if (RIDE_HAILING_PATTERN.test(normalized) && ORDER_INTENT_PATTERN.test(normalized)) {
    return {
      kind: "ride_hailing",
      destinationAlias: detectDestinationAlias(normalized),
    };
  }

  return null;
}

/**
 * @param {{
 *   latestUserMessage?: string;
 *   exactBrowserLocationPresent?: boolean;
 * }} [options]
 */
export function buildBrowserWorkflowRuntimeContext({
  latestUserMessage,
  exactBrowserLocationPresent = false,
} = {}) {
  const workflow = detectBrowserWorkflow(latestUserMessage);
  if (!workflow) return "";

  if (workflow.kind === "ride_hailing") {
    return buildRideHailingRuntimeContext({ workflow, exactBrowserLocationPresent });
  }

  return "";
}

function buildRideHailingRuntimeContext({ workflow, exactBrowserLocationPresent }) {
  return [
    "Workflow hint: ride-hailing / taxi order.",
    "Treat this as a browser-first transactional workflow: use Chrome MCP, not shell or generic web instructions.",
    exactBrowserLocationPresent
      ? "Pickup: exact browser location is already available. Use it as the pickup/current location unless the latest user message gives another pickup."
      : "Pickup: if no exact browser location, first look for an explicit pickup in the latest message or reliable memory; otherwise ask one concise pickup question.",
    workflow.destinationAlias
      ? `Destination: the user referred to ${workflow.destinationAlias}. Resolve it from confirmed user memory first, then from saved places visible inside the logged-in taxi/maps surface. If it is still unknown, ask only for that destination.`
      : "Destination: use the latest user message, confirmed memory, or saved places visible inside the logged-in taxi/maps surface. If destination is missing, ask only for that field.",
    "Provider discovery: prefer remembered Web MCP/site memory, currently open logged-in tabs, and services visible in the user's browser session. If no provider is known, search/open a local ride-hailing web booking surface that matches the user's locale and browser language. Do not assume a single fixed provider.",
    "Execution: open the provider website/PWA in Chrome, use the logged-in session when available, set pickup and destination, gather ETA/price/class options, and choose a sensible default from the user's preferences and current evidence.",
    "Safety: never click the final order/confirm/payment button without explicit confirmation in chat. Stop at the review screen with pickup, destination, provider, class, ETA, price, payment method visibility, and the exact final action awaiting confirmation.",
    "If the provider requires native mobile app only, login/MFA/captcha, missing saved destination, or unavailable service area, report that concrete blocker and the shortest next step.",
  ].join("\n");
}

function detectDestinationAlias(normalized) {
  if (HOME_DESTINATION_PATTERN.test(normalized)) return "home";
  if (WORK_DESTINATION_PATTERN.test(normalized)) return "work/office";
  return null;
}

function normalize(value) {
  return typeof value === "string" ? value.replace(/\s+/g, " ").trim().toLowerCase() : "";
}
