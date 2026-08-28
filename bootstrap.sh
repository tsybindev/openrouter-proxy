#!/usr/bin/env bash
# bootstrap.sh — быстрая установка openrouter-proxy на чистый Ubuntu 24.04.
# Идемпотентный: можно запускать повторно, не сломает.
#
# Что делает:
#   1. Проверяет что мы root
#   2. Ставит Docker Engine + Compose plugin (если не стоят)
#   3. Открывает порты 22/80/443 через ufw
#   4. Создаёт 2 ГБ swap, если RAM < 2 ГБ (LiteLLM на 1 ГБ падает в OOM)
#   5. Клонирует репо с GitHub
#   6. Генерирует LITELLM_MASTER_KEY / LITELLM_SALT_KEY / POSTGRES_PASSWORD
#   7. Создаёт .env из .env.example + секреты, ставит права 600
#   8. Печатает секреты ОДИН РАЗ — сохрани их в менеджер паролей
#
# Что делает НЕ (это ручное):
#   - Не просит OPENROUTER_API_KEY. Открой .env и впиши сам.
#   - Не запускает init-letsencrypt.sh — его запускаешь после вписывания ключа.
#
# Использование:
#   ssh root@NEW_SERVER
#   bash /path/to/bootstrap.sh

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/tsybindev/openrouter-proxy.git}"
INSTALL_DIR="${INSTALL_DIR:-/root/openrouter-proxy}"

# ─── 1. root-check ────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "❌ Скрипт нужно запускать от root" >&2
  exit 1
fi

# ─── 2. параметры от пользователя ────────────────────────────────────────────
echo "=== openrouter-proxy bootstrap ==="
read -r -p "Домен (например wp.tsybindev.ru): " DOMAIN
read -r -p "Email для Let's Encrypt: " EMAIL

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
  echo "❌ Домен и email обязательны" >&2
  exit 1
fi

# ─── 3. Docker + Compose plugin ──────────────────────────────────────────────
echo ""
echo "=== Проверяю Docker ==="
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker не найден, ставлю..."
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-v2
  echo "✅ Docker установлен"
else
  echo "✅ Docker уже есть: $(docker --version)"
fi

# Compose plugin отдельным пакетом в Ubuntu 24.04
if ! docker compose version >/dev/null 2>&1; then
  apt-get install -y -qq docker-compose-v2
fi
echo "✅ Compose: $(docker compose version)"

# ─── 4. UFW + порты ──────────────────────────────────────────────────────────
echo ""
echo "=== UFW ==="
if ! command -v ufw >/dev/null 2>&1; then
  apt-get install -y -qq ufw
fi
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
echo "✅ Порты 22/80/443 открыты"
ufw status | head -8

# ─── 5. Swap, если RAM мало ──────────────────────────────────────────────────
echo ""
echo "=== Память ==="
MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_TOTAL_GB=$((MEM_TOTAL_KB / 1024 / 1024))
echo "RAM: ${MEM_TOTAL_GB} ГБ"

if [ "$MEM_TOTAL_GB" -lt 2 ]; then
  if [ ! -f /swapfile ]; then
    echo "RAM < 2 ГБ — создаю 2 ГБ swap..."
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    if ! grep -q "^/swapfile " /etc/fstab; then
      echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi
    echo "✅ swap 2 ГБ создан и добавлен в /etc/fstab"
  else
    echo "✅ swap уже существует"
  fi
else
  echo "✅ RAM достаточно, swap не нужен"
fi

# ─── 6. DNS-проверка (мягкая) ────────────────────────────────────────────────
echo ""
echo "=== DNS ==="
DNS_IP=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1 || true)
SERVER_IP=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null || true)
echo "Домен $DOMAIN → $DNS_IP"
echo "Сервер       → $SERVER_IP"
if [ -n "$DNS_IP" ] && [ -n "$SERVER_IP" ] && [ "$DNS_IP" != "$SERVER_IP" ]; then
  echo "⚠️  DNS домена не указывает на этот сервер. Let's Encrypt откажет."
  echo "    Пропиши A-запись $DOMAIN → $SERVER_IP и перезапусти скрипт."
  read -r -p "    Продолжить всё равно? (y/N): " CONTINUE
  if [ "$CONTINUE" != "y" ] && [ "$CONTINUE" != "Y" ]; then
    exit 1
  fi
fi

# ─── 7. Клонируем репо ───────────────────────────────────────────────────────
echo ""
echo "=== Клонирую репо ==="
if [ -d "$INSTALL_DIR" ]; then
  echo "Директория $INSTALL_DIR уже есть — обновляю"
  cd "$INSTALL_DIR"
  git pull --rebase --autostash || true
else
  git clone "$REPO_URL" "$INSTALL_DIR"
  cd "$INSTALL_DIR"
fi
echo "✅ Репозиторий в $INSTALL_DIR"

# ─── 8. Генерируем секреты и пишем .env ─────────────────────────────────────
echo ""
echo "=== Генерирую секреты ==="

# Если .env уже есть и в нём заполнен LITELLM_MASTER_KEY — не перетираем
# (идемпотентность: повторный запуск не должен ломать рабочий стек)
if [ -f .env ] && grep -qE "^LITELLM_MASTER_KEY=[a-f0-9]{64}$" .env; then
  echo "✅ .env уже заполнен, оставляю как есть"
else
  LITELLM_MASTER_KEY=$(openssl rand -hex 32)
  LITELLM_SALT_KEY=$(openssl rand -hex 32)
  POSTGRES_PASSWORD=$(openssl rand -hex 24)

  {
    echo "OPENROUTER_API_KEY=sk-or-v1-PUT-YOUR-KEY-HERE"
    echo "LITELLM_MASTER_KEY=$LITELLM_MASTER_KEY"
    echo "LITELLM_SALT_KEY=$LITELLM_SALT_KEY"
    echo "POSTGRES_USER=litellm"
    echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
    echo "POSTGRES_DB=litellm"
    echo "DOMAIN=$DOMAIN"
    echo "EMAIL=$EMAIL"
  } > .env
  chmod 600 .env
  echo "✅ .env создан (chmod 600)"
fi

# ─── 9. Показываем секреты (ОДИН РАЗ) ────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  СГЕНЕРИРОВАННЫЕ СЕКРЕТЫ — СОХРАНИ ИХ В МЕНЕДЖЕР ПАРОЛЕЙ"
echo "═══════════════════════════════════════════════════════════════"
echo "LITELLM_MASTER_KEY=$(grep ^LITELLM_MASTER_KEY= .env | cut -d= -f2)"
echo "LITELLM_SALT_KEY=$(grep ^LITELLM_SALT_KEY= .env | cut -d= -f2)"
echo "POSTGRES_PASSWORD=$(grep ^POSTGRES_PASSWORD= .env | cut -d= -f2)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# ─── 10. Финальные инструкции ────────────────────────────────────────────────
cat <<EOF

✅ Готово. Что делать дальше:

  1. Открой .env и впиши свой ключ OpenRouter:
       nano $INSTALL_DIR/.env
       # замени OPENROUTER_API_KEY=sk-or-v1-PUT-YOUR-KEY-HERE
       # на ключ с https://openrouter.ai/keys

  2. Запусти инициализацию сертификата:
       cd $INSTALL_DIR
       ./init-letsencrypt.sh

  3. После того как стек поднимется (~2 минуты на прогрев LiteLLM):
       curl -I https://$DOMAIN
       # открой https://$DOMAIN/ui и войди под LITELLM_MASTER_KEY

EOF
