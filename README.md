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
