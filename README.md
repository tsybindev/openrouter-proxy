# OpenRouter proxy (nginx + certbot + LiteLLM)

Схема:

```
клиент (RU) --https--> wp.tsybindev.ru (сервер ЕС)
                          nginx (TLS) --> litellm (docker network)
                                            litellm --> openrouter.ai (с твоим OPENROUTER_API_KEY)
```

Клиент шлёт запросы на твой домен со **своим** токеном (LITELLM_MASTER_KEY),
LiteLLM подменяет его на реальный ключ OpenRouter и делает запрос уже с
IP зарубежного сервера — блокировка по гео обходится.

## 1. Подготовка сервера (в Европе)

1. Направь A-запись домена `wp.tsybindev.ru` на IP сервера.
2. Установи Docker и Docker Compose plugin.
3. Открой порты 80 и 443 в файрволе/security group.

## 2. Настройка проекта

```bash
cp .env.example .env
nano .env   # впиши OPENROUTER_API_KEY, свой LITELLM_MASTER_KEY, домен и e-mail
```

Отредактируй `litellm/config.yaml` — добавь/убери модели, которые хочешь
проксировать (список id моделей: https://openrouter.ai/models).

Если домен другой — поменяй `wp.tsybindev.ru` в `nginx/conf.d/app.conf`.

## 3. Первый запуск (выпуск сертификата)

```bash
./init-letsencrypt.sh
```

Скрипт сам: поднимет временный self-signed сертификат → запустит nginx →
получит настоящий сертификат Let's Encrypt → перезапустит весь стек.

Дальше сертификат обновляется автоматически контейнером `certbot`
(проверка раз в 12 часов, certbot сам обновит его за ~30 дней до истечения).

## 4. Обычный запуск/остановка

```bash
docker compose up -d
docker compose logs -f litellm
docker compose down
```

## 5. Использование с клиента

Прокси полностью OpenAI-совместим. Пример curl:

```bash
curl https://wp.tsybindev.ru/v1/chat/completions \
  -H "Authorization: Bearer <LITELLM_MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-3.7-sonnet",
    "messages": [{"role": "user", "content": "Привет!"}]
  }'
```

Пример с openai-python SDK:

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://wp.tsybindev.ru/v1",
    api_key="<LITELLM_MASTER_KEY>",
)

resp = client.chat.completions.create(
    model="claude-3.7-sonnet",
    messages=[{"role": "user", "content": "Привет!"}],
)
print(resp.choices[0].message.content)
```

Для инструментов, которые умеют работать только с "OpenAI-совместимым API"
(Cursor, Continue.dev, LibreChat, SillyTavern и т.п.) — просто укажи
`base_url = https://wp.tsybindev.ru/v1` и свой `LITELLM_MASTER_KEY` как API key.

## 6. Admin UI

Открой `https://wp.tsybindev.ru/ui` и войди под `LITELLM_MASTER_KEY` (это и
логин-пароль, и admin-токен). В UI можно:

- добавлять/удалять модели без правки `config.yaml` (хранятся в Postgres,
  накладываются поверх файла — см. `store_model_in_db`);
- нарезать отдельные виртуальные ключи под конкретных людей/приложения:
  Keys → Create Key — с лимитом бюджета в $, rpm/tpm, доступом только к
  части моделей, сроком действия;
- смотреть spend-логи (кто, сколько токенов, сколько денег) по каждому ключу;
- заводить команды/организации, если клиентов станет много.

Ключи, выданные через UI/`/key/generate`, тоже работают как
`Authorization: Bearer <ключ>` — просто выдавай их вместо общего мастер-ключа
тем, кому не нужен полный доступ.

⚠️ Для UI и виртуальных ключей обязателен **Postgres** — SQLite LiteLLM
официально не поддерживает (жёстко зашито в их Prisma-схеме). Он уже
добавлен как сервис `postgres` в `docker-compose.yml`, тебе нужно только
задать `POSTGRES_USER/PASSWORD/DB` и `LITELLM_SALT_KEY` в `.env`.

## 7. Управление провайдером OpenRouter (provider routing)

OpenRouter балансирует запрос между несколькими бэкендами одной модели
(например, DeepSeek через deepinfra/fireworks/together — разные по цене,
скорости, квантованию). Если хочешь закрепить конкретных провайдеров —
задай это через `extra_body.provider` в `litellm_params` нужной модели в
`litellm/config.yaml` (пример уже есть у `deepseek-r1`):

```yaml
litellm_params:
  model: openrouter/deepseek/deepseek-r1
  api_key: os.environ/OPENROUTER_API_KEY
  extra_body:
    provider:
      order: ["deepinfra", "fireworks"]
      allow_fallbacks: false
```

Полный список полей (`only`, `ignore`, `sort`, `quantizations`,
`data_collection` и т.д.) — в доке OpenRouter:
https://openrouter.ai/docs/features/provider-routing

Клиент также может переопределить это на лету через `extra_body` в самом
запросе (OpenAI SDK: параметр `extra_body={"provider": {...}}` в
`chat.completions.create`) — тогда настройка из `config.yaml` для этого
конкретного запроса не используется.

⚠️ Не задавай `extra_body` ещё и в `router_settings.default_litellm_params` —
известный баг LiteLLM: глобальный `extra_body` там перетирает `extra_body`,
заданный на уровне конкретной модели.

## 7. Безопасность

- Никому не давай `OPENROUTER_API_KEY` — только контейнеру litellm.
- `LITELLM_MASTER_KEY` — это то, что видят твои клиенты, придумай длинный
  случайный токен: `openssl rand -hex 32`.
- Порт 4000 (litellm) наружу не публикуется — только через nginx по 443.

## 8. Быстрая установка на новом сервере (bootstrap)

Скрипт `bootstrap.sh` делает всю ручную работу из разделов 1-3 за один запуск:
ставит Docker, открывает порты, создаёт swap (если RAM < 2 ГБ), клонирует репо,
генерирует секреты и подготавливает `.env`. После него остаётся только
вписать `OPENROUTER_API_KEY` и запустить `init-letsencrypt.sh`.

**На новом сервере** (Ubuntu 24.04, root-доступ):

```bash
# 1. один раз залить скрипт на сервер (или скопировать содержимое и сохранить)
scp bootstrap.sh root@NEW_SERVER:/root/

# 2. подключиться и запустить
ssh root@NEW_SERVER
bash /root/bootstrap.sh
# скрипт попросит ввести: домен и email для Let's Encrypt

# 3. вписать реальный ключ OpenRouter
nano /root/openrouter-proxy/.env
# заменить OPENROUTER_API_KEY=sk-or-v1-PUT-YOUR-KEY-HERE
# на свой ключ с https://openrouter.ai/keys

# 4. выпустить сертификат и поднять стек
cd /root/openrouter-proxy
./init-letsencrypt.sh
```

Скрипт идемпотентный — можно перезапускать, не сломает. На выходе напечатает
все сгенерированные секреты **один раз** (`LITELLM_MASTER_KEY`,
`LITELLM_SALT_KEY`, `POSTGRES_PASSWORD`) — **обязательно сохрани их
в менеджер паролей**, `LITELLM_SALT_KEY` нужен для расшифровки БД при миграциях.

## 9. История развёртывания и подводные камни

Заметки по конкретным граблям, на которые уже наступили — пригодится
при следующем развёртывании и при отладке.

### 9.1 RAM < 2 ГБ → обязательно swap

LiteLLM-образ `ghcr.io/berriai/litellm-database:main-stable` на старте с
`store_model_in_db: true` аллоцирует **~660 МБ RSS** (Prisma-клиент, миграции,
UI). На сервере с 1 ГБ RAM без swap ядро его OOM-kill'ит в цикле — контейнер
рестартит каждые ~30 секунд, nginx отдаёт 502, SSH отваливается по таймауту.

**Симптомы** (видны в `dmesg | grep -i oom`):
```
Out of memory: Killed process 4234 (litellm) total-vm:732692kB anon-rss:661120kB
```

**Лечение:** создать 2 ГБ swap. На 1 ГБ RAM этого хватает, LiteLLM сидит
в подкачке, но работает стабильно. Скрипт `bootstrap.sh` делает это
автоматически, если видит `MemTotal < 2 ГБ`.

Если есть возможность — лучше сразу взять тариф с 2+ ГБ RAM, тогда swap
не понадобится, а LiteLLM будет отвечать заметно быстрее (особенно UI).

### 9.2 OpenRouter-провайдер nvidia для free-моделей

`nvidia/nemotron-3-ultra-550b-a55b:free` на твоём `OPENROUTER_API_KEY`
отдаёт **404 `function not found`** (провайдер не активирован для
этого ключа на free-уровне). У других OpenRouter-ключей тот же провайдер
может работать. Если важна именно эта модель — нужно зайти на
https://openrouter.ai, открыть карточку модели, нажать "Add provider"
для nvidia (если доступно) и подтвердить.

В текущем `config.yaml` настроены **fallback'и**:
- при падении nemotron LiteLLM автоматически переключается на poolside/minimax
- алиас `free` исключён nemotron из ротации (rotates только между работающими)

### 9.3 Fallback-формат в `config.yaml`

LiteLLM в `router_settings.fallbacks` принимает только формат
**список словарей с одним ключом**:

```yaml
router_settings:
  fallbacks:
    - model_name: ["fallback1", "fallback2"]      # ❌ не работает
    - {model_name: foo, fallbacks: [bar]}         # ❌ не работает
    - foo: ["bar", "baz"]                         # ✅ правильно
```

Если положить строку вместо словаря — LiteLLM валится с
`ValueError: Item 'nemotron-3-ultra-free' is not a dictionary` и уходит
в цикл рестартов. Лечится правкой формата + `docker compose restart litellm`.

### 9.4 Старт LiteLLM занимает 60-90 секунд

После `docker compose restart litellm` или `docker compose up -d` нужно
**подождать минимум минуту**, прежде чем слать запросы. За это время:

1. LiteLLM поднимает Prisma-клиент, прогоняет миграции (~20-30с)
2. Uvicorn открывает порт 4000
3. `depends_on: postgres: service_healthy` ждёт, пока Postgres не
   пройдёт healthcheck

В это время nginx отдаёт **502 Bad Gateway** — это нормально, не паника.
Проверить готовность: `curl https://$DOMAIN/health/readiness` должен
вернуть `{"status":"healthy","db":"connected"}`.

### 9.5 `use_provider_cost: true` для динамических тарифов

У некоторых провайдеров OpenRouter (например, Z.ai до 09.09.2026 идёт
скидка 50%) цена меняется со временем. Если зашить тариф в `model_info`,
в spend-логах LiteLLM будет отображаться устаревшая цена.

**Решение:** `litellm_settings.use_provider_cost: true` — LiteLLM берёт
реальный `usage.cost` из ответа OpenRouter. `model_info` остаётся как
fallback на случай, если OpenRouter не прислал `cost` (бывает для
некоторых провайдеров).

В логах LiteLLM будет сыпать `WARNING ... not in built-in cost map` —
это нормально, для wildcard-моделей у LiteLLM нет своей таблицы, и он
полагается на `use_provider_cost`.

### 9.6 Wildcard-модель `*` для всего остального

Запись в `model_list`:
```yaml
- model_name: "*"
  litellm_params:
    model: openrouter/*
    api_key: os.environ/OPENROUTER_API_KEY
```
ловит **любой `model=`**, который не совпал с явной записью выше, и
проксирует его в OpenRouter. Так можно не прописывать каждую модель
вручную. Если такого id у OpenRouter нет — клиент получит
`400 is not a valid model ID` (это нормальная ошибка, не паника).

**Ограничения wildcard:**
- Нельзя задать `extra_body.provider.order` (используется default)
- Нельзя задать явный `model_info` (только через `use_provider_cost`)
- В Admin UI wildcard не показывается как отдельная модель

### 9.7 Баннер "No Redis configured" на одном воркере

LiteLLM показывает жёлтый баннер если не подключён Redis. **Для одного
воркера Redis не нужен** — rate limits, бюджеты, spend-логи работают
корректно и без него. Баннер скрывается переменной
`LITELLM_DISABLE_NO_REDIS_WARNING=true` (уже выставлена в `docker-compose.yml`).

Redis становится обязательным только при горизонтальном масштабировании
(несколько реплик LiteLLM за балансировщиком) — иначе rate-limits и
бюджеты считаются per-worker, и при пиках лимиты можно превысить.
