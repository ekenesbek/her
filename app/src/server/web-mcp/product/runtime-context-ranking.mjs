export function rankWebSitesForGoal(sites, goal, limit = 3) {
  const safeLimit = Math.max(0, Math.floor(limit));
  if (safeLimit === 0) return [];

  return [...sites]
    .map((site) => ({ site, score: scoreWebSiteForGoal(site, goal) }))
    .sort((a, b) => {
      if (b.score !== a.score) return b.score - a.score;
      return (b.site.lastVisitAt ?? b.site.updatedAt ?? 0) - (a.site.lastVisitAt ?? a.site.updatedAt ?? 0);
    })
    .slice(0, safeLimit)
    .map((entry) => entry.site);
}

export function scoreWebSiteForGoal(site, goal) {
  const tokens = tokenizeGoal(goal);
  if (tokens.length === 0) return recencyScore(site);

  const haystack = [
    site.primaryHost,
    site.label,
    site.category,
    site.goal,
    site.seedUrl,
    ...(Array.isArray(site.tags) ? site.tags : []),
  ]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();
  const siteTokens = tokenizeGoal(haystack);

  let score = recencyScore(site);

  for (const token of tokens) {
    if (siteTokens.includes(token)) {
      score += token.length >= 5 ? 4 : 2;
    } else if (haystack.includes(token)) {
      score += token.length >= 5 ? 2 : 1;
    }
  }

  return score;
}

export function tokenizeGoal(goal) {
  if (typeof goal !== "string") return [];
  const normalized = goal.toLowerCase().replace(/[^a-z0-9а-яё]+/giu, " ");
  return [...new Set(normalized.split(/\s+/).filter((token) => token.length >= 3))];
}

function recencyScore(site) {
  if (typeof site?.lastVisitAt !== "number" && typeof site?.updatedAt !== "number") return 0;
  const ts = site.lastVisitAt ?? site.updatedAt;
  const ageDays = Math.max(0, (Date.now() - ts) / 86_400_000);
  if (ageDays <= 1) return 2;
  if (ageDays <= 7) return 1;
  return 0;
}
