const TIME_SENSITIVE_PATTERN =
  /(?:сейчас|сегодня|завтра|актуальн|текущ|в\s+реальном\s+времени|\bcurrent\b|\blatest\b|\btoday\b|\bnow\b)/i;

const STRONG_EXTERNAL_ACTION_PATTERN =
  /(?:закажи|заказать|вызови|вызвать|купи|купить|оформи|оформить|забронируй|забронировать|оплати|оплатить|подключи|подключить|интегрир|сконнект|авторизу|залогин|логин|book|order|buy|checkout|pay|connect|integrate|authorize|login)/i;

const ACCOUNT_OR_SECRET_PATTERN =
  /(?:oauth|токен|token|pat|api\s*key|ключ\s+api|personal access|fine[-\s]?grained|парол|passkey|mfa|2fa|аккаунт|account|billing|settings)/i;

const COMMUNICATION_OR_WORK_ITEM_PATTERN =
  /(?:сообщен|письм|чат|коммент|задач|тикет|issue|pull request|meeting|встреч|событи|календар|email|mail|message|chat|comment|task|ticket|calendar|event)/i;

const EXTERNAL_SURFACE_PATTERN =
  /(?:браузер|chrome|вкладк|страниц|сайт|аккаунт|приложени|сервис|\burl\b|https?:\/\/|\bbrowser\b|\btab\b|\bpage\b|\bsite\b|\baccount\b|\bapp\b|\bservice\b)/i;

const EXTERNAL_DESTINATION_ACTION_PATTERN =
  /(?:напиши|отправь|ответь|создай|добавь|измени|удали|запланируй|send|reply|create|add|update|delete|schedule).*(?:(?:^|\s)(?:в|на|to|in|on)\s+(?!стил[ьея]\b)(?:[a-zа-яё0-9._-]{3,}|https?:\/\/)|@|\+\d{5,}|[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,})/i;

const ROUTE_OR_LOCAL_ACTION_PATTERN =
  /(?:построй|построить|проложи|проложить|найди|покажи|сколько|как\s+долго|долго\s+ли|когда|open|show|build|find).*(?:маршрут|дорог|ехать|доехать|адрес|место|локац|route|directions|map|location|drive|ride|trip)/i;

const LIVE_LOOKUP_PATTERN =
  /(?:проверь|посмотри|найди|открой|сравни|подбери|выбери|оцени|сколько|когда|где|какой|какая|какие|лучший|лучше|варианты|цена|стоимость|доступн|свободн|наличи|\bcheck\b|\bfind\b|\bopen\b|\bcompare\b|\bchoose\b|\boptions\b|\bprice\b|\bavailability\b|\beta\b)/i;

export function normalizeTaskText(message) {
  return typeof message === "string" ? message.replace(/\s+/g, " ").trim().toLowerCase() : "";
}

export function matchesBrowserGroundedTask(message) {
  const normalized = normalizeTaskText(message);
  if (!normalized) return false;
  if (STRONG_EXTERNAL_ACTION_PATTERN.test(normalized)) return true;
  if (ACCOUNT_OR_SECRET_PATTERN.test(normalized)) return true;
  if (EXTERNAL_SURFACE_PATTERN.test(normalized)) return true;
  if (EXTERNAL_DESTINATION_ACTION_PATTERN.test(normalized)) return true;
  if (ROUTE_OR_LOCAL_ACTION_PATTERN.test(normalized)) return true;
  if (TIME_SENSITIVE_PATTERN.test(normalized) && LIVE_LOOKUP_PATTERN.test(normalized)) return true;
  return LIVE_LOOKUP_PATTERN.test(normalized) && COMMUNICATION_OR_WORK_ITEM_PATTERN.test(normalized);
}
