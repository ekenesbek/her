"use client";

import { useEffect, useState } from "react";

export type Lang = "en" | "ru";

const STORAGE_KEY = "meta.lang.v1";
const CHANGE_EVENT = "meta:lang-changed";
const DEFAULT: Lang = "en";

export function readLang(): Lang {
  if (typeof window === "undefined") return DEFAULT;
  try {
    const v = window.localStorage.getItem(STORAGE_KEY);
    return v === "en" || v === "ru" ? v : DEFAULT;
  } catch {
    return DEFAULT;
  }
}

export function writeLang(lang: Lang) {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(STORAGE_KEY, lang);
  window.dispatchEvent(new Event(CHANGE_EVENT));
}

export function useLang(): [Lang, (lang: Lang) => void] {
  const [lang, setLang] = useState<Lang>(DEFAULT);

  useEffect(() => {
    setLang(readLang());
    const sync = () => setLang(readLang());
    window.addEventListener(CHANGE_EVENT, sync);
    window.addEventListener("storage", sync);
    return () => {
      window.removeEventListener(CHANGE_EVENT, sync);
      window.removeEventListener("storage", sync);
    };
  }, []);

  return [lang, writeLang];
}

type Dict = Record<string, { en: string; ru: string }>;

export const STRINGS = {
  // login
  "login.signIn": { en: "sign in", ru: "вход" },
  "login.createAccount": { en: "create account", ru: "создать" },
  "login.welcome": { en: "welcome", ru: "привет," },
  "login.welcomeEm": { en: "back", ru: "снова" },
  "login.letsMake": { en: "let’s make", ru: "давай создадим" },
  "login.letsMakeEm": { en: "meta", ru: "meta" },
  "login.youA": { en: "you a", ru: "твой" },
  "login.subSignin": {
    en: "No passwords. Your device proves it’s you with a passkey — Touch ID, Face ID, or security key.",
    ru: "Без паролей. Устройство подтверждает тебя по passkey — Touch ID, Face ID или ключ.",
  },
  "login.subCreate": {
    en: "One tap creates a passkey on this device. You won’t ever type a password for meta.",
    ru: "Одним касанием создашь passkey на этом устройстве. Больше никаких паролей.",
  },
  "login.email": { en: "email", ru: "email" },
  "login.name": { en: "name", ru: "имя" },
  "login.namePlaceholder": { en: "how should I call you", ru: "как тебя называть" },
  "login.ready": { en: "READY", ru: "READY" },
  "login.checking": { en: "CHECK", ru: "CHECK" },
  "login.unavailable": { en: "N/A", ru: "N/A" },
  "login.signinCta": { en: "Sign in with passkey", ru: "Войти по passkey" },
  "login.createCta": { en: "Create passkey", ru: "Создать passkey" },
  "login.signingIn": { en: "Signing in…", ru: "Входим…" },
  "login.creating": { en: "Creating passkey…", ru: "Создаём passkey…" },
  "login.or": { en: "or", ru: "или" },
  "login.securityKey": { en: "Security key", ru: "Ключ безопасности" },
  "login.anotherDevice": { en: "Another device", ru: "Другое устройство" },
  "login.autofillTip": {
    en: "tip · click the email field to pick a saved passkey",
    ru: "подсказка · кликни в email, чтобы выбрать сохранённый passkey",
  },
  "login.newHere": { en: "New here?", ru: "Впервые здесь?" },
  "login.alreadyHave": { en: "Already have one?", ru: "Уже есть meta?" },
  "login.createAMeta": { en: "Create a meta", ru: "Создать meta" },
  "login.notSupported": {
    en: "This browser doesn’t support passkeys. Use a recent Safari, Chrome, Edge or Firefox.",
    ru: "В этом браузере passkeys недоступны. Нужен современный Safari, Chrome, Edge или Firefox.",
  },
  "login.strapline": {
    en: "passkey · webauthn · no password ever leaves this device",
    ru: "passkey · webauthn · пароль никогда не покидает устройство",
  },

  // onboarding
  "onb.step.welcome": { en: "welcome", ru: "знакомство" },
  "onb.step.browser": { en: "browser", ru: "браузер" },
  "onb.step.keys": { en: "autonomy", ru: "автономия" },
  "onb.step.ready": { en: "ready", ru: "готово" },
  "onb.consent.title": { en: "Work", ru: "Работай" },
  "onb.consent.titleEm": { en: "silently.", ru: "без вопросов." },
  "onb.consent.body": {
    en: "Grant standing permissions once. meta acts on your behalf across sites you already use — without tapping you on the shoulder.",
    ru: "Дай разрешения один раз. meta будет действовать за тебя на сайтах, где ты и так уже, без постоянных вопросов.",
  },
  "onb.consent.observe.label": { en: "Observe open tabs", ru: "Наблюдать за вкладками" },
  "onb.consent.observe.hint": { en: "passive discovery", ru: "тихо, без действий" },
  "onb.consent.autoprovision.label": { en: "Auto-connect MCPs", ru: "Подключать MCP сам" },
  "onb.consent.autoprovision.hint": { en: "for services you use", ru: "для твоих сервисов" },
  "onb.consent.autofill.label": { en: "Auto-fill & create logins", ru: "Логины и пароли сам" },
  "onb.consent.autofill.hint": { en: "from vault, passkey-backed", ru: "из vault, под passkey" },
  "onb.consent.outbound.label": { en: "Send messages without asking", ru: "Отправлять без подтверждения" },
  "onb.consent.outbound.hint": { en: "mail, chat, comments", ru: "почта, чаты, комментарии" },
  "onb.consent.finance": {
    en: "Finance & payments always require your confirmation.",
    ru: "Финансы и платежи всегда требуют твоего подтверждения.",
  },
  "onb.welcome.hiHead": { en: "Hi.", ru: "Привет." },
  "onb.welcome.iAmYour": { en: "I’m your", ru: "Я — твой" },
  "onb.welcome.body": {
    en: "I’ll learn to understand you. With your permission — I’ll plug into your browser, keys and contacts, and help where you already live.",
    ru: "Я буду учиться понимать тебя. С твоего разрешения — подключусь к браузеру, ключам и контактам, и буду помогать там, где ты уже живёшь.",
  },
  "onb.welcome.s1": { en: "Connect your browser", ru: "Подключим браузер" },
  "onb.welcome.s1s": { en: "Chrome MCP", ru: "Chrome MCP" },
  "onb.welcome.s2": { en: "Add keys and contacts", ru: "Добавим ключи и контакты" },
  "onb.welcome.s2s": { en: "Apple / Google", ru: "Apple / Google" },
  "onb.welcome.s3": { en: "Assemble your meta", ru: "Соберём твой meta" },
  "onb.welcome.s3s": { en: "one minute", ru: "одна минута" },
  "onb.welcome.go": { en: "Let’s go", ru: "Поехали" },
  "onb.welcome.later": { en: "Later", ru: "Позже" },
  "onb.browser.title": { en: "Connect Chrome.", ru: "Подключи Chrome." },
  "onb.browser.titleEm": { en: "Once.", ru: "Один раз." },
  "onb.browser.body": {
    en: "I’ll use your live session to reach Gmail, calendars, banks — wherever you’re already signed in.",
    ru: "Я буду использовать твою открытую сессию, чтобы ходить в Gmail, календари, банки — туда, где ты уже залогинен.",
  },
  "onb.browser.readTabs": { en: "Read open tabs", ru: "Читать открытые вкладки" },
  "onb.browser.fillForms": { en: "Fill forms", ru: "Заполнять формы" },
  "onb.browser.openPages": { en: "Open new pages", ru: "Открывать новые страницы" },
  "onb.browser.payments": { en: "Make payments", ru: "Совершать платежи" },
  "onb.browser.paymentsHint": { en: "with confirm", ru: "только с подтв." },
  "onb.browser.connect": { en: "Connect Chrome", ru: "Подключить Chrome" },
  "onb.common.back": { en: "← Back", ru: "← Назад" },
  "onb.common.next": { en: "Next", ru: "Далее" },
  "onb.common.skip": { en: "Skip", ru: "Пропустить" },
  "onb.keys.title": { en: "Your", ru: "Твои" },
  "onb.keys.titleEm": { en: "keys", ru: "ключи" },
  "onb.keys.body": {
    en: "Everything lives on your device. meta sees a password only when you allow it — via Touch ID or passkey.",
    ru: "Всё живёт на твоём устройстве. meta видит пароль только когда ты разрешаешь — через Touch ID или passkey.",
  },
  "onb.keys.shield": {
    en: "meta never sees passwords. Only you — via Touch ID / Passkey.",
    ru: "meta никогда не видит пароли. Только ты — через Touch ID / Passkey.",
  },
  "onb.keys.apple": { en: "Apple Keychain", ru: "Apple Keychain" },
  "onb.keys.appleSub": { en: "passkeys + iCloud passwords", ru: "passkeys + пароли из iCloud" },
  "onb.keys.google": { en: "Google Passwords", ru: "Google Passwords" },
  "onb.keys.googleSub": { en: "saved logins from Chrome", ru: "сохранённые логины в Chrome" },
  "onb.keys.contacts": { en: "Contacts", ru: "Контакты" },
  "onb.keys.contactsSub": { en: "Apple / Google contacts", ru: "Apple / Google contacts" },
  "onb.keys.calendar": { en: "Calendar", ru: "Календарь" },
  "onb.keys.calendarSub": { en: "Google · Apple", ru: "Google · Apple" },
  "onb.keys.connect": { en: "Connect", ru: "Подключить" },
  "onb.keys.connecting": { en: "Connecting…", ru: "Подключаем…" },
  "onb.keys.connected": { en: "Connected", ru: "Подключено" },
  "onb.ready.title": { en: "Ready.", ru: "Готов." },
  "onb.ready.titleEm": { en: "Let’s go.", ru: "Поехали." },
  "onb.ready.body": {
    en: "I’ll assemble myself from your keys and permissions. You can change anything later — model, access, tone.",
    ru: "Я соберу себя на основе твоих ключей и разрешений. Можешь менять всё потом — модель, доступы, стиль общения.",
  },
  "onb.ready.assemble": { en: "Assemble meta", ru: "Собрать meta" },
  "onb.ready.assembling": { en: "Assembling…", ru: "Собираю…" },
  "onb.ready.tpl": { en: "personal assistant", ru: "персональный ассистент" },
  "onb.fail.noTpl": { en: "No templates available. Contact admin.", ru: "Нет доступных шаблонов. Обратись к админу." },
  "onb.fail.save": { en: "Couldn’t create agent. Check the console for details.", ru: "Не удалось создать агента. Открой консоль для деталей." },

  // chat
  "chat.nav.talk": { en: "Talk", ru: "Диалог" },
  "chat.nav.webMcp": { en: "Web MCP", ru: "Web MCP" },
  "chat.nav.memory": { en: "Memory", ru: "Память" },
  "chat.nav.vault": { en: "Vault", ru: "Хранилище" },
  "chat.nav.tasks": { en: "Tasks", ru: "Задачи" },
  "chat.nav.settings": { en: "Settings", ru: "Настройки" },
  "chat.chrome.online": { en: "online", ru: "online" },
  "chat.chrome.offline": { en: "offline", ru: "offline" },
  "chat.chrome.personal": { en: "personal", ru: "personal" },
  "chat.chrome.shared": { en: "shared", ru: "shared" },
  "chat.chrome.notLinked": { en: "not linked", ru: "не подключён" },
  "chat.logout": { en: "log out", ru: "выйти" },
  "chat.msgs": { en: "messages · today", ru: "сообщений · сегодня" },
  "chat.msg": { en: "message · today", ru: "сообщение · сегодня" },
  "chat.clear": { en: "clear", ru: "очистить" },
  "chat.clearConfirm": { en: "Clear chat history?", ru: "Очистить историю чата?" },
  "chat.day": { en: "Today", ru: "Сегодня" },
  "chat.empty.title": { en: "What shall we do", ru: "С чего начнём" },
  "chat.empty.titleEm": { en: "today", ru: "сегодня" },
  "chat.empty.body": {
    en: "{name} is ready to work in your browser — ask to check mail, book a ride, or pull up links.",
    ru: "{name} готов работать в браузере — попроси проверить почту, забронировать такси или подобрать ссылки.",
  },
  "chat.thinking": { en: "thinking…", ru: "думаю…" },
  "chat.placeholder": { en: "Say something to {name}…", ru: "Скажи {name}…" },
  "chat.task.showAll": { en: "show all {n} steps", ru: "все {n} шагов" },
  "chat.task.previous": { en: "{n} previous steps", ru: "{n} шагов раньше" },
  "chat.task.waiting": { en: "waiting for you", ru: "ждёт тебя" },
  "chat.task.tokens": { en: "{n} tokens", ru: "{n} токенов" },
  "chat.toolCalls": { en: "{n} tool call", ru: "{n} вызов" },
  "chat.toolCalls_plural": { en: "{n} tool calls", ru: "{n} вызовов" },
  "chat.status.created": { en: "created", ru: "создано" },
  "chat.status.planning": { en: "planning", ru: "план" },
  "chat.status.running": { en: "running", ru: "выполняю" },
  "chat.status.waiting_for_user": { en: "awaiting you", ru: "ждёт тебя" },
  "chat.status.done": { en: "done", ru: "готово" },
  "chat.status.failed": { en: "failed", ru: "ошибка" },
  "chat.status.cancelled": { en: "cancelled", ru: "отменено" },
  "chat.cred.password": { en: "password", ru: "пароль" },
  "chat.cred.passkey": { en: "passkey", ru: "passkey" },
  "chat.cred.session": { en: "session reuse", ru: "повторное использование сессии" },
  "chat.cred.read": { en: "read access", ru: "read доступ" },
  "chat.cred.approve": { en: "allow", ru: "разрешить" },
  "chat.cred.deny": { en: "deny", ru: "отклонить" },
  "chat.cred.pending": { en: "pending", ru: "ожидает" },
  "chat.cred.approved": { en: "approved", ru: "разрешено" },
  "chat.cred.denied": { en: "denied", ru: "отклонено" },
  "chat.cred.expired": { en: "expired", ru: "истекло" },
  "chat.cred.used": { en: "used", ru: "использовано" },
  "chat.error.http": { en: "Request failed", ru: "Ошибка запроса" },
  "chat.stop": { en: "stop", ru: "стоп" },
  "chat.stopped": { en: "stopped", ru: "остановлено" },
  "chat.edit": { en: "edit", ru: "изменить" },
  "chat.save": { en: "save", ru: "сохранить" },
  "chat.cancel": { en: "cancel", ru: "отмена" },
  "chat.queued": { en: "queued · {n}", ru: "в очереди · {n}" },

  // agent settings
  "settings.backToChat": { en: "← Back to chat", ru: "← Назад в чат" },
  "settings.openChat": { en: "Open chat →", ru: "Открыть чат →" },
  "settings.title": { en: "Agent settings", ru: "Настройки агента" },
  "settings.name": { en: "Name", ru: "Имя" },
  "settings.description": { en: "Description", ru: "Описание" },
  "settings.model": { en: "Model", ru: "Модель" },
  "settings.capabilities": { en: "Capabilities", ru: "Возможности" },
  "settings.systemPrompt": { en: "System prompt", ru: "Системный промпт" },
  "settings.delete": { en: "Delete agent", ru: "Удалить агента" },
  "settings.deleteConfirm": { en: "Delete agent \"{name}\"? This cannot be undone.", ru: "Удалить агента «{name}»? Это необратимо." },
  "settings.saved": { en: "Saved", ru: "Сохранено" },
  "settings.save": { en: "Save", ru: "Сохранить" },
  "settings.saving": { en: "Saving…", ru: "Сохраняю…" },
  "settings.avatarUpload": { en: "Upload avatar", ru: "Загрузить аватар" },
  "settings.iconPlaceholder": { en: "icon", ru: "иконка" },

  // model hints
  "model.haiku.hint": { en: "Claude: fast, cheap", ru: "Claude: быстрый, дешёвый" },
  "model.sonnet.hint": { en: "Claude: balance of speed and quality", ru: "Claude: баланс скорости и качества" },
  "model.opus.hint": { en: "Claude: max for hard tasks", ru: "Claude: максимум для сложных задач" },
  "model.codex.hint": { en: "Codex: code, files and terminal", ru: "Codex: код, файлы и терминал" },

  // capabilities
  "cap.web_search.label": { en: "Web search", ru: "Веб-поиск" },
  "cap.web_search.hint": { en: "Search the internet", ru: "Искать в интернете" },
  "cap.web_fetch.label": { en: "Open URL", ru: "Открывать URL" },
  "cap.web_fetch.hint": { en: "Read web pages", ru: "Читать веб-страницы" },
  "cap.chrome_browser.label": { en: "Chrome with sessions", ru: "Chrome с сессиями" },
  "cap.chrome_browser.hint": { en: "Your browser, your logins", ru: "Твой браузер, твои логины" },
  "cap.credential_broker.label": { en: "Credential broker", ru: "Парольный брокер" },
  "cap.credential_broker.hint": { en: "Ask approval for saved credentials", ru: "Запрашивать approve на saved credentials" },
  "cap.file_read.label": { en: "Read files", ru: "Чтение файлов" },
  "cap.file_read.hint": { en: "Read local files", ru: "Читать локальные файлы" },
  "cap.file_write.label": { en: "Write files", ru: "Запись файлов" },
  "cap.file_write.hint": { en: "Save results to disk", ru: "Сохранять результаты на диск" },
  "cap.shell.label": { en: "Shell", ru: "Shell" },
  "cap.shell.hint": { en: "Run terminal commands", ru: "Запускать команды в терминале" },

  // lang toggle
  "lang.en": { en: "EN", ru: "EN" },
  "lang.ru": { en: "RU", ru: "RU" },
} satisfies Dict;

export function t(lang: Lang, key: keyof typeof STRINGS, vars?: Record<string, string | number>): string {
  const entry = STRINGS[key];
  let s = entry ? entry[lang] : key;
  if (vars) {
    for (const [k, v] of Object.entries(vars)) {
      s = s.replaceAll(`{${k}}`, String(v));
    }
  }
  return s;
}
