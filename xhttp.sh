#!/usr/bin/env bash
#
# xhttp.sh — подготовка сервера (Ubuntu) под XHTTP протокол (Remnawave/Xray)
#
#   1. Устанавливает свежий nginx из официального репозитория nginx.org
#      (с поддержкой HTTP/3 QUIC, встроенной в билд начиная с 1.25.5)
#      и сразу поднимает LimitNOFILE=524288:524288 и worker_connections до 16384
#   2. Запрашивает домен и выпускает Let's Encrypt сертификат
#   3. Создаёт конфиг nginx под XHTTP (grpc_pass на unix-socket в /dev/shm)
#   4. Правит /opt/remnanode/docker-compose.yml, добавляя volumes с /dev/shm
#   5. По желанию перезапускает контейнер remnanode
#
# Запуск: sudo bash xhttp.sh
#
set -euo pipefail

# ------------------------------------------------------------------ helpers --

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log_info() { echo -e "${BLUE}[*]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $*"; }
log_err()  { echo -e "${RED}[ОШИБКА]${NC} $*" >&2; }

ask() {
    # ask "Вопрос" "default_value" -> печатает ответ в stdout
    local prompt="$1" default="${2:-}" reply
    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " reply || true
        echo "${reply:-$default}"
    else
        read -r -p "$prompt: " reply || true
        echo "$reply"
    fi
}

confirm() {
    # confirm "Вопрос" -> код возврата 0 = да, 1 = нет
    local prompt="$1" reply
    read -r -p "$prompt [y/N]: " reply || true
    [[ "$reply" =~ ^[YyДд]([Aa]|)$ ]]
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_err "Скрипт нужно запускать от root (sudo bash xhttp.sh)"
        exit 1
    fi
}

require_ubuntu() {
    if ! command -v lsb_release >/dev/null 2>&1; then
        apt-get update -y >/dev/null
        apt-get install -y lsb-release >/dev/null
    fi
    if [[ "$(lsb_release -is)" != "Ubuntu" ]]; then
        log_warn "Скрипт рассчитан на Ubuntu. На другом дистрибутиве могут быть проблемы, продолжаю на свой риск..."
    fi
}

# ------------------------------------------------------------- 1. nginx.org --

install_fresh_nginx() {
    log_info "Устанавливаю зависимости для добавления репозитория nginx.org..."
    apt-get update -y
    apt-get install -y curl gnupg2 ca-certificates lsb-release ubuntu-keyring

    log_info "Добавляю официальный ключ подписи nginx..."
    curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
        | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null

    local codename
    codename="$(lsb_release -cs)"

    log_info "Добавляю репозиторий nginx.org (stable, релиз: ${codename})..."
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu ${codename} nginx" \
        > /etc/apt/sources.list.d/nginx.list

    # Приоритет пакетов nginx.org выше, чем у версии из репозитория Ubuntu,
    # чтобы apt install nginx не подтягивал старую версию из стандартных репо.
    cat > /etc/apt/preferences.d/99nginx <<'EOF'
Package: *
Pin: origin nginx.org
Pin: release o=nginx
Pin-Priority: 900
EOF

    log_info "Обновляю списки пакетов..."
    apt-get update -y

    log_info "Доступные версии nginx (apt policy nginx):"
    apt-cache policy nginx || true

    if dpkg -l nginx >/dev/null 2>&1; then
        log_info "nginx уже установлен, обновляю до версии из nginx.org..."
    fi

    apt-get install -y nginx

    systemctl enable nginx >/dev/null 2>&1 || true

    log_ok "Установлен nginx: $(nginx -v 2>&1)"
}

# Сразу после установки: лимит открытых файлов у процесса nginx и worker_connections.
tune_nginx_limits() {
    log_info "Поднимаю LimitNOFILE для nginx до 524288:524288..."
    mkdir -p /etc/systemd/system/nginx.service.d
    cat > /etc/systemd/system/nginx.service.d/limits.conf <<'EOF'
[Service]
LimitNOFILE=524288:524288
EOF
    systemctl daemon-reload
    log_ok "LimitNOFILE=524288:524288 записан в /etc/systemd/system/nginx.service.d/limits.conf"

    local nginx_conf="/etc/nginx/nginx.conf"
    if [[ ! -f "$nginx_conf" ]]; then
        log_err "Не найден ${nginx_conf}, worker_connections не изменён."
        exit 1
    fi

    if grep -qE '^[[:space:]]*worker_connections[[:space:]]+16384;' "$nginx_conf"; then
        log_ok "worker_connections уже 16384 в ${nginx_conf}"
    elif grep -qE '^[[:space:]]*worker_connections[[:space:]]+[0-9]+;' "$nginx_conf"; then
        sed -i -E 's/^([[:space:]]*worker_connections[[:space:]]+)[0-9]+;/\116384;/' "$nginx_conf"
        log_ok "worker_connections установлен в 16384 (${nginx_conf})"
    else
        log_err "Не нашёл worker_connections в ${nginx_conf}"
        exit 1
    fi

    if systemctl is-active --quiet nginx; then
        systemctl restart nginx
        log_ok "nginx перезапущен, лимиты применены."
    fi
}

# ------------------------------------------------------------ 2. certificate --

issue_certificate() {
    local domain="$1" email cert_dir="/etc/letsencrypt/live/${1}"

    if [[ -d "$cert_dir" ]]; then
        log_warn "Сертификат для ${domain} уже существует в ${cert_dir}, повторный выпуск пропущен."
        return 0
    fi

    if ! command -v certbot >/dev/null 2>&1; then
        log_info "Устанавливаю certbot..."
        apt-get install -y certbot
    fi

    email="$(ask "Введите e-mail для Let's Encrypt (можно оставить пустым)" "")"

    log_info "Останавливаю nginx на время выпуска сертификата (нужен свободный порт 80)..."
    systemctl stop nginx || true

    local certbot_args=(certonly --standalone -d "$domain" --non-interactive --agree-tos)
    if [[ -n "$email" ]]; then
        certbot_args+=(-m "$email")
    else
        certbot_args+=(--register-unsafely-without-email)
    fi

    if ! certbot "${certbot_args[@]}"; then
        log_err "Не удалось выпустить сертификат для ${domain}. Проверьте, что домен указывает на этот сервер и порт 80/443 открыты."
        systemctl start nginx || true
        exit 1
    fi

    log_ok "Сертификат для ${domain} выпущен."
}

# --------------------------------------------------------------- 3. nginx.conf --

write_xhttp_config() {
    local domain="$1" conf_path="/etc/nginx/conf.d/xhttp.conf"

    mkdir -p /var/www/html
    if [[ ! -f /var/www/html/index.html ]]; then
        echo "<html><body>It works.</body></html>" > /var/www/html/index.html
    fi

    log_info "Пишу конфиг ${conf_path}..."
    cat > "$conf_path" <<EOF
server {
    listen 443 ssl;
    listen 443 quic reuseport;
    listen [::]:443 ssl;
    listen [::]:443 quic;

    server_name ${domain};

    http2 on;
    http3 on;
    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256;

    add_header Alt-Svc 'h3=":443"; ma=86400';

    client_header_timeout 5m;
    keepalive_timeout 5m;

    location /cloudst/ {
        client_max_body_size 0;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        client_body_timeout 5m;
        grpc_read_timeout 315;
        grpc_send_timeout 5m;
        grpc_pass unix:/dev/shm/xrxh.socket;
    }

    location / {
        root /var/www/html;
        index index.html;
    }

    access_log /var/log/nginx/xhttp_access.log;
    error_log /var/log/nginx/xhttp_error.log info;
}
EOF

    log_ok "Конфиг создан: ${conf_path}"
}

reload_nginx() {
    log_info "Проверяю конфигурацию nginx (nginx -t)..."
    if ! nginx -t; then
        log_err "Конфигурация nginx содержит ошибки, смотрите вывод выше."
        exit 1
    fi

    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
        log_ok "nginx перезагружен (reload)."
    else
        systemctl start nginx
        log_ok "nginx запущен."
    fi
}

open_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi "Status: active"; then
        log_info "Обнаружен активный ufw, открываю 80/tcp, 443/tcp и 443/udp (QUIC)..."
        ufw allow 80/tcp  >/dev/null || true
        ufw allow 443/tcp >/dev/null || true
        ufw allow 443/udp >/dev/null || true
        log_ok "Правила ufw добавлены."
    fi
}

# ----------------------------------------------------------- 4. docker-compose --

patch_docker_compose() {
    local compose_path="/opt/remnanode/docker-compose.yml"

    if [[ ! -f "$compose_path" ]]; then
        compose_path="$(ask "Не нашёл /opt/remnanode/docker-compose.yml, укажите путь к docker-compose.yml вручную (или оставьте пустым, чтобы пропустить этот шаг)" "")"
        if [[ -z "$compose_path" || ! -f "$compose_path" ]]; then
            log_warn "docker-compose.yml не найден, пропускаю шаг с volumes. Добавьте вручную:"
            echo '        volumes:'
            echo '            - /dev/shm:/dev/shm:rw'
            return 1
        fi
    fi

    if grep -q "/dev/shm:/dev/shm" "$compose_path"; then
        log_ok "Том /dev/shm уже присутствует в ${compose_path}, менять ничего не нужно."
        echo "$compose_path"
        return 0
    fi

    if ! grep -qE '^[[:space:]]*cap_add:[[:space:]]*$' "$compose_path"; then
        log_warn "Не нашёл секцию 'cap_add:' в ${compose_path}, автоматическая правка невозможна."
        log_warn "Открываю файл в nano, добавьте вручную volumes: - /dev/shm:/dev/shm:rw"
        nano "$compose_path" || true
        echo "$compose_path"
        return 0
    fi

    local backup="${compose_path}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$compose_path" "$backup"
    log_info "Сделал бэкап: ${backup}"

    awk '
        /^[[:space:]]*cap_add:[[:space:]]*$/ && !done {
            match($0, /^[[:space:]]*/)
            indent = substr($0, RSTART, RLENGTH)
            print indent "volumes:"
            print indent "    - /dev/shm:/dev/shm:rw"
            done = 1
        }
        { print }
    ' "$backup" > "$compose_path"

    log_ok "В ${compose_path} добавлен volumes: /dev/shm:/dev/shm:rw"
    echo
    log_info "Текущее содержимое ${compose_path}:"
    cat "$compose_path"
    echo

    echo "$compose_path"
}

restart_remnanode() {
    local compose_path="$1"
    local compose_dir
    compose_dir="$(dirname "$compose_path")"

    if confirm "Перезапустить контейнер remnanode сейчас (docker compose down && up -d)?"; then
        (
            cd "$compose_dir"
            docker compose down
            docker compose up -d
        )
        log_ok "Контейнер remnanode перезапущен."
    else
        log_warn "Не забудьте перезапустить контейнер вручную:"
        echo "  cd ${compose_dir} && docker compose down && docker compose up -d"
    fi
}

# ------------------------------------------------------------------- main ----

main() {
    require_root
    require_ubuntu

    log_info "=== Шаг 1/4: установка свежего nginx из nginx.org ==="
    install_fresh_nginx
    tune_nginx_limits

    log_info "=== Шаг 2/4: сертификат Let's Encrypt ==="
    local domain
    domain="$(ask "Введите домен, на который смотрит этот сервер (например, sub.example.com)")"
    if [[ -z "$domain" ]]; then
        log_err "Домен не указан, выхожу."
        exit 1
    fi
    issue_certificate "$domain"

    log_info "=== Шаг 3/4: конфиг nginx под XHTTP ==="
    write_xhttp_config "$domain"
    open_firewall
    reload_nginx

    log_info "=== Шаг 4/4: docker-compose.yml для remnanode ==="
    local compose_path
    if compose_path="$(patch_docker_compose)"; then
        if [[ -n "$compose_path" ]] && command -v docker >/dev/null 2>&1; then
            restart_remnanode "$compose_path"
        fi
    fi

    echo
    log_ok "Готово! Домен: ${domain}"
    log_ok "Конфиг nginx: /etc/nginx/conf.d/xhttp.conf"
    log_ok "Unix-socket для XHTTP: /dev/shm/xrxh.socket (должен слушать xray/remnanode внутри контейнера)"
}

main "$@"
