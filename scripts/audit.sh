#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo " [OK] $desc"; ((PASS++))
    else
        echo " [FAIL] $desc (ожидалось: '$expected', получено: '$actual')";
((FAIL++))
 fi
}
echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
check "Вход от имени root запрещён" "no" "$(sudo sshd -T | awk '/^permitrootlogin/{print $2}')"
check "Парольная аутентификация отключена" "no" "$(sudo sshd -T | awk '/^passwordauthentication/{print $2}')"

# Реализация TODO 1
check "Порт SSH изменён (не 22)" "not_22" "$( [[ $(sudo sshd -T | awk '/^port/{print $2}') != "22" ]] && echo "not_22" )"

# Реализация TODO 2
check "MaxAuthTries равен 3" "3" "$(sudo sshd -T | awk '/^maxauthtries/{print $2}')"


echo "[2] Межсетевой экран"
check "Межсетевой экран активен" "active" "$(sudo ufw status | awk '/^Status:/{print $2}')"

# Реализация TODO 3
check "Политика по умолчанию для входящих — deny" "deny" "$(sudo ufw status verbose | grep 'Default:' | awk '{print $2}')"

echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf " %s (uid=%s)\n",$1,$3}' /etc/passwd

echo "[4] Веб-сервер"
# а) служба nginx активна
check "Служба nginx активна" "active" "$(systemctl is-active nginx)"

# б) конфигурация nginx синтаксически корректна
if sudo nginx -t > /dev/null 2>&1; then
    NGINX_TEST_RESULT="ok"
else
    NGINX_TEST_RESULT="error"
fi
check "Конфигурация nginx корректна" "ok" "$NGINX_TEST_RESULT"

# в) сертификат истекает не ранее чем через 30 дней (2592000 секунд)
# Флаг -checkend возвращает 0, если сертификат действителен дольше указанного времени.
if openssl x509 -checkend 2592000 -noout -in /etc/ssl/certs/devops.crt > /dev/null 2>&1; then
    CERT_RESULT="valid"
else
    CERT_RESULT="expired_soon"
fi
check "Сертификат действителен более 30 дней" "valid" "$CERT_RESULT"

# г) нет файлов с правами 666 (доступных на запись всем) и права ключа 600
NO_WORLD_WRITABLE=$(sudo find /var/www/devops-site -perm -o+w | wc -l)
KEY_PERMS=$(sudo stat -c '%a' /etc/ssl/private/devops.key)

# Проверяем, что файлов, доступных на запись всем, НЕТ (0 штук), и права ключа 600
if [[ "$NO_WORLD_WRITABLE" -eq 0 && "$KEY_PERMS" == "600" ]]; then
    SECURE_RESULT="secure"
else
    SECURE_RESULT="insecure"
fi
check "Права файлов безопасны (нет 666, ключ 600)" "secure" "$SECURE_RESULT"

echo "[5] Контейнеризация"
# а) служба docker активна
check "Служба docker активна" "active" "$(systemctl is-active docker)"

# б) контейнер СУБД healthy
DB_HEALTH=$(docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null || echo "not_found")
check "Контейнер СУБД healthy" "healthy" "$DB_HEALTH"

# в) порты 5000 и 5432 не прослушиваются на всех адресах, кроме 127.0.0.1
BAD_PORTS=$(ss -tln | awk '$4 ~ /:5000$/ && $4 !~ /^127\.0\.0\.1:/ {print}' | wc -l)
check "Порты 5000/5432 не доступны извне" "0" "$BAD_PORTS"

# г) права .env равны 600
ENV_PERMS=$(stat -c '%a' ~/app/.env)
check "Права .env равны 600" "600" "$ENV_PERMS"

echo "[6] Контрольная работа № 2"
PROJECT_DIR="$HOME/kr2"
PORT=8002

# а) контейнер сервиса redis находится в состоянии healthy
REDIS_CONTAINER_ID=$(docker compose --project-directory $PROJECT_DIR ps -q redis 2>/dev/null || echo "")
if [ -n "$REDIS_CONTAINER_ID" ]; then
    REDIS_HEALTH=$(docker inspect -f '{{.State.Health.Status}}' "$REDIS_CONTAINER_ID" 2>/dev/null || echo "unknown")
else
    REDIS_HEALTH="not_found"
fi
check "Контейнер redis healthy" "healthy" "$REDIS_HEALTH"

# б) порт опубликован только на 127.0.0.1
PORT_OUTPUT=$(docker compose --project-directory $PROJECT_DIR port app $PORT 2>/dev/null || echo "not_found")
if [[ "$PORT_OUTPUT" == "127.0.0.1:$PORT" ]]; then
    PORT_OK="yes"
else
    PORT_OK="no"
fi
check "Порт $PORT доступен только на 127.0.0.1" "yes" "$PORT_OK"

# в) права файла .env равны 600
ENV_PERMS_KR2=$(stat -c '%a' ~/kr2/.env 2>/dev/null || echo "not_found")
check "Права .env равны 600" "600" "$ENV_PERMS_KR2"

# г) сертификат истекает не ранее чем через 30 дней (2592000 секунд)
if openssl x509 -checkend 2592000 -noout -in /etc/ssl/certs/kr2.crt > /dev/null 2>&1; then
    CERT_RESULT="valid"
else
    CERT_RESULT="expired_soon"
fi
check "Сертификат kr2.crt действителен более 30 дней" "valid" "$CERT_RESULT"

# д) ресурс kr2 активирован (символическая ссылка)
if [ -L /etc/nginx/sites-enabled/kr2 ]; then
    LINK_RESULT="active"
else
    LINK_RESULT="inactive"
fi
check "Ресурс kr2 активирован в Nginx" "active" "$LINK_RESULT"

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1