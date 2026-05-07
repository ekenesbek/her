# Her — Roadmap (deferred initiatives)

Отложенные направления, обсуждённые но не начатые. Снято с активных todos чтобы не отвлекали.

---

## 1. Realtime voice agent через очки

**Идея:** разговорный агент с wake word + сном по фразе ("bye", "хватит"). Аудио in/out полностью через Ray-Ban Meta (HFP in / A2DP out), телефон в кармане.

**Архитектура:**
```
очки → HFP mic → iPhone → WebSocket → backend → OpenAI Realtime API
                                                          ↓
                                                       tools (search_meetings, weather, taxi, reminders)
                                                          ↓
очки ← A2DP speaker ← iPhone ← audio frames ← backend ← OpenAI Realtime
```

**Этапы (~5-7 дней работы):**
1. Backend WebSocket `/v1/realtime/conversation` — proxy к OpenAI Realtime + tool execution + injection памяти
2. iOS audio streaming (`AVAudioEngine` → WebSocket → speaker)
3. AppIntent «Talk to Her» для Siri-активации
4. System prompt с sleep-words (bye, goodbye, до свидания, хватит, finish)
5. 30-сек silence timeout
6. Tools: `search_meetings(query)`, `get_weather(loc)`, `draft_taxi(from, to)`, `set_reminder(text, when)`, `end_conversation()`
7. Сохранение realtime-разговоров как обычных meetings (с диаризацией)

**Затем (опционально):**
- Custom wake word «Hey [имя_агента]» через Picovoice Porcupine — позволит активировать без «Hey Siri», но требует app в активном audio-режиме (батарея 2-3× нагрузка)
- Smart on/off для wake (только дома, только когда телефон не заблокирован) — экономия батареи

**Что нужно:**
- **OpenAI API key** Tier 1+ с доступом к Realtime API — обязательно
- Picovoice account (бесплатно для personal) — опционально для custom wake word
- Бюджет: ~$0.20-0.35 за минуту разговора Realtime API → ~$60-100/мес при 10 мин/день

**Альтернатива дешевле (pipeline):** Whisper STT → Claude → TTS. Турн-ответ 2-4 секунды (не realtime feel), но в 5-7 раз дешевле. Нужен ANTHROPIC_API_KEY.

### 1.1. Custom wake word «Hey [имя]» — детальный план

**Что одноразовое (установка ~10 мин):**
1. Регистрация на [picovoice.ai/console](https://console.picovoice.ai) — бесплатно для personal
2. Тренировка custom keyword `.ppn` файла — выбираешь iOS платформу + фразу + язык, ждёшь 5-10 минут, скачиваешь
3. Создание Access Key на странице AccessKeys
4. Добавление файла в bundle iOS приложения
5. Настройка SDK через SPM (`https://github.com/Picovoice/porcupine.git`)
6. Включение `Always listening` в Settings приложения

**Что постоянно работает после установки:**
- `.ppn` файл не expires, никогда не пере-тренируется
- Picovoice SDK работает локально на устройстве, без интернета для wake-detection
- Slu listener живёт пока приложение активно (foreground или background с audio session)

**Что требует периодических действий:**
- После **force-kill** приложения (свайп-up) — listener умирает, нужно открыть Her один раз
- После **перезагрузки телефона** — то же
- На **free tier Picovoice** — лимит ~50 wake events/мес/устройство; при превышении нужен Standard план $15/мес

**Что не нужно:**
- Не нужно «продлевать» лицензию `.ppn`
- Не нужно пере-обучать модель если не меняешь фразу
- Не нужно держать интернет-соединение для самого wake-detection

**Battery cost (важно для UX):**
- Always-on listening: ~30-40% дополнительная разрядка в день
- Smart mode (только когда телефон не заблокирован И BT-устройство подключено): ~10%
- Ручной режим (только Hey Siri): 0% extra

**Lifecycle table:**
| Состояние app | Custom wake работает? |
|---|---|
| Foreground (открыто) | Да |
| Background с audio session | Да |
| Lock screen | Да |
| Force-killed (swipe-up в app switcher) | Нет — нужно открыть Her |
| После перезагрузки телефона | Нет — нужно открыть Her один раз |
| Low Power Mode (<20% батареи) | iOS может приостановить |

**Альтернатива Picovoice:** [OpenWakeWord](https://github.com/dscripka/openWakeWord) — open-source, бесплатно навсегда, но нужно тренировать самому, точность ниже на 5-10%.

---

## 2. MWDAT audio API (когда Meta откроет)

**Сейчас:** SDK 0.6 даёт только camera/photo. Аудио идёт через стандартный iOS HFP — 8 kHz mono.

**Когда Meta добавит audio capability в DAT SDK** (анонсов нет, ждём 2026+):
- Заменить HFP-путь на прямой PCM-стрим из SDK
- Поднять качество с 8 kHz узкополосного до 16+ kHz wideband
- Точность Whisper подскочит на ~15-20%

**Триггер для работы:** новый minor релиз `meta-wearables-dat-ios` с упоминанием audio в CHANGELOG. Проверить: https://github.com/facebook/meta-wearables-dat-ios/releases

---

## 3. Auto-learn speakers (Omi style — Stage 4 диаризации)

**Сейчас:** voice profile создаётся явно через 60-секундную запись в settings/onboarding. Каждый, кого хочешь распознавать, должен сам пройти enrollment.

**Идея (как Omi):**
- В meeting view сегмент `SPEAKER_01` сделать tappable
- Тап → action sheet «Name this speaker» → текст «Иван»
- Бэк извлекает embedding всех сегментов этого SPEAKER_NN из meeting → сохраняет как `voice_profile` под именем
- В будущих митингах Иван автоматически распознаётся

**Backend:**
- Новый эндпойнт `POST /v1/voice-profiles/from-meeting` принимает `{meeting_id, speaker_label, name}`
- Хранение оригинальных аудио-файлов на сервере (сейчас удаляются)
- Извлечение embedding через `pyannote.audio.Inference.crop()` для соответствующих сегментов

**iOS:**
- Tap-handler на speaker label в transcript view
- Modal с input + Save
- Refresh meeting после сохранения

**Объём:** ~2-3 часа (если хранение аудио уже сделано) или ~4-5 часов (если нужно добавлять storage).

См. источник идеи: https://github.com/BasedHardware/omi/issues/2703

---

## 4. Action integrations (deep-link → full payment)

### Stage A — deep-link (~1 час за интеграцию)
Агент готовит запрос → открывает нативное приложение с pre-fill, пользователь жмёт «оплатить» вручную.

- Yandex Taxi: URL scheme `yandextaxi://route/?ref=her&start-lat=...&start-lon=...&end-lat=...&end-lon=...`
- Uber: `uber://?action=setPickup&pickup=my_location&dropoff[latitude]=...`
- Booking: deep-link с фильтрами поиска
- Aviasales/Skyscanner: фильтры рейсов

### Stage B — full API integration (дни-недели)
Полностью авто-флоу с оплатой. Требует:
- OAuth интеграцию с каждым провайдером
- Хранение payment methods
- Trust flow (подтверждение пользователя перед списанием)
- Compliance (PCI-DSS если храним токены карт)

**Рекомендация:** ограничиться Stage A надолго. Полная авто-оплата — это отдельный продукт со своими compliance проблемами.

---

## 5. Streaming/realtime транскрипция (если потребуется)

**Сейчас:** batch — записал → стоп → отправил → транскрипция. Турн ~3-5× realtime.

**Если нужен realtime UI с partial-результатами:**
- WebSocket эндпойнт `/v1/transcribe/stream`
- Бэк проксирует в Soniox/Deepgram (платно) или поддерживает локальный stream через `whisper-streaming` (бесплатно)
- iOS показывает партиал-транскрипт по мере поступления

**Не приоритет** — батч-режим закрывает 95% юзкейсов.

---

## 6. Apple Watch companion

**Идея:** кнопка на часах → старт/стоп записи на iPhone без вытаскивания телефона.

**Объём:** ~3-4 часа (новый WatchOS target, минимальная WatchKit app).

Полезно если очки не носишь, а часы есть.
