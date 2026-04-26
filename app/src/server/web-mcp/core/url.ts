import { createHash } from "node:crypto";

const COMMON_SECOND_LEVEL_TLDS = new Set(["ac", "co", "com", "edu", "gov", "net", "org"]);
const MULTITENANT_SUFFIXES = [
  "firebaseapp.com",
  "github.io",
  "netlify.app",
  "pages.dev",
  "vercel.app",
  "web.app",
];
const SITE_FAMILY_HOST_ALIASES = new Map([
  ["notion.com", "notion.so"],
]);
const VOLATILE_QUERY_KEYS = new Set([
  "from",
  "indoorLevel",
  "ll",
  "lr",
  "mode",
  "rtext",
  "rtt",
  "ruri",
  "source",
  "utm_campaign",
  "utm_content",
  "utm_medium",
  "utm_source",
  "utm_term",
  "z",
]);

export type WebPageIdentity = {
  siteFamilyHost: string;
  pageKey: string;
  pageKind: string;
  canonicalUrl: string;
  artifactSegments: string[];
};

export function normalizeUrl(rawUrl: string) {
  const url = new URL(rawUrl);
  url.hash = "";
  return url;
}

export function slugifySegment(value: string, max = 64) {
  const normalized = value
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, max);
  return normalized || "item";
}

export function sanitizeHost(value: string) {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9.-]+/g, "-")
    .replace(/^-+|-+$/g, "") || "site";
}

export function shortHash(value: string) {
  return createHash("sha1").update(value).digest("hex").slice(0, 10);
}

export function safeDecode(value: string) {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

export function getSiteFamilyHost(hostname: string) {
  const host = sanitizeHost(hostname);
  if (MULTITENANT_SUFFIXES.some((suffix) => host !== suffix && host.endsWith(`.${suffix}`))) {
    return canonicalizeSiteFamilyHost(host);
  }

  const parts = host.split(".").filter(Boolean);
  if (parts.length <= 2) return canonicalizeSiteFamilyHost(host);

  const [tld, second, third] = parts.slice(-3).reverse();
  if (tld.length === 2 && COMMON_SECOND_LEVEL_TLDS.has(second) && third) {
    return canonicalizeSiteFamilyHost(parts.slice(-3).join("."));
  }

  return canonicalizeSiteFamilyHost(parts.slice(-2).join("."));
}

export function canonicalizeSiteFamilyHost(value: string) {
  const host = sanitizeHost(value);
  return SITE_FAMILY_HOST_ALIASES.get(host) ?? host;
}

export function getSiteFamilyOrigin(url: URL) {
  const familyHost = getSiteFamilyHost(url.hostname);
  return `${url.protocol}//${familyHost}${url.port ? `:${url.port}` : ""}`;
}

export function getSiteKeyFromUrl(rawUrl: string) {
  const url = normalizeUrl(rawUrl);
  const familyHost = getSiteFamilyHost(url.hostname);
  return `${sanitizeHost(familyHost)}--${shortHash(getSiteFamilyOrigin(url))}`;
}

export function getPageIdentity(rawUrl: string): WebPageIdentity {
  const url = normalizeUrl(rawUrl);
  const siteFamilyHost = getSiteFamilyHost(url.hostname);
  const pathSegments = url.pathname
    .split("/")
    .filter(Boolean)
    .map((segment) => slugifySegment(safeDecode(segment)));
  const normalizedPathSegments = pathSegments.length > 0 ? pathSegments : ["_root"];
  const yandexMaps = getYandexMapsPageIdentity(url, siteFamilyHost, normalizedPathSegments);
  if (yandexMaps) return yandexMaps;

  const stableQueryKeys = [...new Set([...url.searchParams.keys()])]
    .filter((key) => !VOLATILE_QUERY_KEYS.has(key) && !key.startsWith("utm_"))
    .sort();
  const queryKeySuffix = stableQueryKeys.length > 0
    ? `?queryKeys=${stableQueryKeys.map((key) => encodeURIComponent(key)).join(",")}`
    : "";
  const pageKind = stableQueryKeys.length > 0 ? `query:${stableQueryKeys.join(",")}` : "page";
  const artifactSegments = stableQueryKeys.length > 0
    ? [...normalizedPathSegments, `_query_${slugifySegment(stableQueryKeys.join("-"), 48)}`]
    : normalizedPathSegments;
  const canonicalPath = `/${normalizedPathSegments.filter((segment) => segment !== "_root").join("/")}`;
  const normalizedCanonicalPath = canonicalPath === "/" ? "/" : canonicalPath.replace(/\/$/, "");

  return {
    siteFamilyHost,
    pageKey: `${siteFamilyHost}${normalizedCanonicalPath}${queryKeySuffix}`,
    pageKind,
    canonicalUrl: `${url.protocol}//${siteFamilyHost}${normalizedCanonicalPath}${queryKeySuffix}`,
    artifactSegments,
  };
}

function getYandexMapsPageIdentity(
  url: URL,
  siteFamilyHost: string,
  pathSegments: string[],
): WebPageIdentity | null {
  if (siteFamilyHost !== "yandex.ru" || pathSegments[0] !== "maps") return null;

  const baseSegments = pathSegments.slice(0, 3);
  const mode = url.searchParams.get("mode");
  const isRoute = mode === "routes" || url.searchParams.has("rtext") || url.searchParams.has("rtt");
  const kindSegment = isRoute ? "routes" : mode ? `mode-${slugifySegment(mode, 32)}` : "page";
  const pageKind = isRoute ? "maps-route" : mode ? `maps-${slugifySegment(mode, 32)}` : "maps-page";
  const artifactSegments = [...baseSegments, kindSegment];
  const canonicalPath = `/${baseSegments.join("/")}`;
  const canonicalQuery = isRoute ? "?mode=routes" : mode ? `?mode=${encodeURIComponent(mode)}` : "";

  return {
    siteFamilyHost,
    pageKey: `${siteFamilyHost}${canonicalPath}${canonicalQuery}`,
    pageKind,
    canonicalUrl: `${url.protocol}//${siteFamilyHost}${canonicalPath}${canonicalQuery}`,
    artifactSegments,
  };
}
