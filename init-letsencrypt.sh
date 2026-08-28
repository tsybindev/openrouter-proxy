#!/usr/bin/env bash
set -e

# Загружаем переменные из .env
set -a
source .env
set +a

DOMAIN="${DOMAIN:?DOMAIN не задан в .env}"
EMAIL="${EMAIL:?EMAIL не задан в .env}"

DATA_PATH="./certbot"
RSA_KEY_SIZE=4096

echo "### Проверка: DNS домена $DOMAIN должен уже указывать на IP этого сервера ###"

mkdir -p "$DATA_PATH/conf/live/$DOMAIN"

echo "### Создаём временный self-signed сертификат, чтобы nginx смог стартовать ###"
docker compose run --rm --entrypoint "\
  openssl req -x509 -nodes -newkey rsa:$RSA_KEY_SIZE -days 1 \
    -keyout '/etc/letsencrypt/live/$DOMAIN/privkey.pem' \
    -out '/etc/letsencrypt/live/$DOMAIN/fullchain.pem' \
    -subj '/CN=localhost'" certbot

echo "### Запускаем nginx ###"
docker compose up -d nginx

echo "### Удаляем временный сертификат ###"
docker compose run --rm --entrypoint "\
  rm -rf /etc/letsencrypt/live/$DOMAIN /etc/letsencrypt/archive/$DOMAIN /etc/letsencrypt/renewal/$DOMAIN.conf" certbot

echo "### Запрашиваем настоящий сертификат у Let's Encrypt ###"
docker compose run --rm --entrypoint "\
  certbot certonly --webroot -w /var/www/certbot \
    --email $EMAIL -d $DOMAIN \
    --rsa-key-size $RSA_KEY_SIZE --agree-tos --non-interactive" certbot

echo "### Перезагружаем nginx с реальным сертификатом ###"
docker compose exec nginx nginx -s reload

echo "### Готово. Поднимаем весь стек ###"
docker compose up -d

echo "### Проверь: curl -I https://$DOMAIN ###"
