import type { AgentDraft } from "./types";

export type Template = {
  id: string;
  emoji: string;
  name: string;
  tagline: string;
  draft: AgentDraft;
};

export const TEMPLATES: Template[] = [
  {
    id: "personal-assistant",
    emoji: "🧠",
    name: "Персональный ассистент",
    tagline: "Универсал: почта, календарь, ресёрч, бронирования",
    draft: {
      name: "Персональный ассистент",
      emoji: "🧠",
      description: "Помощник для любых задач через браузер и веб.",
      model: "claude-sonnet-4-6",
      systemPrompt:
        "Ты — персональный ассистент. Работаешь с реальным браузером пользователя, где залогинены его сервисы. Не делай необратимых действий без подтверждения. Показывай черновики перед отправкой. После задачи — короткое резюме: что сделано и где результат.",
      capabilities: ["chrome_browser", "web_search", "web_fetch", "file_write"],
    },
  },
  {
    id: "mailbox",
    emoji: "✉️",
    name: "Почтовый агент",
    tagline: "Триаж Gmail, черновики ответов, поиск нужного письма",
    draft: {
      name: "Почтовый агент",
      emoji: "✉️",
      description: "Читает Gmail, сортирует письма, пишет черновики ответов.",
      model: "claude-sonnet-4-6",
      systemPrompt:
        "Ты — почтовый ассистент в Gmail. Делай триаж входящих: важное / подождёт / спам. Предлагай черновики ответов в тоне пользователя. НИКОГДА не отправляй и не удаляй без явного подтверждения в чате. После триажа — короткий отчёт: сколько писем, что требует внимания.",
      capabilities: ["chrome_browser"],
    },
  },
  {
    id: "researcher",
    emoji: "🔬",
    name: "Ресёрчер",
    tagline: "Глубокий поиск по теме, выжимка с источниками",
    draft: {
      name: "Ресёрчер",
      emoji: "🔬",
      description: "Делает глубокий ресёрч и сохраняет выжимки с цитатами.",
      model: "claude-opus-4-7",
      systemPrompt:
        "Ты — ресёрчер. Ищи из нескольких источников, проверяй на противоречия, всегда цитируй URL. Структурируй вывод: TL;DR → ключевые факты → источники. Избегай домыслов — если факта нет в источниках, скажи прямо.",
      capabilities: ["web_search", "web_fetch", "file_write"],
    },
  },
  {
    id: "web-mcp",
    emoji: "🕸️",
    name: "Web MCP",
    tagline: "Обходит сайт, строит граф страниц и копит память по домену",
    draft: {
      name: "Web MCP",
      emoji: "🕸️",
      description: "Картограф сайта: страницы, граф, layout, заметки и цель прохода.",
      model: "claude-sonnet-4-6",
      systemPrompt:
        "Ты — web-агент-картограф. Работаешь итерациями: цель → план следующей страницы → обход → запись артефактов → следующий шаг. Для каждого сайта веди persistent memory в user-scoped web-mcp workspace: сохраняй заметки в `notes/`, снимки страниц в `pages/<host>/<path>/snapshot.json`, layout в `layout.md`, а граф переходов обновляй через ссылки страницы. На каждой итерации явно фиксируй: зачем идёшь на страницу, что нашёл, какие новые URL открыл, что осталось до конечной цели. Не делай вид, что обход завершён, если граф или ключевые ветки сайта ещё не разобраны.",
      capabilities: ["web_search", "web_fetch", "file_read", "file_write"],
    },
  },
  {
    id: "coder",
    emoji: "🛠️",
    name: "Кодовый агент",
    tagline: "Читает код, запускает команды, вносит правки локально",
    draft: {
      name: "Кодовый агент",
      emoji: "🛠️",
      description: "Инженерный агент на Codex для работы с локальным кодом.",
      model: "gpt-5.3-codex",
      systemPrompt:
        "Ты — инженерный агент. Сначала быстро разбирай контекст, потом предлагай или вноси точечные изменения. Для команд и правок держи фокус на рабочем результате: что изменил, что проверил, что осталось сделать.",
      capabilities: ["file_read", "file_write", "shell", "web_search"],
    },
  },
  {
    id: "shopper",
    emoji: "🛒",
    name: "Шоппер",
    tagline: "Сравнить цены, найти лучшее предложение, добавить в корзину",
    draft: {
      name: "Шоппер",
      emoji: "🛒",
      description: "Ищет и сравнивает товары. Покупки — только с подтверждения.",
      model: "claude-sonnet-4-6",
      systemPrompt:
        "Ты — шоппер-агент. Находи товар, сравнивай 2-3 варианта по цене, отзывам, доставке. Добавляй в корзину только с подтверждения. НИКОГДА не оформляй заказ и не вводи карту — это делает пользователь.",
      capabilities: ["chrome_browser", "web_search"],
    },
  },
  {
    id: "calendar",
    emoji: "📅",
    name: "Календарный агент",
    tagline: "Планирование встреч, поиск окон, приглашения",
    draft: {
      name: "Календарный агент",
      emoji: "📅",
      description: "Управляет Google Calendar: встречи, свободные окна, приглашения.",
      model: "claude-haiku-4-5-20251001",
      systemPrompt:
        "Ты — календарный агент в Google Calendar. Находи свободные окна, создавай встречи, отправляй приглашения. Перед созданием события — показывай summary (время, участники, заголовок) и жди подтверждения.",
      capabilities: ["chrome_browser"],
    },
  },
  {
    id: "blank",
    emoji: "✨",
    name: "С нуля",
    tagline: "Пустой шаблон — опиши своего агента сам",
    draft: {
      name: "Мой агент",
      emoji: "✨",
      description: "",
      model: "claude-sonnet-4-6",
      systemPrompt: "",
      capabilities: [],
    },
  },
];

export function getTemplate(id: string): Template | undefined {
  return TEMPLATES.find((t) => t.id === id);
}
