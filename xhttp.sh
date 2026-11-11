#!/usr/bin/env bash
#
# xhttp.sh — подготовка сервера (Ubuntu) под XHTTP протокол (Remnawave/Xray)
#
#   1. Устанавливает свежий nginx из официального репозитория nginx.org
#      (с поддержкой HTTP/3 QUIC, встроенной в билд начиная с 1.25.5)
#      и сразу поднимает LimitNOFILE=524288:524288 и worker_connections до 16384
#   2. Запрашивает домен и выпускает Let's Encrypt сертификат
#   3. Разворачивает сайт-прикрытие в /var/www/html (многостраничный сайт IT-студии:
#      вёрстка, JS, favicon, robots.txt, sitemap.xml, 404; генерируется самим скриптом),
#      запрашивает location и создаёт конфиг nginx под XHTTP (grpc_pass на unix-socket
#      в /dev/shm) + раздачу статики (gzip, кэш, error_page 404, security-заголовки)
#   4. Правит /opt/remnanode/docker-compose.yml, добавляя volumes с /dev/shm
#   5. По желанию перезапускает контейнер remnanode
#
# Запуск: sudo bash xhttp.sh
#
# Необязательные переменные окружения (для неинтерактивного запуска):
#   XHTTP_DECOY=y|n          разворачивать ли сайт-прикрытие (по умолчанию спрашивает, y)
#   XHTTP_DECOY_BRAND=Имя    название компании на сайте (по умолчанию из домена)
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

# ------------------------------------------- 3a. сайт-прикрытие (decoy site) --
#
# Генерирует правдоподобный многостраничный сайт (IT-студия) целиком из этого
# скрипта: без внешних загрузок, CDN, шрифтов и трекеров. Все файлы собираются
# во временном каталоге и только потом копируются в веб-корень.

DECOY_ROOT_DEFAULT="/var/www/html"
DECOY_GENERATOR_TAG="sitegen-lite"
DECOY_DEPLOYED=0
DECOY_HUES=(215 168 262 14 338 142)
DECOY_HEXES=("#1f5fc4" "#1f9e7c" "#6a3fc6" "#c05a1c" "#c42b62" "#1f9e3f")

_decoy_sedesc() {
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

# Заглушка/дефолтная страница, которую безопасно заменить нашим сайтом.
_decoy_is_placeholder() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    if [[ "$(wc -c < "$f")" -lt 200 ]] && grep -qi 'It works' "$f"; then
        return 0
    fi
    grep -qiE 'Welcome to nginx!|Apache2 .*Default Page' "$f"
}

# 0 — можно (пусто / наш сайт / заглушка), 1 — там чужой сайт.
_decoy_can_deploy() {
    local index="$1/index.html"
    [[ ! -f "$index" ]] && return 0
    grep -q "$DECOY_GENERATOR_TAG" "$index" && return 0
    _decoy_is_placeholder "$index"
}

_decoy_default_brand() {
    local domain="${1#www.}" label
    local -a parts
    IFS='.' read -ra parts <<< "$domain"
    local n="${#parts[@]}"
    if (( n >= 3 )) && [[ "${parts[n-2]}" =~ ^(co|com|org|net|gov|edu)$ ]]; then
        label="${parts[n-3]}"
    elif (( n >= 2 )); then
        label="${parts[n-2]}"
    else
        label="${parts[0]}"
    fi
    label="${label//-/ }"
    [[ -z "$label" ]] && label="Студия"
    printf '%s' "${label^}"
}

_decoy_sanitize_brand() {
    local b="$1"
    b="$(printf '%s' "$b" | tr -d '<>&"'"'"'\\|`$;/')"
    b="$(printf '%s' "$b" | LC_ALL=C.UTF-8 cut -c1-40)"
    b="$(printf '%s' "$b" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    printf '%s' "$b"
}

_decoy_date_ru() {
    local -a months=(января февраля марта апреля мая июня июля августа сентября октября ноября декабря)
    local d m y
    d="$(date +%-d)"; m="$(date +%-m)"; y="$(date +%Y)"
    printf '%s %s %s' "$d" "${months[m-1]}" "$y"
}

_decoy_write_seo() {
    local r="$1" lastmod p
    lastmod="$(date +%F)"

    cat > "$r/robots.txt" <<'DECOY_ROBOTS_EOF'
User-agent: *
Allow: /

Sitemap: https://__DOMAIN__/sitemap.xml
DECOY_ROBOTS_EOF

    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
        for p in "" services.html portfolio.html blog.html blog/skolko-stoit-sait.html \
                 blog/nativnoe-ili-krossplatformennoe.html blog/pyat-processov-dlya-avtomatizatsii.html \
                 blog/chek-list-zapuska-sayta.html about.html contacts.html privacy.html; do
            printf '  <url><loc>https://__DOMAIN__/%s</loc><lastmod>%s</lastmod></url>\n' "$p" "$lastmod"
        done
        echo '</urlset>'
    } > "$r/sitemap.xml"
}

# Подстановка глобальных плейсхолдеров во всех сгенерированных файлах.
_decoy_substitute() {
    local r="$1" domain="$2" brand="$3" hue="$4" hex="$5"
    local d_esc b_esc
    d_esc="$(_decoy_sedesc "$domain")"
    b_esc="$(_decoy_sedesc "$brand")"
    find "$r" -type f \( -name '*.html' -o -name '*.css' -o -name '*.xml' -o -name '*.txt' -o -name '*.svg' \) -print0 \
        | xargs -0 sed -i \
            -e "s|__BRAND__|${b_esc}|g" \
            -e "s|__DOMAIN__|${d_esc}|g" \
            -e "s|__YEAR__|$(date +%Y)|g" \
            -e "s|__DATE_RU__|$(_decoy_date_ru)|g" \
            -e "s|__HUE__|${hue}|g" \
            -e "s|__HEX__|${hex}|g"
}

# deploy_decoy_site <домен> [веб-корень]
# Результат: DECOY_DEPLOYED=1 если наш сайт установлен в веб-корень.
deploy_decoy_site() {
    local domain="$1" root="${2:-$DECOY_ROOT_DEFAULT}"
    DECOY_DEPLOYED=0

    if [[ -f "$root/index.html" ]] && ! _decoy_can_deploy "$root"; then
        log_warn "В ${root} уже есть чужой сайт (index.html без нашей метки) — не трогаю, сайт-прикрытие не разворачиваю."
        return 0
    fi

    local answer="${XHTTP_DECOY:-}"
    if [[ -z "$answer" ]]; then
        answer="$(ask "Развернуть правдоподобный сайт-прикрытие вместо заглушки? (y/n)" "y")"
    fi
    if [[ ! "$answer" =~ ^([YyДд]([Aa]|)|1|yes|да)$ ]]; then
        log_warn "Сайт-прикрытие пропущен по вашему выбору."
        return 0
    fi

    local brand="${XHTTP_DECOY_BRAND:-}"
    if [[ -z "$brand" ]]; then
        brand="$(ask "Название компании для сайта" "$(_decoy_default_brand "$domain")")"
    fi
    brand="$(_decoy_sanitize_brand "$brand")"
    [[ -z "$brand" ]] && brand="$(_decoy_default_brand "$domain")"

    local idx hue hex
    idx=$(( $(printf '%s' "$domain" | cksum | cut -d' ' -f1) % ${#DECOY_HUES[@]} ))
    hue="${DECOY_HUES[idx]}"
    hex="${DECOY_HEXES[idx]}"

    log_info "Генерирую сайт «${brand}» для ${domain} в ${root}..."
    local stage
    stage="$(mktemp -d)"
    if ! {
        _decoy_write_assets "$stage" \
        && _decoy_write_favicon_ico "$stage/favicon.ico" "$hex" \
        && _decoy_write_pages_main "$stage" \
        && _decoy_write_pages_blog "$stage" \
        && _decoy_write_seo "$stage" \
        && _decoy_substitute "$stage" "$domain" "$brand" "$hue" "$hex"
    }; then
        rm -rf "$stage"
        log_err "Не удалось сгенерировать сайт-прикрытие."
        return 1
    fi

    chmod -R u=rwX,go=rX "$stage"
    mkdir -p "$root"
    cp -a "$stage"/. "$root"/
    rm -rf "$stage"

    DECOY_DEPLOYED=1
    log_ok "Сайт-прикрытие развёрнут: ${root} ($(find "$root" -type f | wc -l) файлов, тема «${brand}»)"
}

_decoy_write_assets() {
    local d="$1/assets"
    mkdir -p "$d"

    cat > "$d/style.css" <<'DECOY_CSS_EOF'
:root{--h:__HUE__;--bg:#f6f7fb;--surface:#fff;--surface-2:#eef1f7;--text:#18202f;--muted:#5b6679;--border:#e1e5ee;--accent:hsl(var(--h),72%,40%);--accent-ink:#fff;--accent-soft:hsl(var(--h),80%,95%);--accent-2:hsl(calc(var(--h) + 40),80%,52%);--shadow:0 10px 30px rgba(20,30,60,.08);--radius:16px;--maxw:1120px;color-scheme:light}
[data-theme=dark]{--bg:#0e121b;--surface:#161b27;--surface-2:#1d2433;--text:#e8ecf4;--muted:#9aa5b8;--border:#262e40;--accent:hsl(var(--h),80%,68%);--accent-ink:#0b0f18;--accent-soft:hsl(var(--h),35%,17%);--accent-2:hsl(calc(var(--h) + 40),80%,66%);--shadow:0 10px 30px rgba(0,0,0,.45);color-scheme:dark}
*,*::before,*::after{box-sizing:border-box}
html{scroll-behavior:smooth;-webkit-text-size-adjust:100%}
body{margin:0;font:16px/1.65 system-ui,-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;background:var(--bg);color:var(--text);transition:background .25s,color .25s}
img,svg{max-width:100%}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
h1,h2,h3,h4{line-height:1.2;margin:0 0 .6em;letter-spacing:-.01em}
h1{font-size:clamp(2rem,4.5vw,3.2rem)}
h2{font-size:clamp(1.55rem,3vw,2.15rem)}
h3{font-size:1.2rem}
p{margin:0 0 1em}
ul{padding-left:1.2em}
:focus-visible{outline:3px solid var(--accent);outline-offset:2px;border-radius:6px}
.skip{position:absolute;left:-999px;top:8px;background:var(--accent);color:var(--accent-ink);padding:8px 14px;border-radius:8px;z-index:100}
.skip:focus{left:8px}
.wrap{width:100%;max-width:var(--maxw);margin:0 auto;padding:0 20px}
.ic{width:1.25em;height:1.25em;stroke:currentColor;fill:none;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round;flex:none;vertical-align:-.25em}
.muted{color:var(--muted)}
.after-grid{margin-top:28px}
.lead-c{margin-inline:auto}
.dlg-cta{margin:22px 0 0}
.center{text-align:center}

.site-header{position:sticky;top:0;z-index:50;background:color-mix(in srgb,var(--bg) 88%,transparent);backdrop-filter:saturate(1.4) blur(10px);border-bottom:1px solid var(--border)}
.nav{display:flex;align-items:center;gap:20px;min-height:68px}
.logo{display:flex;align-items:center;gap:10px;font-weight:700;font-size:1.15rem;color:var(--text)}
.logo:hover{text-decoration:none}
.logo .ic{color:var(--accent);width:34px;height:34px;fill:currentColor;stroke:none}
.menu{display:flex;gap:4px;margin:0 0 0 auto;padding:0;list-style:none}
.menu a{display:block;padding:8px 13px;border-radius:10px;color:var(--text);font-weight:500;font-size:.95rem}
.menu a:hover{background:var(--surface-2);text-decoration:none}
.menu a[aria-current=page]{background:var(--accent-soft);color:var(--accent)}
.icon-btn{display:inline-grid;place-items:center;width:40px;height:40px;border-radius:12px;border:1px solid var(--border);background:var(--surface);color:var(--text);cursor:pointer;font-size:1.1rem;transition:transform .15s,background .2s}
.icon-btn:hover{background:var(--surface-2)}
.icon-btn:active{transform:scale(.94)}
.burger{display:none;margin-left:0}
.theme-ic-moon{display:none}
[data-theme=dark] .theme-ic-moon{display:inline}
[data-theme=dark] .theme-ic-sun{display:none}

.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;padding:12px 22px;border-radius:12px;border:1px solid transparent;background:var(--accent);color:var(--accent-ink);font:inherit;font-weight:600;cursor:pointer;transition:transform .15s,box-shadow .2s,background .2s}
.btn:hover{text-decoration:none;box-shadow:0 8px 20px color-mix(in srgb,var(--accent) 35%,transparent);transform:translateY(-1px)}
.btn:disabled{opacity:.6;cursor:progress;transform:none;box-shadow:none}
.btn.ghost{background:transparent;color:var(--text);border-color:var(--border)}
.btn.ghost:hover{background:var(--surface-2);box-shadow:none}
.btn.small{padding:8px 14px;font-size:.9rem}

.hero{padding:72px 0 56px;background:radial-gradient(900px 400px at 85% -10%,var(--accent-soft),transparent 70%)}
.hero-grid{display:grid;grid-template-columns:1.05fr .95fr;gap:48px;align-items:center}
.eyebrow{display:inline-flex;align-items:center;gap:8px;padding:5px 12px;border-radius:99px;background:var(--accent-soft);color:var(--accent);font-weight:600;font-size:.85rem;margin-bottom:18px}
.lead{font-size:1.15rem;color:var(--muted);max-width:56ch}
.hero-cta{display:flex;flex-wrap:wrap;gap:12px;margin-top:26px}
.hero-art{width:100%;height:auto;filter:drop-shadow(var(--shadow))}
.hero-art .w{fill:var(--surface);stroke:var(--border)}
.hero-art .bar{fill:var(--accent)}
.hero-art .bar2{fill:var(--accent-2)}
.hero-art .ln{stroke:var(--border);fill:none;stroke-width:2}
.hero-art .tx{fill:var(--surface-2)}
.hero-art .pl{fill:none;stroke:var(--accent-2);stroke-width:4;stroke-linecap:round;stroke-linejoin:round}
.hero-art .dot{fill:var(--accent)}

.section{padding:64px 0}
.section.alt{background:var(--surface);border-block:1px solid var(--border)}
.section-head{max-width:640px;margin:0 auto 38px;text-align:center}
.section-head p{color:var(--muted)}
.grid{display:grid;gap:22px}
.g2{grid-template-columns:repeat(2,1fr)}
.g3{grid-template-columns:repeat(3,1fr)}
.g4{grid-template-columns:repeat(4,1fr)}
.card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:26px;transition:transform .2s,box-shadow .2s,border-color .2s}
.card:hover{transform:translateY(-3px);box-shadow:var(--shadow);border-color:color-mix(in srgb,var(--accent) 40%,var(--border))}
.card h3{margin-bottom:.4em}
.card p{color:var(--muted);margin-bottom:0}
.badge{display:inline-grid;place-items:center;width:48px;height:48px;border-radius:14px;background:var(--accent-soft);color:var(--accent);font-size:1.4rem;margin-bottom:16px}
.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:18px;margin-top:44px}
.stat{padding:20px;border-radius:var(--radius);background:var(--surface);border:1px solid var(--border);text-align:center}
.stat b{display:block;font-size:2.1rem;line-height:1.1;color:var(--accent)}
.stat span{color:var(--muted);font-size:.92rem}
.steps{counter-reset:s;display:grid;grid-template-columns:repeat(4,1fr);gap:22px;padding:0;list-style:none}
.steps li{position:relative;padding:22px;border:1px dashed var(--border);border-radius:var(--radius);counter-increment:s;background:var(--bg)}
.steps li::before{content:counter(s);display:grid;place-items:center;width:34px;height:34px;border-radius:50%;background:var(--accent);color:var(--accent-ink);font-weight:700;margin-bottom:12px}
.steps h3{font-size:1.05rem}
.steps p{color:var(--muted);margin:0;font-size:.95rem}
.cta-band{background:linear-gradient(120deg,var(--accent),var(--accent-2));color:#fff;border-radius:24px;padding:44px;display:flex;gap:24px;align-items:center;justify-content:space-between;flex-wrap:wrap}
.cta-band h2{margin:0 0 6px;color:#fff}
.cta-band p{margin:0;opacity:.92}
.cta-band .btn{background:#fff;color:#111a2c}

.slider{position:relative;max-width:820px;margin:0 auto}
.viewport{overflow:hidden;border-radius:var(--radius)}
.track{display:flex;transition:transform .55s cubic-bezier(.3,.7,.2,1)}
.slide{min-width:100%;margin:0;padding:34px 40px;background:var(--surface);border:1px solid var(--border);border-radius:var(--radius)}
.slide blockquote{margin:0 0 20px;font-size:1.15rem;line-height:1.6}
.slide figcaption{display:flex;align-items:center;gap:12px;color:var(--muted);font-size:.95rem}
.avatar{display:inline-grid;place-items:center;width:44px;height:44px;border-radius:50%;background:var(--accent);color:var(--accent-ink);font-weight:700;flex:none}
.avatar.a2{background:var(--accent-2)}
.stars{color:#f5a623;letter-spacing:2px;margin-bottom:10px}
.slider-ctl{display:flex;justify-content:center;align-items:center;gap:16px;margin-top:18px}
.dots{display:flex;gap:8px}
.dots button{width:10px;height:10px;border-radius:50%;border:0;padding:0;background:var(--border);cursor:pointer;transition:all .25s}
.dots button[aria-current=true]{width:28px;border-radius:99px;background:var(--accent)}

.thumb{height:150px;border-radius:12px;margin:-8px -8px 18px;display:grid;place-items:center;color:#fff;font-size:3rem;position:relative;overflow:hidden}
.thumb::after{content:"";position:absolute;inset:0;background:radial-gradient(circle at 80% 10%,rgba(255,255,255,.28),transparent 55%)}
.thumb .ic{width:56px;height:56px;stroke-width:1.5;z-index:1}
.g-1{background:linear-gradient(135deg,hsl(var(--h),70%,45%),hsl(calc(var(--h) + 50),70%,55%))}
.g-2{background:linear-gradient(135deg,hsl(calc(var(--h) + 120),60%,42%),hsl(calc(var(--h) + 170),65%,52%))}
.g-3{background:linear-gradient(135deg,hsl(calc(var(--h) + 200),65%,45%),hsl(calc(var(--h) + 250),70%,55%))}
.g-4{background:linear-gradient(135deg,hsl(calc(var(--h) + 30),75%,48%),hsl(calc(var(--h) + 80),70%,52%))}
.g-5{background:linear-gradient(135deg,hsl(calc(var(--h) + 90),55%,40%),hsl(calc(var(--h) + 140),60%,48%))}
.g-6{background:linear-gradient(135deg,hsl(calc(var(--h) + 160),65%,40%),hsl(calc(var(--h) + 220),65%,52%))}
.tag{display:inline-block;padding:2px 10px;border-radius:99px;background:var(--surface-2);color:var(--muted);font-size:.8rem;font-weight:600}
.meta{display:flex;flex-wrap:wrap;gap:10px;align-items:center;color:var(--muted);font-size:.88rem;margin-bottom:10px}
.card .more{display:inline-flex;gap:6px;align-items:center;margin-top:14px;font-weight:600;background:none;border:0;padding:0;color:var(--accent);cursor:pointer;font:inherit;font-weight:600}

.toolbar{display:flex;flex-wrap:wrap;gap:14px;align-items:center;justify-content:space-between;margin-bottom:26px}
.chips{display:flex;flex-wrap:wrap;gap:8px}
.chip{padding:8px 16px;border-radius:99px;border:1px solid var(--border);background:var(--surface);color:var(--text);font:inherit;font-size:.92rem;cursor:pointer;transition:all .15s}
.chip:hover{border-color:var(--accent)}
.chip[aria-pressed=true]{background:var(--accent);border-color:var(--accent);color:var(--accent-ink)}
.search{position:relative;min-width:240px}
.search .ic{position:absolute;left:13px;top:50%;transform:translateY(-50%);color:var(--muted)}
.search input{padding-left:40px}
.empty{display:none;text-align:center;padding:40px;color:var(--muted)}
.empty.show{display:block}
[hidden]{display:none!important}

dialog{border:0;border-radius:20px;padding:0;max-width:560px;width:calc(100% - 32px);background:var(--surface);color:var(--text);box-shadow:0 30px 80px rgba(0,0,0,.35)}
dialog::backdrop{background:rgba(8,12,22,.6);backdrop-filter:blur(3px)}
.dlg-body{padding:0 28px 28px}
.dlg-body .thumb{margin:0 -28px 20px;border-radius:0;height:170px}
.dlg-close{position:absolute;right:14px;top:14px;z-index:2;background:rgba(0,0,0,.35);color:#fff;border-color:transparent}
.dlg-body dl{display:grid;grid-template-columns:auto 1fr;gap:6px 18px;margin:16px 0 0}
.dlg-body dt{color:var(--muted)}
.dlg-body dd{margin:0;font-weight:600}

label{display:block;font-weight:600;font-size:.92rem;margin-bottom:6px}
input,select,textarea{width:100%;padding:12px 14px;border-radius:12px;border:1px solid var(--border);background:var(--surface);color:var(--text);font:inherit;transition:border-color .15s,box-shadow .15s}
textarea{min-height:130px;resize:vertical}
input:focus,select:focus,textarea:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 3px color-mix(in srgb,var(--accent) 25%,transparent)}
.field{margin-bottom:18px}
.field.invalid input,.field.invalid select,.field.invalid textarea{border-color:#d93a4a}
.err{display:none;color:#d93a4a;font-size:.85rem;margin-top:5px}
.field.invalid .err{display:block}
.row2{display:grid;grid-template-columns:1fr 1fr;gap:18px}
.check{display:flex;gap:10px;align-items:flex-start;font-weight:400}
.check input{width:auto;margin-top:5px;accent-color:var(--accent)}
.counter{float:right;font-weight:400;color:var(--muted)}
.hp{position:absolute;left:-9999px;opacity:0;height:0;overflow:hidden}
.notice{display:none;padding:18px 20px;border-radius:14px;background:color-mix(in srgb,#1fa971 14%,var(--surface));border:1px solid #1fa971;margin-bottom:18px}
.notice.show{display:block}
.contact-grid{display:grid;grid-template-columns:1.15fr .85fr;gap:30px;align-items:start}
.info-list{list-style:none;padding:0;margin:0}
.info-list li{display:flex;gap:14px;padding:14px 0;border-bottom:1px solid var(--border)}
.info-list li:last-child{border:0}
.info-list .ic{color:var(--accent);font-size:1.3rem;margin-top:2px}
.info-list b{display:block}
.map{width:100%;height:auto;border-radius:12px;margin-top:10px;border:1px solid var(--border)}
.map .bg{fill:var(--surface-2)}
.map .rd{stroke:var(--surface);stroke-width:10;fill:none}
.map .rd2{stroke:var(--surface);stroke-width:5;fill:none}
.map .bl{fill:var(--border)}
.map .pin{fill:var(--accent)}

.calc{display:grid;grid-template-columns:1.1fr .9fr;gap:28px;align-items:start}
.calc-out{position:sticky;top:90px;background:linear-gradient(150deg,var(--accent),var(--accent-2));color:#fff;border-radius:var(--radius);padding:30px}
.calc-out small{opacity:.85}
.calc-sum{font-size:clamp(1.7rem,3.5vw,2.4rem);font-weight:800;line-height:1.15;margin:6px 0 14px}
.calc-out .btn{background:#fff;color:#111a2c;width:100%}
.range-line{display:flex;justify-content:space-between;align-items:center;margin-bottom:6px}
input[type=range]{padding:0;height:6px;border:0;background:var(--border);accent-color:var(--accent);box-shadow:none}
.opts{display:grid;gap:10px}
.opt{display:flex;gap:12px;align-items:center;padding:12px 14px;border:1px solid var(--border);border-radius:12px;background:var(--surface);cursor:pointer;font-weight:500;margin:0}
.opt input{width:auto;accent-color:var(--accent)}
.opt small{margin-left:auto;color:var(--muted);font-weight:400}

.faq{max-width:780px;margin:0 auto;display:grid;gap:12px}
.faq-item{background:var(--surface);border:1px solid var(--border);border-radius:14px;overflow:hidden}
.faq-q{display:flex;width:100%;align-items:center;justify-content:space-between;gap:14px;padding:18px 22px;background:none;border:0;color:var(--text);font:inherit;font-weight:600;text-align:left;cursor:pointer}
.faq-q .ic{transition:transform .25s;color:var(--accent)}
.faq-q[aria-expanded=true] .ic{transform:rotate(45deg)}
.faq-a{max-height:0;overflow:hidden;transition:max-height .3s ease}
.faq-a p{padding:0 22px 20px;margin:0;color:var(--muted)}

.page-head{padding:54px 0 30px;border-bottom:1px solid var(--border);background:linear-gradient(180deg,var(--accent-soft),transparent)}
.crumbs{font-size:.88rem;color:var(--muted);margin-bottom:12px}
.article{max-width:740px;margin:0 auto;padding:48px 20px 20px}
.article h2{margin-top:1.6em;font-size:1.5rem}
.article p,.article li{font-size:1.06rem}
.article .meta{margin-bottom:24px}
.article-nav{display:flex;justify-content:space-between;gap:16px;flex-wrap:wrap;margin-top:34px;padding-top:22px;border-top:1px solid var(--border)}
.timeline{list-style:none;margin:0;padding:0 0 0 22px;border-left:2px solid var(--border)}
.timeline li{position:relative;padding:0 0 26px 20px}
.timeline li::before{content:"";position:absolute;left:-30px;top:6px;width:14px;height:14px;border-radius:50%;background:var(--accent);box-shadow:0 0 0 4px var(--accent-soft)}
.timeline b{display:block;color:var(--accent)}
.team .avatar{width:64px;height:64px;font-size:1.3rem;margin-bottom:14px}
.split{display:grid;grid-template-columns:1fr 1fr;gap:44px;align-items:center}
.checklist{list-style:none;padding:0;margin:0}
.checklist li{display:flex;gap:10px;padding:6px 0}
.checklist .ic{color:var(--accent);margin-top:4px}
.nf{padding:90px 0;text-align:center}
.nf .code{font-size:clamp(5rem,16vw,9rem);font-weight:800;line-height:1;background:linear-gradient(120deg,var(--accent),var(--accent-2));-webkit-background-clip:text;background-clip:text;color:transparent}
.nf-links{display:flex;gap:10px;justify-content:center;flex-wrap:wrap;margin-top:22px}

.site-footer{background:var(--surface);border-top:1px solid var(--border);padding:48px 0 26px;margin-top:40px;font-size:.95rem}
.foot-grid{display:grid;grid-template-columns:1.4fr 1fr 1fr 1fr;gap:30px}
.site-footer .logo{margin-bottom:12px}
.foot-grid h4{font-size:.95rem;margin-bottom:12px}
.foot-grid ul{list-style:none;margin:0;padding:0}
.foot-grid li{margin-bottom:8px}
.foot-grid a{color:var(--muted)}
.foot-grid a:hover{color:var(--accent)}
.copy{display:flex;flex-wrap:wrap;justify-content:space-between;gap:10px;margin-top:30px;padding-top:20px;border-top:1px solid var(--border);color:var(--muted);font-size:.88rem}
.to-top{position:fixed;right:20px;bottom:20px;opacity:0;pointer-events:none;transition:opacity .25s;z-index:40;box-shadow:var(--shadow)}
.to-top.show{opacity:1;pointer-events:auto}
.cookie{position:fixed;left:16px;right:16px;bottom:16px;max-width:560px;margin:0 auto;background:var(--surface);border:1px solid var(--border);border-radius:16px;padding:16px 18px;box-shadow:var(--shadow);display:none;gap:14px;align-items:center;z-index:60;font-size:.9rem}
.cookie.show{display:flex}
.cookie p{margin:0;color:var(--muted)}
.toast{position:fixed;left:50%;bottom:28px;transform:translate(-50%,20px);background:var(--text);color:var(--bg);padding:12px 20px;border-radius:12px;opacity:0;transition:all .3s;z-index:90;pointer-events:none}
.toast.show{opacity:1;transform:translate(-50%,0)}

@media (max-width:960px){
.g3,.g4{grid-template-columns:repeat(2,1fr)}
.steps,.stats{grid-template-columns:repeat(2,1fr)}
.hero-grid,.split,.calc,.contact-grid{grid-template-columns:1fr}
.calc-out{position:static}
.foot-grid{grid-template-columns:1fr 1fr}
}
@media (max-width:760px){
.burger{display:inline-grid}
#theme-toggle{margin-left:auto}
.menu{display:none;position:absolute;top:68px;left:0;right:0;flex-direction:column;background:var(--bg);border-bottom:1px solid var(--border);padding:10px 20px 16px;margin:0}
.menu.open{display:flex}
.menu a{padding:12px 14px}
.hero{padding:44px 0 36px}
.section{padding:44px 0}
.g2,.g3,.g4,.steps,.row2{grid-template-columns:1fr}
.stats{grid-template-columns:1fr 1fr}
.slide{padding:24px}
.cta-band{padding:28px}
.foot-grid{grid-template-columns:1fr}
.search{width:100%}
}
@media (prefers-reduced-motion:reduce){*{transition:none!important;animation:none!important;scroll-behavior:auto!important}}
DECOY_CSS_EOF

    cat > "$d/theme.js" <<'DECOY_THEME_EOF'
(function () {
  try {
    var t = localStorage.getItem('theme');
    if (!t) { t = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'; }
    document.documentElement.setAttribute('data-theme', t);
  } catch (e) {
    document.documentElement.setAttribute('data-theme', 'light');
  }
})();
DECOY_THEME_EOF

    cat > "$d/icons.svg" <<'DECOY_ICONS_EOF'
<svg xmlns="http://www.w3.org/2000/svg">
<symbol id="i-logo" viewBox="0 0 32 32"><rect width="32" height="32" rx="9"/><path d="M9 22V10h6.5a4 4 0 0 1 0 8H13" fill="none" stroke="#fff" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/><circle cx="21.5" cy="21.5" r="2.2" fill="#fff"/></symbol>
<symbol id="i-sun" viewBox="0 0 24 24"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></symbol>
<symbol id="i-moon" viewBox="0 0 24 24"><path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"/></symbol>
<symbol id="i-menu" viewBox="0 0 24 24"><path d="M4 7h16M4 12h16M4 17h16"/></symbol>
<symbol id="i-close" viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18"/></symbol>
<symbol id="i-plus" viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></symbol>
<symbol id="i-web" viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="14" rx="2"/><path d="M3 9h18M8 21h8M12 18v3"/></symbol>
<symbol id="i-mobile" viewBox="0 0 24 24"><rect x="7" y="2" width="10" height="20" rx="2.5"/><path d="M11 18h2"/></symbol>
<symbol id="i-auto" viewBox="0 0 24 24"><path d="M4 12a8 8 0 0 1 14-5l2 2M20 4v5h-5M20 12a8 8 0 0 1-14 5l-2-2M4 20v-5h5"/></symbol>
<symbol id="i-design" viewBox="0 0 24 24"><path d="M12 3l9 5-9 5-9-5 9-5zM3 13l9 5 9-5"/></symbol>
<symbol id="i-support" viewBox="0 0 24 24"><path d="M4 14v-2a8 8 0 0 1 16 0v2"/><rect x="3" y="14" width="4" height="6" rx="1.5"/><rect x="17" y="14" width="4" height="6" rx="1.5"/></symbol>
<symbol id="i-shield" viewBox="0 0 24 24"><path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6l8-3z"/><path d="M9 12l2 2 4-4"/></symbol>
<symbol id="i-rocket" viewBox="0 0 24 24"><path d="M14 4c4 0 6 2 6 6-2 4-5 7-9 8l-5-5c1-4 4-7 8-9zM5 19c0-3 2-4 4-4"/><circle cx="14.5" cy="9.5" r="1.5"/></symbol>
<symbol id="i-chart" viewBox="0 0 24 24"><path d="M4 20V4M4 20h16M8 16v-5M13 16V8M18 16v-9"/></symbol>
<symbol id="i-code" viewBox="0 0 24 24"><path d="M8 8l-5 4 5 4M16 8l5 4-5 4M14 5l-4 14"/></symbol>
<symbol id="i-mail" viewBox="0 0 24 24"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 7l9 6 9-6"/></symbol>
<symbol id="i-phone" viewBox="0 0 24 24"><path d="M5 4h4l2 5-2.5 1.5a11 11 0 0 0 5 5L15 13l5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 6a2 2 0 0 1 2-2z"/></symbol>
<symbol id="i-pin" viewBox="0 0 24 24"><path d="M12 21s7-6 7-11a7 7 0 0 0-14 0c0 5 7 11 7 11z"/><circle cx="12" cy="10" r="2.5"/></symbol>
<symbol id="i-clock" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></symbol>
<symbol id="i-arrow" viewBox="0 0 24 24"><path d="M5 12h14M13 6l6 6-6 6"/></symbol>
<symbol id="i-left" viewBox="0 0 24 24"><path d="M15 6l-6 6 6 6"/></symbol>
<symbol id="i-right" viewBox="0 0 24 24"><path d="M9 6l6 6-6 6"/></symbol>
<symbol id="i-up" viewBox="0 0 24 24"><path d="M6 15l6-6 6 6"/></symbol>
<symbol id="i-check" viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5"/></symbol>
<symbol id="i-search" viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="M20 20l-4-4"/></symbol>
</svg>
DECOY_ICONS_EOF

    cat > "$d/app.js" <<'DECOY_APP_EOF'
(function () {
  'use strict';

  var $ = function (s, r) { return (r || document).querySelector(s); };
  var $$ = function (s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); };
  var store = {
    get: function (k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set: function (k, v) { try { localStorage.setItem(k, v); } catch (e) { /* private mode */ } }
  };

  function toast(msg) {
    var t = $('.toast');
    if (!t) { t = document.createElement('div'); t.className = 'toast'; t.setAttribute('role', 'status'); document.body.appendChild(t); }
    t.textContent = msg;
    t.classList.add('show');
    clearTimeout(toast.timer);
    toast.timer = setTimeout(function () { t.classList.remove('show'); }, 3200);
  }

  /* ---------- navigation, theme ---------- */
  var menu = $('#menu'), burger = $('.burger');
  if (menu && burger) {
    burger.addEventListener('click', function () {
      var open = menu.classList.toggle('open');
      burger.setAttribute('aria-expanded', open ? 'true' : 'false');
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && menu.classList.contains('open')) { menu.classList.remove('open'); burger.setAttribute('aria-expanded', 'false'); }
    });
  }
  var path = location.pathname.replace(/index\.html$/, '');
  $$('#menu a').forEach(function (a) {
    var p = a.getAttribute('href').replace(/index\.html$/, '');
    if (p === path || (p !== '/' && path.indexOf(p.replace(/\.html$/, '')) === 0 && p !== '/')) { a.setAttribute('aria-current', 'page'); }
  });

  var themeBtn = $('#theme-toggle');
  if (themeBtn) {
    themeBtn.addEventListener('click', function () {
      var next = document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
      document.documentElement.setAttribute('data-theme', next);
      store.set('theme', next);
      themeBtn.setAttribute('aria-pressed', next === 'dark' ? 'true' : 'false');
    });
    themeBtn.setAttribute('aria-pressed', document.documentElement.getAttribute('data-theme') === 'dark' ? 'true' : 'false');
  }

  var toTop = $('.to-top');
  if (toTop) {
    window.addEventListener('scroll', function () { toTop.classList.toggle('show', window.scrollY > 600); }, { passive: true });
    toTop.addEventListener('click', function () { window.scrollTo({ top: 0, behavior: 'smooth' }); });
  }

  var cookie = $('.cookie');
  if (cookie && !store.get('cookie-ok')) {
    cookie.classList.add('show');
    $('button', cookie).addEventListener('click', function () { store.set('cookie-ok', '1'); cookie.classList.remove('show'); });
  }

  /* ---------- animated counters ---------- */
  var counters = $$('[data-count]');
  function runCounter(el) {
    var end = parseFloat(el.getAttribute('data-count')), suffix = el.getAttribute('data-suffix') || '', start = null, dur = 1400;
    function step(ts) {
      if (start === null) { start = ts; }
      var p = Math.min((ts - start) / dur, 1), eased = 1 - Math.pow(1 - p, 3);
      el.textContent = Math.round(end * eased).toLocaleString('ru-RU') + suffix;
      if (p < 1) { requestAnimationFrame(step); }
    }
    requestAnimationFrame(step);
  }
  if (counters.length && 'IntersectionObserver' in window) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) { if (en.isIntersecting) { runCounter(en.target); io.unobserve(en.target); } });
    }, { threshold: 0.4 });
    counters.forEach(function (c) { io.observe(c); });
  } else {
    counters.forEach(function (c) { c.textContent = c.getAttribute('data-count') + (c.getAttribute('data-suffix') || ''); });
  }

  /* ---------- slider ---------- */
  $$('[data-slider]').forEach(function (root) {
    var track = $('.track', root), slides = $$('.slide', root), dotsBox = $('.dots', root), i = 0, timer = null, sx = null;
    slides.forEach(function (_, n) {
      var b = document.createElement('button');
      b.type = 'button'; b.setAttribute('aria-label', 'Слайд ' + (n + 1));
      b.addEventListener('click', function () { go(n); restart(); });
      dotsBox.appendChild(b);
    });
    function go(n) {
      i = (n + slides.length) % slides.length;
      track.style.transform = 'translateX(' + (-100 * i) + '%)';
      $$('button', dotsBox).forEach(function (b, k) { b.setAttribute('aria-current', k === i ? 'true' : 'false'); });
      slides.forEach(function (s, k) { s.setAttribute('aria-hidden', k === i ? 'false' : 'true'); });
    }
    function restart() { clearInterval(timer); timer = setInterval(function () { go(i + 1); }, 6500); }
    $('[data-prev]', root).addEventListener('click', function () { go(i - 1); restart(); });
    $('[data-next]', root).addEventListener('click', function () { go(i + 1); restart(); });
    root.addEventListener('mouseenter', function () { clearInterval(timer); });
    root.addEventListener('mouseleave', restart);
    root.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowLeft') { go(i - 1); restart(); }
      if (e.key === 'ArrowRight') { go(i + 1); restart(); }
    });
    root.addEventListener('pointerdown', function (e) { sx = e.clientX; });
    root.addEventListener('pointerup', function (e) {
      if (sx !== null && Math.abs(e.clientX - sx) > 45) { go(i + (e.clientX < sx ? 1 : -1)); restart(); }
      sx = null;
    });
    go(0); restart();
  });

  /* ---------- FAQ accordion ---------- */
  $$('.faq-q').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var open = btn.getAttribute('aria-expanded') === 'true', panel = document.getElementById(btn.getAttribute('aria-controls'));
      $$('.faq-q', btn.closest('.faq')).forEach(function (o) {
        o.setAttribute('aria-expanded', 'false');
        document.getElementById(o.getAttribute('aria-controls')).style.maxHeight = null;
      });
      if (!open) { btn.setAttribute('aria-expanded', 'true'); panel.style.maxHeight = panel.scrollHeight + 'px'; }
    });
  });

  /* ---------- filters + search (projects, blog) ---------- */
  $$('[data-filter-root]').forEach(function (root) {
    var items = $$('[data-item]', root), chips = $$('[data-chip]', root), input = $('[data-search]', root), empty = $('[data-empty]', root), cat = 'all';
    function apply() {
      var q = (input ? input.value : '').trim().toLowerCase(), shown = 0;
      items.forEach(function (it) {
        var ok = (cat === 'all' || it.getAttribute('data-cat') === cat) && (!q || it.textContent.toLowerCase().indexOf(q) !== -1);
        it.hidden = !ok;
        if (ok) { shown++; }
      });
      if (empty) { empty.classList.toggle('show', shown === 0); }
    }
    chips.forEach(function (c) {
      c.addEventListener('click', function () {
        cat = c.getAttribute('data-chip');
        chips.forEach(function (o) { o.setAttribute('aria-pressed', o === c ? 'true' : 'false'); });
        apply();
      });
    });
    if (input) { input.addEventListener('input', apply); }
  });

  /* ---------- project modal ---------- */
  var dlg = $('#project-dialog');
  if (dlg) {
    $$('[data-open]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var card = btn.closest('[data-item]');
        $('#dlg-title').textContent = card.getAttribute('data-title');
        $('#dlg-text').textContent = card.getAttribute('data-text');
        $('#dlg-client').textContent = card.getAttribute('data-client');
        $('#dlg-term').textContent = card.getAttribute('data-term');
        $('#dlg-stack').textContent = card.getAttribute('data-stack');
        $('#dlg-thumb').className = 'thumb ' + card.getAttribute('data-grad');
        if (typeof dlg.showModal === 'function') { dlg.showModal(); } else { dlg.setAttribute('open', ''); }
      });
    });
    $$('[data-close]', dlg).forEach(function (b) { b.addEventListener('click', function () { dlg.close(); }); });
    dlg.addEventListener('click', function (e) { if (e.target === dlg) { dlg.close(); } });
  }

  /* ---------- cost calculator ---------- */
  var calc = $('[data-calc]');
  if (calc) {
    var types = {
      landing: { base: 60000, unit: 4500, weeks: 2, label: 'страниц/блоков' },
      site: { base: 120000, unit: 9000, weeks: 4, label: 'страниц' },
      shop: { base: 240000, unit: 11000, weeks: 8, label: 'разделов каталога' },
      mobile: { base: 320000, unit: 28000, weeks: 10, label: 'экранов' },
      internal: { base: 280000, unit: 22000, weeks: 9, label: 'модулей' }
    };
    var f = {
      type: $('[name=type]', calc), units: $('[name=units]', calc), design: $('[name=design]', calc), integr: $('[name=integr]', calc),
      urgent: $('[name=urgent]', calc), support: $('[name=support]', calc)
    };
    var out = { sum: $('#calc-sum'), weeks: $('#calc-weeks'), units: $('#calc-units'), label: $('#calc-unit-label') };
    var fmt = function (n) { return (Math.round(n / 1000) * 1000).toLocaleString('ru-RU') + '\u00a0₽'; };
    var recalc = function () {
      var t = types[f.type.value], u = parseInt(f.units.value, 10), total = t.base + t.unit * u, weeks = t.weeks + Math.ceil(u / 6);
      if (f.design.checked) { total += total * 0.18; weeks += 1; }
      if (f.integr.checked) { total += 70000; weeks += 2; }
      if (f.support.checked) { total += 45000; }
      if (f.urgent.checked) { total *= 1.3; weeks = Math.max(2, Math.ceil(weeks * 0.7)); }
      out.units.textContent = u;
      out.label.textContent = t.label;
      out.sum.textContent = 'от ' + fmt(total * 0.9) + ' до ' + fmt(total * 1.15);
      out.weeks.textContent = weeks + ' ' + (weeks % 10 === 1 && weeks % 100 !== 11 ? 'неделя' : ([2, 3, 4].indexOf(weeks % 10) !== -1 && [12, 13, 14].indexOf(weeks % 100) === -1 ? 'недели' : 'недель'));
    };
    $$('input,select', calc).forEach(function (el) { el.addEventListener('input', recalc); el.addEventListener('change', recalc); });
    recalc();
  }

  /* ---------- contact form (client side only) ---------- */
  var form = $('#contact-form');
  if (form) {
    var rules = {
      name: function (v) { return v.trim().length >= 2 ? '' : 'Укажите имя (не короче 2 символов)'; },
      email: function (v) { return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(v.trim()) ? '' : 'Введите корректный e-mail'; },
      phone: function (v) { var d = v.replace(/\D/g, ''); return !v || (d.length === 11) ? '' : 'Телефон в формате +7 (900) 000-00-00'; },
      topic: function (v) { return v ? '' : 'Выберите тему обращения'; },
      message: function (v) { return v.trim().length >= 10 ? '' : 'Опишите задачу подробнее (минимум 10 символов)'; },
      agree: function (v, el) { return el.checked ? '' : 'Необходимо согласие на обработку данных'; }
    };
    var check = function (el) {
      var field = el.closest('.field'), msg = rules[el.name](el.value, el);
      field.classList.toggle('invalid', !!msg);
      $('.err', field).textContent = msg;
      el.setAttribute('aria-invalid', msg ? 'true' : 'false');
      return !msg;
    };
    var phone = form.elements.phone;
    phone.addEventListener('input', function () {
      var d = phone.value.replace(/\D/g, '');
      if (d[0] === '8' || d[0] === '7') { d = d.slice(1); }
      d = d.slice(0, 10);
      var s = d.length ? '+7 (' + d.slice(0, 3) : '';
      if (d.length >= 3) { s += ') ' + d.slice(3, 6); }
      if (d.length >= 6) { s += '-' + d.slice(6, 8); }
      if (d.length >= 8) { s += '-' + d.slice(8, 10); }
      phone.value = s;
    });
    var msgEl = form.elements.message, counter = $('#msg-count');
    msgEl.addEventListener('input', function () {
      if (msgEl.value.length > 500) { msgEl.value = msgEl.value.slice(0, 500); }
      counter.textContent = msgEl.value.length + ' / 500';
    });
    Object.keys(rules).forEach(function (n) {
      var el = form.elements[n];
      el.addEventListener('blur', function () { check(el); });
      el.addEventListener('input', function () { if (el.closest('.field').classList.contains('invalid')) { check(el); } });
      el.addEventListener('change', function () { check(el); });
    });
    form.addEventListener('submit', function (e) {
      e.preventDefault();
      var ok = true, first = null;
      Object.keys(rules).forEach(function (n) { var el = form.elements[n]; if (!check(el)) { ok = false; first = first || el; } });
      if (form.elements.website.value) { return; }
      if (!ok) { first.focus(); return; }
      var btn = $('button[type=submit]', form), label = btn.textContent;
      btn.disabled = true; btn.textContent = 'Отправляем…';
      setTimeout(function () {
        btn.disabled = false; btn.textContent = label;
        form.reset(); counter.textContent = '0 / 500';
        var n = $('#form-ok');
        n.classList.add('show');
        n.scrollIntoView({ behavior: 'smooth', block: 'center' });
        toast('Заявка отправлена. Мы свяжемся с вами в рабочее время.');
      }, 1100);
    });
  }

  $$('[data-calc-go]').forEach(function (a) {
    a.addEventListener('click', function () { store.set('calc', $('#calc-sum') ? $('#calc-sum').textContent : ''); });
  });
})();
DECOY_APP_EOF

    cat > "$d/../favicon.svg" <<'DECOY_FAV_EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="9" fill="__HEX__"/><path d="M9 22V10h6.5a4 4 0 0 1 0 8H13" fill="none" stroke="#fff" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/><circle cx="21.5" cy="21.5" r="2.2" fill="#fff"/></svg>
DECOY_FAV_EOF
}

_decoy_write_favicon_ico() {
    # 16x16 32-бит ICO без внешних утилит: цветной скруглённый квадрат с белой точкой.
    local out="$1" hex="${2#\#}" r g b x y row px_color
    r=$((16#${hex:0:2})); g=$((16#${hex:2:2})); b=$((16#${hex:4:2}))
    printf -v px_color '\\x%02x\\x%02x\\x%02x\\xff' "$b" "$g" "$r"
    {
        printf '\x00\x00\x01\x00\x01\x00'
        printf '\x10\x10\x00\x00\x01\x00\x20\x00\x68\x04\x00\x00\x16\x00\x00\x00'
        printf '\x28\x00\x00\x00\x10\x00\x00\x00\x20\x00\x00\x00\x01\x00\x20\x00'
        printf '\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00'
        for ((y = 15; y >= 0; y--)); do
            for ((x = 0; x < 16; x++)); do
                if { (( (x == 0 || x == 15) && (y <= 1 || y >= 14) )) || (( (x == 1 || x == 14) && (y == 0 || y == 15) )); }; then
                    printf '\x00\x00\x00\x00'
                elif (( x >= 5 && x <= 10 && y >= 5 && y <= 10 && (x - 7) * (x - 7) + (y - 7) * (y - 7) <= 9 )); then
                    printf '\xff\xff\xff\xff'
                else
                    # shellcheck disable=SC2059
                    printf "$px_color"
                fi
            done
        done
        for ((row = 0; row < 16; row++)); do printf '\x00\x00\x00\x00'; done
    } > "$out"
}

_decoy_tpl_head() {
    cat <<'DECOY_HEAD_EOF'
<!DOCTYPE html>
<html lang="ru" data-theme="light">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__PAGE_TITLE__</title>
<meta name="description" content="__PAGE_DESC__">
<meta name="robots" content="__PAGE_ROBOTS__">
<meta name="generator" content="sitegen-lite">
<meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#0e121b" media="(prefers-color-scheme: dark)">
<link rel="canonical" href="https://__DOMAIN__/__PAGE_PATH__">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="icon" href="/favicon.ico" sizes="any">
<meta property="og:type" content="website">
<meta property="og:locale" content="ru_RU">
<meta property="og:site_name" content="__BRAND__">
<meta property="og:title" content="__PAGE_TITLE__">
<meta property="og:description" content="__PAGE_DESC__">
<meta property="og:url" content="https://__DOMAIN__/__PAGE_PATH__">
<script src="/assets/theme.js"></script>
<link rel="stylesheet" href="/assets/style.css">
</head>
<body>
<a class="skip" href="#main">Перейти к содержимому</a>
<header class="site-header">
  <div class="wrap nav">
    <a class="logo" href="/" aria-label="__BRAND__ — на главную"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-logo"/></svg><span>__BRAND__</span></a>
    <ul class="menu" id="menu">
      <li><a href="/">Главная</a></li>
      <li><a href="/services.html">Услуги</a></li>
      <li><a href="/portfolio.html">Проекты</a></li>
      <li><a href="/blog.html">Блог</a></li>
      <li><a href="/about.html">О компании</a></li>
      <li><a href="/contacts.html">Контакты</a></li>
    </ul>
    <button class="icon-btn" id="theme-toggle" type="button" aria-label="Переключить тёмную тему"><svg class="ic theme-ic-sun" aria-hidden="true"><use href="/assets/icons.svg#i-sun"/></svg><svg class="ic theme-ic-moon" aria-hidden="true"><use href="/assets/icons.svg#i-moon"/></svg></button>
    <button class="icon-btn burger" type="button" aria-label="Меню" aria-expanded="false" aria-controls="menu"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-menu"/></svg></button>
  </div>
</header>
<main id="main">
DECOY_HEAD_EOF
}

_decoy_tpl_foot() {
    cat <<'DECOY_FOOT_EOF'
</main>
<footer class="site-footer">
  <div class="wrap">
    <div class="foot-grid">
      <div>
        <a class="logo" href="/"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-logo"/></svg><span>__BRAND__</span></a>
        <p class="muted">Студия разработки сайтов, мобильных приложений и внутренних сервисов. Работаем с 2014 года.</p>
      </div>
      <div>
        <h4>Услуги</h4>
        <ul>
          <li><a href="/services.html">Разработка сайтов</a></li>
          <li><a href="/services.html">Мобильные приложения</a></li>
          <li><a href="/services.html">Автоматизация</a></li>
          <li><a href="/services.html#calc">Калькулятор стоимости</a></li>
        </ul>
      </div>
      <div>
        <h4>Компания</h4>
        <ul>
          <li><a href="/about.html">О нас</a></li>
          <li><a href="/portfolio.html">Проекты</a></li>
          <li><a href="/blog.html">Блог</a></li>
          <li><a href="/privacy.html">Конфиденциальность</a></li>
        </ul>
      </div>
      <div>
        <h4>Контакты</h4>
        <ul>
          <li><a href="mailto:hello@__DOMAIN__">hello@__DOMAIN__</a></li>
          <li><a href="tel:+74955550124">+7 (495) 555-01-24</a></li>
          <li class="muted">Пн–Пт, 10:00–19:00</li>
        </ul>
      </div>
    </div>
    <div class="copy"><span>© __YEAR__ __BRAND__. Все права защищены.</span><a href="/privacy.html">Политика конфиденциальности</a></div>
  </div>
</footer>
<button class="icon-btn to-top" type="button" aria-label="Наверх"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-up"/></svg></button>
<div class="cookie" role="dialog" aria-label="Уведомление о cookie"><p>Мы используем cookie, чтобы сайт работал стабильнее и запоминал ваши настройки, например тему оформления.</p><button class="btn small" type="button">Понятно</button></div>
<script src="/assets/app.js" defer></script>
</body>
</html>
DECOY_FOOT_EOF
}

# _decoy_page <файл> <title> <description> <path-для-canonical> [robots] < тело страницы
_decoy_page() {
    local out="$1" title="$2" desc="$3" ppath="$4" robots="${5:-index,follow}"
    mkdir -p "$(dirname "$out")"
    {
        _decoy_tpl_head
        cat
        _decoy_tpl_foot
    } | sed \
        -e "s|__PAGE_TITLE__|$(_decoy_sedesc "$title")|g" \
        -e "s|__PAGE_DESC__|$(_decoy_sedesc "$desc")|g" \
        -e "s|__PAGE_PATH__|$(_decoy_sedesc "$ppath")|g" \
        -e "s|__PAGE_ROBOTS__|${robots}|g" \
        > "$out"
}

_decoy_write_pages_main() {
    local r="$1"

    _decoy_page "$r/index.html" \
        "__BRAND__ — разработка сайтов, приложений и сервисов для бизнеса" \
        "Студия «__BRAND__»: разрабатываем сайты, мобильные приложения и внутренние сервисы. Прозрачные сроки, фиксированная смета, поддержка после запуска." \
        "" <<'DECOY_INDEX_EOF'
<section class="hero">
  <div class="wrap hero-grid">
    <div>
      <span class="eyebrow"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-rocket"/></svg>Цифровая студия полного цикла</span>
      <h1>Делаем цифровые продукты, которые работают на ваш бизнес</h1>
      <p class="lead">Сайты, мобильные приложения и внутренние сервисы: от идеи и прототипа до запуска и сопровождения. Фиксируем смету и сроки до начала работ.</p>
      <div class="hero-cta">
        <a class="btn" href="/contacts.html">Обсудить проект <svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-arrow"/></svg></a>
        <a class="btn ghost" href="/services.html#calc">Рассчитать стоимость</a>
      </div>
    </div>
    <svg class="hero-art" viewBox="0 0 480 360" role="img" aria-label="Иллюстрация: панель аналитики">
      <rect class="w" x="20" y="24" width="440" height="300" rx="18"/>
      <path class="ln" d="M20 66h440"/>
      <circle class="dot" cx="48" cy="45" r="6"/><circle class="bar2" cx="68" cy="45" r="6"/><circle class="tx" cx="88" cy="45" r="6"/>
      <rect class="tx" x="44" y="90" width="110" height="214" rx="10"/>
      <rect class="bar" x="56" y="106" width="60" height="8" rx="4"/>
      <rect class="w" x="56" y="130" width="86" height="8" rx="4"/><rect class="w" x="56" y="152" width="70" height="8" rx="4"/><rect class="w" x="56" y="174" width="80" height="8" rx="4"/>
      <rect class="tx" x="174" y="90" width="124" height="64" rx="10"/><rect class="tx" x="312" y="90" width="124" height="64" rx="10"/>
      <rect class="bar" x="188" y="106" width="50" height="10" rx="5"/><rect class="bar2" x="326" y="106" width="50" height="10" rx="5"/>
      <rect class="w" x="188" y="128" width="84" height="8" rx="4"/><rect class="w" x="326" y="128" width="84" height="8" rx="4"/>
      <rect class="tx" x="174" y="170" width="262" height="134" rx="10"/>
      <rect class="bar" x="196" y="250" width="22" height="40" rx="5"/><rect class="bar2" x="232" y="226" width="22" height="64" rx="5"/><rect class="bar" x="268" y="240" width="22" height="50" rx="5"/><rect class="bar2" x="304" y="204" width="22" height="86" rx="5"/><rect class="bar" x="340" y="216" width="22" height="74" rx="5"/><rect class="bar2" x="376" y="190" width="22" height="100" rx="5"/>
      <path class="pl" d="M200 236L238 214L274 226L312 190L348 202L388 176"/>
    </svg>
  </div>
  <div class="wrap stats">
    <div class="stat"><b data-count="11" data-suffix=" лет">11 лет</b><span>на рынке разработки</span></div>
    <div class="stat"><b data-count="240" data-suffix="+">240+</b><span>реализованных проектов</span></div>
    <div class="stat"><b data-count="38">38</b><span>специалистов в команде</span></div>
    <div class="stat"><b data-count="97" data-suffix="%">97%</b><span>клиентов продолжают работу</span></div>
  </div>
</section>

<section class="section">
  <div class="wrap">
    <div class="section-head">
      <h2>Чем мы занимаемся</h2>
      <p>Берём на себя весь цикл: аналитику, дизайн, разработку, тестирование и поддержку.</p>
    </div>
    <div class="grid g3">
      <article class="card"><span class="badge"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-web"/></svg></span><h3>Сайты и веб-сервисы</h3><p>Корпоративные сайты, интернет-магазины, личные кабинеты и порталы с удобной админ-панелью.</p></article>
      <article class="card"><span class="badge"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-mobile"/></svg></span><h3>Мобильные приложения</h3><p>iOS и Android: нативная и кроссплатформенная разработка, публикация в магазинах приложений.</p></article>
      <article class="card"><span class="badge"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-auto"/></svg></span><h3>Автоматизация процессов</h3><p>Интеграции с CRM и 1С, складской учёт, отчётность и дашборды вместо ручных таблиц.</p></article>
    </div>
    <p class="center after-grid"><a href="/services.html">Все услуги и цены <svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-arrow"/></svg></a></p>
  </div>
</section>

<section class="section alt">
  <div class="wrap">
    <div class="section-head"><h2>Как мы работаем</h2><p>Понятный процесс без сюрпризов: вы всегда знаете, что происходит с проектом.</p></div>
    <ol class="steps">
      <li><h3>Бриф и аналитика</h3><p>Разбираем задачу, аудиторию и метрики успеха, фиксируем требования.</p></li>
      <li><h3>Прототип и дизайн</h3><p>Согласуем структуру и интерфейс на кликабельном прототипе.</p></li>
      <li><h3>Разработка</h3><p>Короткие итерации, демо раз в две недели, доступ к тестовому стенду.</p></li>
      <li><h3>Запуск и поддержка</h3><p>Выкатываем, обучаем команду и сопровождаем по SLA.</p></li>
    </ol>
  </div>
</section>

<section class="section">
  <div class="wrap">
    <div class="section-head"><h2>Что говорят клиенты</h2><p>Несколько отзывов о совместной работе.</p></div>
    <div class="slider" data-slider tabindex="0" aria-roledescription="карусель" aria-label="Отзывы клиентов">
      <div class="viewport"><div class="track">
        <figure class="slide"><div class="stars" aria-label="5 из 5">★★★★★</div><blockquote>«Запустили интернет-магазин за два месяца, как и обещали. Конверсия выросла на треть, а менеджеры наконец перестали вести заказы в таблицах.»</blockquote><figcaption><span class="avatar">АК</span><span><b>Алексей Коваленко</b><br>директор, «Маркет-Лайн»</span></figcaption></figure>
        <figure class="slide"><div class="stars" aria-label="5 из 5">★★★★★</div><blockquote>«Команда глубоко вникла в наш процесс и предложила решения, о которых мы сами не думали. Приложением для курьеров пользуются каждый день.»</blockquote><figcaption><span class="avatar a2">МС</span><span><b>Мария Сидорова</b><br>руководитель логистики, «КурьерGo»</span></figcaption></figure>
        <figure class="slide"><div class="stars" aria-label="5 из 5">★★★★★</div><blockquote>«Интеграция с CRM и 1С сэкономила нам десятки часов в месяц. Отдельное спасибо за документацию и спокойную передачу проекта.»</blockquote><figcaption><span class="avatar">ДП</span><span><b>Дмитрий Павлов</b><br>коммерческий директор, «ЛогиСтар»</span></figcaption></figure>
        <figure class="slide"><div class="stars" aria-label="5 из 5">★★★★★</div><blockquote>«Онлайн-запись разгрузила регистратуру, а пациенты хвалят личный кабинет. Поддержка отвечает быстро и по делу.»</blockquote><figcaption><span class="avatar a2">ЕВ</span><span><b>Елена Воронцова</b><br>главный врач, «Клиника Север»</span></figcaption></figure>
      </div></div>
      <div class="slider-ctl">
        <button class="icon-btn" type="button" data-prev aria-label="Предыдущий отзыв"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-left"/></svg></button>
        <div class="dots"></div>
        <button class="icon-btn" type="button" data-next aria-label="Следующий отзыв"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-right"/></svg></button>
      </div>
    </div>
  </div>
</section>

<section class="section">
  <div class="wrap">
    <div class="cta-band">
      <div><h2>Есть задача? Расскажите о ней</h2><p>Ответим в течение рабочего дня и предложим формат работы.</p></div>
      <a class="btn" href="/contacts.html">Оставить заявку</a>
    </div>
  </div>
</section>
<script type="application/ld+json">{"@context":"https://schema.org","@type":"Organization","name":"__BRAND__","url":"https://__DOMAIN__/","email":"hello@__DOMAIN__","telephone":"+7 495 555-01-24"}</script>
DECOY_INDEX_EOF

    _decoy_page "$r/services.html" \
        "Услуги и цены — __BRAND__" \
        "Разработка сайтов, мобильных приложений и автоматизация бизнес-процессов. Онлайн-калькулятор стоимости и ответы на частые вопросы." \
        "services.html" <<'DECOY_SERVICES_EOF'
<section class="page-head">
  <div class="wrap"><div class="crumbs"><a href="/">Главная</a> / Услуги</div><h1>Услуги и стоимость</h1><p class="lead">Подберите формат сотрудничества: от разового проекта до долгосрочной команды разработки.</p></div>
</section>

<section class="section">
  <div class="wrap">
    <div class="grid g2">
      <article class="card"><span class="badge"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-web"/></svg></span><h3>Сайты и интернет-магазины</h3><p>Лендинги, корпоративные сайты, каталоги и магазины с интеграцией оплаты и доставки. Адаптивная вёрстка, SEO-основа, удобная админка. <b>От 60 000 ₽.</b></p></article>
      <article class="card"><span class="badge"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-mobile"/></svg></span><h3>Мобильные приложения</h3><p>Нативные и кроссплатформенные приложения для iOS и Android, push-уведомления, офлайн-режим, публикация в App Store и Google Play. <b>От 320 000 ₽.</b></p></article>
      <article class="card"><span class="badge"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-auto"/></svg></span><h3>Внутренние сервисы и автоматизация</h3><p>CRM, складской учёт, личные кабинеты, интеграции с 1С и маркетплейсами, дашборды и автоматическая отчётность. <b>От 280 000 ₽.</b></p></article>
      <article class="card"><span class="badge"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-design"/></svg></span><h3>UX/UI-дизайн</h3><p>Исследование аудитории, прототипы, дизайн-системы и фирменный стиль интерфейсов. Согласуем на кликабельном макете до разработки. <b>От 45 000 ₽.</b></p></article>
      <article class="card"><span class="badge"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-support"/></svg></span><h3>Поддержка и развитие</h3><p>Мониторинг, обновления, резервные копии, доработки по SLA. Выделенная команда или почасовая поддержка. <b>От 45 000 ₽/мес.</b></p></article>
      <article class="card"><span class="badge"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-shield"/></svg></span><h3>Аудит и безопасность</h3><p>Технический аудит кода и инфраструктуры, проверка уязвимостей, оптимизация скорости загрузки и отказоустойчивости. <b>От 35 000 ₽.</b></p></article>
    </div>
  </div>
</section>

<section class="section alt" id="calc">
  <div class="wrap">
    <div class="section-head"><h2>Калькулятор стоимости</h2><p>Ориентировочная оценка за минуту. Точную смету подготовим после короткого брифа.</p></div>
    <div class="calc" data-calc>
      <div class="card">
        <div class="field"><label for="c-type">Тип проекта</label>
          <select id="c-type" name="type"><option value="landing">Лендинг</option><option value="site" selected>Корпоративный сайт</option><option value="shop">Интернет-магазин</option><option value="mobile">Мобильное приложение</option><option value="internal">Внутренний сервис</option></select></div>
        <div class="field"><div class="range-line"><label for="c-units">Объём: <span id="calc-units">8</span> <span id="calc-unit-label">страниц</span></label></div>
          <input id="c-units" name="units" type="range" min="1" max="30" value="8"></div>
        <div class="opts">
          <label class="opt"><input type="checkbox" name="design" checked> Индивидуальный дизайн <small>+18%</small></label>
          <label class="opt"><input type="checkbox" name="integr"> Интеграции (CRM, 1С, оплата) <small>+70 000 ₽</small></label>
          <label class="opt"><input type="checkbox" name="support"> Поддержка 3 месяца <small>+45 000 ₽</small></label>
          <label class="opt"><input type="checkbox" name="urgent"> Срочный запуск <small>+30%</small></label>
        </div>
      </div>
      <aside class="calc-out" aria-live="polite">
        <small>Ориентировочная стоимость</small>
        <div class="calc-sum" id="calc-sum">—</div>
        <small>Срок разработки</small>
        <div class="calc-sum" id="calc-weeks">—</div>
        <a class="btn" href="/contacts.html" data-calc-go>Получить точную смету</a>
      </aside>
    </div>
  </div>
</section>

<section class="section">
  <div class="wrap">
    <div class="section-head"><h2>Частые вопросы</h2></div>
    <div class="faq">
      <div class="faq-item"><button class="faq-q" type="button" aria-expanded="false" aria-controls="fa1"><span>Как фиксируется стоимость проекта?</span><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-plus"/></svg></button><div class="faq-a" id="fa1"><p>После брифа мы готовим смету с разбивкой по этапам. Для проектов с понятным объёмом работаем по фиксированной цене, для развивающихся продуктов — по спринтам с ежемесячным лимитом.</p></div></div>
      <div class="faq-item"><button class="faq-q" type="button" aria-expanded="false" aria-controls="fa2"><span>Сколько времени занимает разработка?</span><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-plus"/></svg></button><div class="faq-a" id="fa2"><p>Лендинг — от двух недель, корпоративный сайт — 4–6 недель, интернет-магазин или приложение — от двух месяцев. Конкретные сроки фиксируем в договоре.</p></div></div>
      <div class="faq-item"><button class="faq-q" type="button" aria-expanded="false" aria-controls="fa3"><span>Кому принадлежат исходные коды?</span><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-plus"/></svg></button><div class="faq-a" id="fa3"><p>Все исключительные права на разработанный продукт переходят заказчику после оплаты. Мы передаём исходники, доступы и документацию.</p></div></div>
      <div class="faq-item"><button class="faq-q" type="button" aria-expanded="false" aria-controls="fa4"><span>Вы поддерживаете проекты после запуска?</span><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-plus"/></svg></button><div class="faq-a" id="fa4"><p>Да. Есть тарифы поддержки с мониторингом, обновлениями безопасности и гарантированным временем реакции. Первые 30 дней после запуска исправляем ошибки бесплатно.</p></div></div>
      <div class="faq-item"><button class="faq-q" type="button" aria-expanded="false" aria-controls="fa5"><span>Можно ли начать с небольшого пилота?</span><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-plus"/></svg></button><div class="faq-a" id="fa5"><p>Конечно. Часто мы начинаем с аудита или прототипа за 1–2 недели, чтобы проверить гипотезу и только потом переходить к полной разработке.</p></div></div>
    </div>
  </div>
</section>
DECOY_SERVICES_EOF

    _decoy_page "$r/portfolio.html" \
        "Проекты и кейсы — __BRAND__" \
        "Избранные проекты студии «__BRAND__»: интернет-магазины, мобильные приложения и системы автоматизации. Фильтр по направлению и поиск." \
        "portfolio.html" <<'DECOY_PORTFOLIO_EOF'
<section class="page-head">
  <div class="wrap"><div class="crumbs"><a href="/">Главная</a> / Проекты</div><h1>Проекты и кейсы</h1><p class="lead">Избранные работы последних лет. Отфильтруйте по направлению или найдите проект по названию и технологии.</p></div>
</section>

<section class="section" data-filter-root>
  <div class="wrap">
    <div class="toolbar">
      <div class="chips" role="group" aria-label="Направление">
        <button class="chip" type="button" data-chip="all" aria-pressed="true">Все</button>
        <button class="chip" type="button" data-chip="web" aria-pressed="false">Сайты</button>
        <button class="chip" type="button" data-chip="mobile" aria-pressed="false">Мобильные</button>
        <button class="chip" type="button" data-chip="auto" aria-pressed="false">Автоматизация</button>
      </div>
      <div class="search"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-search"/></svg><input type="search" data-search placeholder="Поиск по проектам" aria-label="Поиск по проектам"></div>
    </div>
    <div class="grid g3">
      <article class="card" data-item data-cat="web" data-grad="g-1" data-title="Маркет-Лайн — интернет-магазин запчастей" data-client="«Маркет-Лайн», B2B-торговля" data-term="9 недель" data-stack="Vue, Node.js, PostgreSQL" data-text="Каталог на 40 000 позиций, личный кабинет дилера, расчёт индивидуальных цен и выгрузка заказов в 1С. Конверсия в заказ выросла на 34%.">
        <div class="thumb g-1"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-web"/></svg></div>
        <div class="meta"><span class="tag">Сайт</span><span>2025</span></div>
        <h3>Маркет-Лайн</h3><p>Интернет-магазин автозапчастей с кабинетом дилера и интеграцией с 1С.</p>
        <button class="more" type="button" data-open>Подробнее <svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-arrow"/></svg></button>
      </article>
      <article class="card" data-item data-cat="mobile" data-grad="g-2" data-title="ФитТрек — приложение для тренировок" data-client="«ФитТрек», фитнес-сервис" data-term="14 недель" data-stack="React Native, Firebase" data-text="Планы тренировок, трекер прогресса, push-напоминания и интеграция с умными часами. Более 90 000 установок за первый год.">
        <div class="thumb g-2"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-mobile"/></svg></div>
        <div class="meta"><span class="tag">Мобильное</span><span>2024</span></div>
        <h3>ФитТрек</h3><p>Мобильное приложение для персональных тренировок и контроля прогресса.</p>
        <button class="more" type="button" data-open>Подробнее <svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-arrow"/></svg></button>
      </article>
      <article class="card" data-item data-cat="auto" data-grad="g-3" data-title="ЛогиСтар — складской учёт" data-client="«ЛогиСтар», логистическая компания" data-term="12 недель" data-stack="Python, Django, Redis, Docker" data-text="Учёт остатков в реальном времени, маршрутизация сборки, сканирование штрихкодов с ТСД и отчёты для руководства. Время сборки заказа сократилось на 27%.">
        <div class="thumb g-3"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-auto"/></svg></div>
        <div class="meta"><span class="tag">Автоматизация</span><span>2025</span></div>
        <h3>ЛогиСтар</h3><p>Система складского учёта и маршрутизации сборки заказов.</p>
        <button class="more" type="button" data-open>Подробнее <svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-arrow"/></svg></button>
      </article>
      <article class="card" data-item data-cat="web" data-grad="g-4" data-title="Клиника Север — онлайн-запись" data-client="«Клиника Север», медицинский центр" data-term="8 недель" data-stack="Next.js, NestJS, PostgreSQL" data-text="Онлайн-запись к врачам, личный кабинет пациента, напоминания по SMS и e-mail, интеграция с медицинской информационной системой.">
        <div class="thumb g-4"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-shield"/></svg></div>
        <div class="meta"><span class="tag">Сайт</span><span>2024</span></div>
        <h3>Клиника Север</h3><p>Сайт медцентра с онлайн-записью и личным кабинетом пациента.</p>
        <button class="more" type="button" data-open>Подробнее <svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-arrow"/></svg></button>
      </article>
      <article class="card" data-item data-cat="mobile" data-grad="g-5" data-title="КурьерGo — приложение для курьеров" data-client="«КурьерGo», служба доставки" data-term="11 недель" data-stack="Kotlin, Swift, Go" data-text="Распределение заказов, построение маршрутов, фотофиксация доставки и расчёт вознаграждения. Приложение работает офлайн при слабой связи.">
        <div class="thumb g-5"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-rocket"/></svg></div>
        <div class="meta"><span class="tag">Мобильное</span><span>2025</span></div>
        <h3>КурьерGo</h3><p>Приложение для курьеров с маршрутами, статусами и расчётом оплаты.</p>
        <button class="more" type="button" data-open>Подробнее <svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-arrow"/></svg></button>
      </article>
      <article class="card" data-item data-cat="auto" data-grad="g-6" data-title="Аналитика Про — дашборды и CRM" data-client="«Аналитика Про», маркетинговое агентство" data-term="6 недель" data-stack="ClickHouse, Grafana, Python" data-text="Единые дашборды по рекламным кампаниям, автоматическая сборка отчётов из CRM и рекламных кабинетов, оповещения об аномалиях.">
        <div class="thumb g-6"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-chart"/></svg></div>
        <div class="meta"><span class="tag">Автоматизация</span><span>2024</span></div>
        <h3>Аналитика Про</h3><p>Сквозная аналитика, дашборды и автоматические отчёты для агентства.</p>
        <button class="more" type="button" data-open>Подробнее <svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-arrow"/></svg></button>
      </article>
    </div>
    <div class="empty" data-empty><h3>Ничего не найдено</h3><p>Попробуйте изменить запрос или выбрать другое направление.</p></div>
  </div>
</section>

<dialog id="project-dialog" aria-labelledby="dlg-title">
  <button class="icon-btn dlg-close" type="button" data-close aria-label="Закрыть"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-close"/></svg></button>
  <div class="dlg-body">
    <div class="thumb g-1" id="dlg-thumb"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-code"/></svg></div>
    <h2 id="dlg-title"></h2>
    <p id="dlg-text" class="muted"></p>
    <dl><dt>Клиент</dt><dd id="dlg-client"></dd><dt>Срок</dt><dd id="dlg-term"></dd><dt>Стек</dt><dd id="dlg-stack"></dd></dl>
    <p class="dlg-cta"><a class="btn" href="/contacts.html">Обсудить похожий проект</a></p>
  </div>
</dialog>
DECOY_PORTFOLIO_EOF

    _decoy_page "$r/about.html" \
        "О компании — __BRAND__" \
        "Студия «__BRAND__» с 2014 года создаёт цифровые продукты для бизнеса. Наша команда, ценности и история компании." \
        "about.html" <<'DECOY_ABOUT_EOF'
<section class="page-head">
  <div class="wrap"><div class="crumbs"><a href="/">Главная</a> / О компании</div><h1>О компании</h1><p class="lead">«__BRAND__» — независимая студия разработки. Мы делаем продукты, за которые не стыдно, и сопровождаем их годами.</p></div>
</section>

<section class="section">
  <div class="wrap split">
    <div>
      <h2>Небольшая команда с большим опытом</h2>
      <p>Студия основана в 2014 году группой разработчиков и дизайнеров, которым надоели бесконечные согласования и размытые сметы. Сегодня в команде 38 специалистов: аналитики, дизайнеры, разработчики, тестировщики и менеджеры проектов.</p>
      <p>Мы работаем с компаниями из ритейла, логистики, медицины и сферы услуг — от стартапов до федеральных сетей. Для каждого проекта собираем небольшую выделенную команду, чтобы все отвечали за результат лично.</p>
      <ul class="checklist">
        <li><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-check"/></svg>Фиксируем смету и сроки в договоре</li>
        <li><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-check"/></svg>Показываем промежуточные результаты каждые две недели</li>
        <li><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-check"/></svg>Передаём исходники и документацию без привязки к нам</li>
      </ul>
    </div>
    <ol class="timeline">
      <li><b>2014</b>Основание студии, первые проекты для малого бизнеса.</li>
      <li><b>2017</b>Запуск направления мобильной разработки.</li>
      <li><b>2020</b>Переход на полностью удалённый формат и найм по всей стране.</li>
      <li><b>2023</b>Собственная команда автоматизации и аналитики данных.</li>
      <li><b>2025</b>Более 240 завершённых проектов и 97% повторных обращений.</li>
    </ol>
  </div>
</section>

<section class="section alt">
  <div class="wrap">
    <div class="section-head"><h2>Наши ценности</h2></div>
    <div class="grid g3">
      <article class="card"><span class="badge"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-shield"/></svg></span><h3>Честность</h3><p>Говорим о рисках сразу и не обещаем невозможного. Если задачу выгоднее решить проще, так и скажем.</p></article>
      <article class="card"><span class="badge"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-code"/></svg></span><h3>Качество</h3><p>Код-ревью, автотесты и мониторинг в каждом проекте. Мы не выпускаем то, чем не стали бы пользоваться сами.</p></article>
      <article class="card"><span class="badge"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-support"/></svg></span><h3>Партнёрство</h3><p>Остаёмся рядом после запуска и помогаем развивать продукт вместе с бизнесом клиента.</p></article>
    </div>
  </div>
</section>

<section class="section">
  <div class="wrap team">
    <div class="section-head"><h2>Команда</h2><p>Люди, которые будут работать над вашим проектом.</p></div>
    <div class="grid g4">
      <article class="card"><span class="avatar">ИР</span><h3>Игорь Романов</h3><p>Основатель, технический директор</p></article>
      <article class="card"><span class="avatar a2">НЛ</span><h3>Наталья Лебедева</h3><p>Руководитель проектов</p></article>
      <article class="card"><span class="avatar">ТМ</span><h3>Тимур Мартынов</h3><p>Ведущий разработчик</p></article>
      <article class="card"><span class="avatar a2">ОБ</span><h3>Ольга Белова</h3><p>Арт-директор, UX/UI</p></article>
    </div>
  </div>
</section>
DECOY_ABOUT_EOF

    _decoy_page "$r/contacts.html" \
        "Контакты — __BRAND__" \
        "Свяжитесь со студией «__BRAND__»: форма обратной связи, телефон, e-mail и адрес офиса. Ответим в течение рабочего дня." \
        "contacts.html" <<'DECOY_CONTACTS_EOF'
<section class="page-head">
  <div class="wrap"><div class="crumbs"><a href="/">Главная</a> / Контакты</div><h1>Контакты</h1><p class="lead">Расскажите о задаче — мы ответим в течение рабочего дня и предложим формат работы.</p></div>
</section>

<section class="section">
  <div class="wrap contact-grid">
    <div class="card">
      <h2>Написать нам</h2>
      <div class="notice" id="form-ok" role="status"><b>Спасибо! Заявка отправлена.</b><br>Менеджер свяжется с вами в ближайшее рабочее время.</div>
      <form id="contact-form" novalidate>
        <div class="row2">
          <div class="field"><label for="f-name">Имя</label><input id="f-name" name="name" type="text" autocomplete="name" placeholder="Как к вам обращаться"><div class="err" role="alert"></div></div>
          <div class="field"><label for="f-email">E-mail</label><input id="f-email" name="email" type="email" autocomplete="email" placeholder="name@company.ru"><div class="err" role="alert"></div></div>
        </div>
        <div class="row2">
          <div class="field"><label for="f-phone">Телефон <span class="muted">(необязательно)</span></label><input id="f-phone" name="phone" type="tel" autocomplete="tel" inputmode="tel" placeholder="+7 (900) 000-00-00"><div class="err" role="alert"></div></div>
          <div class="field"><label for="f-topic">Тема</label><select id="f-topic" name="topic"><option value="">Выберите…</option><option>Сайт или интернет-магазин</option><option>Мобильное приложение</option><option>Автоматизация процессов</option><option>Поддержка проекта</option><option>Другое</option></select><div class="err" role="alert"></div></div>
        </div>
        <div class="field"><label for="f-message">Сообщение <span class="counter" id="msg-count">0 / 500</span></label><textarea id="f-message" name="message" placeholder="Коротко опишите задачу, сроки и бюджет"></textarea><div class="err" role="alert"></div></div>
        <div class="hp" aria-hidden="true"><label>Не заполняйте это поле <input type="text" name="website" tabindex="-1" autocomplete="off"></label></div>
        <div class="field"><label class="check"><input type="checkbox" name="agree"><span>Согласен на обработку персональных данных в соответствии с <a href="/privacy.html">политикой конфиденциальности</a></span></label><div class="err" role="alert"></div></div>
        <button class="btn" type="submit">Отправить заявку</button>
      </form>
    </div>
    <aside class="card">
      <h3>Как нас найти</h3>
      <ul class="info-list">
        <li><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-pin"/></svg><span><b>Адрес</b>Москва, ул. Тверская, д. 18, офис 405</span></li>
        <li><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-phone"/></svg><span><b>Телефон</b><a href="tel:+74955550124">+7 (495) 555-01-24</a></span></li>
        <li><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-mail"/></svg><span><b>E-mail</b><a href="mailto:hello@__DOMAIN__">hello@__DOMAIN__</a></span></li>
        <li><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-clock"/></svg><span><b>Режим работы</b>Пн–Пт, 10:00–19:00 (МСК)</span></li>
      </ul>
      <svg class="map" viewBox="0 0 400 220" role="img" aria-label="Схема проезда">
        <rect class="bg" width="400" height="220"/>
        <rect class="bl" x="20" y="20" width="90" height="60" rx="6"/><rect class="bl" x="140" y="20" width="110" height="60" rx="6"/><rect class="bl" x="280" y="20" width="100" height="60" rx="6"/>
        <rect class="bl" x="20" y="130" width="130" height="70" rx="6"/><rect class="bl" x="200" y="130" width="70" height="70" rx="6"/><rect class="bl" x="300" y="130" width="80" height="70" rx="6"/>
        <path class="rd" d="M0 105H400"/><path class="rd2" d="M125 0V220M265 0V220"/><path class="rd2" d="M0 100L400 112"/>
        <path class="pin" d="M200 118c-10-14-16-22-16-32a16 16 0 0 1 32 0c0 10-6 18-16 32z"/><circle cx="200" cy="86" r="6" fill="#fff"/>
      </svg>
    </aside>
  </div>
</section>
DECOY_CONTACTS_EOF

    _decoy_page "$r/privacy.html" \
        "Политика конфиденциальности — __BRAND__" \
        "Политика обработки персональных данных на сайте __DOMAIN__." \
        "privacy.html" <<'DECOY_PRIVACY_EOF'
<section class="page-head">
  <div class="wrap"><div class="crumbs"><a href="/">Главная</a> / Конфиденциальность</div><h1>Политика конфиденциальности</h1></div>
</section>
<article class="article">
  <p>Настоящая политика описывает, как студия «__BRAND__» обрабатывает персональные данные посетителей сайта __DOMAIN__.</p>
  <h2>1. Какие данные мы обрабатываем</h2>
  <p>Мы обрабатываем только те данные, которые вы указываете в форме обратной связи: имя, адрес электронной почты, телефон и текст сообщения. Сайт не использует сторонние системы аналитики и рекламные трекеры.</p>
  <h2>2. Цели обработки</h2>
  <p>Данные используются для ответа на ваше обращение, подготовки коммерческого предложения и связи по вопросам сотрудничества. Мы не передаём данные третьим лицам, за исключением случаев, предусмотренных законом.</p>
  <h2>3. Cookie и локальное хранилище</h2>
  <p>Сайт сохраняет в вашем браузере только технические настройки: выбранную тему оформления и отметку о принятии уведомления о cookie. Эти данные не покидают ваше устройство.</p>
  <h2>4. Срок хранения и ваши права</h2>
  <p>Данные из обращений хранятся не дольше 12 месяцев. Вы можете запросить уточнение, блокировку или удаление своих данных, написав на <a href="mailto:hello@__DOMAIN__">hello@__DOMAIN__</a>.</p>
  <h2>5. Изменения политики</h2>
  <p>Актуальная версия политики всегда доступна на этой странице. Последнее обновление: __DATE_RU__.</p>
</article>
DECOY_PRIVACY_EOF

    _decoy_page "$r/404.html" \
        "Страница не найдена — __BRAND__" \
        "Запрошенная страница не найдена." \
        "404.html" "noindex,nofollow" <<'DECOY_404_EOF'
<section class="nf">
  <div class="wrap">
    <div class="code">404</div>
    <h1>Страница не найдена</h1>
    <p class="lead lead-c">Возможно, ссылка устарела или в адресе опечатка. Вернитесь на главную или выберите нужный раздел.</p>
    <div class="nf-links">
      <a class="btn" href="/">На главную</a>
      <a class="btn ghost" href="/services.html">Услуги</a>
      <a class="btn ghost" href="/portfolio.html">Проекты</a>
      <a class="btn ghost" href="/blog.html">Блог</a>
      <a class="btn ghost" href="/contacts.html">Контакты</a>
    </div>
  </div>
</section>
DECOY_404_EOF
}

_decoy_write_pages_blog() {
    local r="$1"

    _decoy_page "$r/blog.html" \
        "Блог — __BRAND__" \
        "Статьи о разработке сайтов, мобильных приложениях и автоматизации бизнеса от команды «__BRAND__»." \
        "blog.html" <<'DECOY_BLOG_EOF'
<section class="page-head">
  <div class="wrap"><div class="crumbs"><a href="/">Главная</a> / Блог</div><h1>Блог</h1><p class="lead">Практические материалы о разработке, дизайне и автоматизации для владельцев бизнеса и руководителей проектов.</p></div>
</section>

<section class="section" data-filter-root>
  <div class="wrap">
    <div class="toolbar">
      <div class="chips" role="group" aria-label="Рубрики">
        <button class="chip" type="button" data-chip="all" aria-pressed="true">Все</button>
        <button class="chip" type="button" data-chip="dev" aria-pressed="false">Разработка</button>
        <button class="chip" type="button" data-chip="mobile" aria-pressed="false">Мобильные</button>
        <button class="chip" type="button" data-chip="auto" aria-pressed="false">Автоматизация</button>
      </div>
      <div class="search"><svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-search"/></svg><input type="search" data-search placeholder="Поиск по статьям" aria-label="Поиск по статьям"></div>
    </div>
    <div class="grid g2">
      <article class="card" data-item data-cat="dev">
        <div class="meta"><span class="tag">Разработка</span><time datetime="2026-02-12">12 февраля 2026</time><span>7 мин</span></div>
        <h3><a href="/blog/skolko-stoit-sait.html">Сколько стоит сайт для бизнеса: из чего складывается бюджет</a></h3>
        <p>Разбираем, за что вы платите при заказе сайта, и как сэкономить, не потеряв в качестве.</p>
        <a class="more" href="/blog/skolko-stoit-sait.html">Читать <svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-arrow"/></svg></a>
      </article>
      <article class="card" data-item data-cat="mobile">
        <div class="meta"><span class="tag">Мобильные</span><time datetime="2026-01-20">20 января 2026</time><span>6 мин</span></div>
        <h3><a href="/blog/nativnoe-ili-krossplatformennoe.html">Нативное или кроссплатформенное приложение: как выбрать</a></h3>
        <p>Сравниваем подходы по стоимости, скорости разработки и пользовательскому опыту.</p>
        <a class="more" href="/blog/nativnoe-ili-krossplatformennoe.html">Читать <svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-arrow"/></svg></a>
      </article>
      <article class="card" data-item data-cat="auto">
        <div class="meta"><span class="tag">Автоматизация</span><time datetime="2025-12-04">4 декабря 2025</time><span>5 мин</span></div>
        <h3><a href="/blog/pyat-processov-dlya-avtomatizatsii.html">Пять процессов, которые стоит автоматизировать в первую очередь</a></h3>
        <p>Где автоматизация окупается быстрее всего: от обработки заявок до сверки платежей.</p>
        <a class="more" href="/blog/pyat-processov-dlya-avtomatizatsii.html">Читать <svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-arrow"/></svg></a>
      </article>
      <article class="card" data-item data-cat="dev">
        <div class="meta"><span class="tag">Разработка</span><time datetime="2025-10-15">15 октября 2025</time><span>4 мин</span></div>
        <h3><a href="/blog/chek-list-zapuska-sayta.html">Чек-лист запуска сайта: что проверить перед релизом</a></h3>
        <p>Двадцать пунктов, которые помогут не потерять трафик и заявки в первые недели после запуска.</p>
        <a class="more" href="/blog/chek-list-zapuska-sayta.html">Читать <svg class="ic" aria-hidden="true"><use href="/assets/icons.svg#i-arrow"/></svg></a>
      </article>
    </div>
    <div class="empty" data-empty><h3>Статьи не найдены</h3><p>Измените запрос или выберите другую рубрику.</p></div>
  </div>
</section>
DECOY_BLOG_EOF

    _decoy_page "$r/blog/skolko-stoit-sait.html" \
        "Сколько стоит сайт для бизнеса — блог __BRAND__" \
        "Из чего складывается стоимость разработки сайта: дизайн, вёрстка, функциональность, контент и поддержка." \
        "blog/skolko-stoit-sait.html" <<'DECOY_POST1_EOF'
<article class="article">
  <div class="crumbs"><a href="/">Главная</a> / <a href="/blog.html">Блог</a></div>
  <h1>Сколько стоит сайт для бизнеса: из чего складывается бюджет</h1>
  <div class="meta"><span class="tag">Разработка</span><time datetime="2026-02-12">12 февраля 2026</time><span>7 мин</span></div>
  <p>Вопрос о стоимости сайта почти всегда звучит как «сколько стоит сайт?», хотя правильнее спрашивать «какую задачу он должен решать». Диапазон цен огромен: от нескольких десятков тысяч рублей за лендинг до миллионов за сложный портал. Разберём, из чего складывается бюджет.</p>
  <h2>Аналитика и структура</h2>
  <p>До первого макета нужно понять, кто ваши клиенты, какие сценарии они проходят и какие страницы действительно необходимы. Хорошая аналитика экономит время на всех следующих этапах: меньше правок, меньше «давайте переделаем».</p>
  <h2>Дизайн</h2>
  <p>Индивидуальный дизайн обычно составляет 20–30% бюджета. Он оправдан, если сайт — основной канал продаж или важная часть бренда. Для небольших проектов можно взять готовую дизайн-систему и адаптировать под фирменный стиль.</p>
  <h2>Разработка и функциональность</h2>
  <p>Основная часть затрат — это логика: каталог, корзина, личный кабинет, интеграции с оплатой, CRM и учётными системами. Каждая интеграция добавляет время на проектирование, тестирование и обработку ошибочных ситуаций.</p>
  <h2>Контент и SEO</h2>
  <p>Тексты, фотографии и настройка метаданных часто недооценивают. Заложите время на наполнение: пустой сайт не продаёт, как бы красиво он ни выглядел.</p>
  <h2>Поддержка</h2>
  <p>Сайт — живой продукт. Обновления безопасности, резервные копии и мелкие доработки лучше планировать сразу: обычно это 10–15% от стоимости разработки в год.</p>
  <p>Если хотите быстро прикинуть порядок цифр, воспользуйтесь <a href="/services.html#calc">калькулятором на странице услуг</a>.</p>
  <div class="article-nav"><a href="/blog.html">← Все статьи</a><a href="/blog/chek-list-zapuska-sayta.html">Чек-лист запуска сайта →</a></div>
</article>
DECOY_POST1_EOF

    _decoy_page "$r/blog/nativnoe-ili-krossplatformennoe.html" \
        "Нативное или кроссплатформенное приложение — блог __BRAND__" \
        "Сравнение нативной и кроссплатформенной мобильной разработки по цене, срокам и качеству пользовательского опыта." \
        "blog/nativnoe-ili-krossplatformennoe.html" <<'DECOY_POST2_EOF'
<article class="article">
  <div class="crumbs"><a href="/">Главная</a> / <a href="/blog.html">Блог</a></div>
  <h1>Нативное или кроссплатформенное приложение: как выбрать</h1>
  <div class="meta"><span class="tag">Мобильные</span><time datetime="2026-01-20">20 января 2026</time><span>6 мин</span></div>
  <p>Перед запуском мобильного продукта каждая команда сталкивается с выбором: писать отдельные приложения под iOS и Android или использовать один код для обеих платформ. Универсального ответа нет, но есть понятные критерии.</p>
  <h2>Когда подойдёт кроссплатформа</h2>
  <p>Если нужно быстро проверить гипотезу, бюджет ограничен, а интерфейс стандартный — списки, формы, карточки, — Flutter или React Native сэкономят до 40% стоимости. Одна команда, один релизный цикл, единая логика.</p>
  <h2>Когда нужен нативный подход</h2>
  <p>Тяжёлая графика, глубокая интеграция с датчиками и системными сервисами, сложные анимации и жёсткие требования к производительности — повод выбрать Swift и Kotlin. Нативные приложения быстрее получают поддержку новых функций операционных систем.</p>
  <h2>Что учесть дополнительно</h2>
  <p>Оцените состав своей команды, планы по развитию продукта и требования к публикации в магазинах. Иногда разумнее начать с кроссплатформенного MVP и переписать критичные экраны нативно, когда продукт докажет свою ценность.</p>
  <div class="article-nav"><a href="/blog.html">← Все статьи</a><a href="/blog/pyat-processov-dlya-avtomatizatsii.html">Пять процессов для автоматизации →</a></div>
</article>
DECOY_POST2_EOF

    _decoy_page "$r/blog/pyat-processov-dlya-avtomatizatsii.html" \
        "Пять процессов для автоматизации — блог __BRAND__" \
        "С каких бизнес-процессов начать автоматизацию, чтобы получить быстрый и измеримый эффект." \
        "blog/pyat-processov-dlya-avtomatizatsii.html" <<'DECOY_POST3_EOF'
<article class="article">
  <div class="crumbs"><a href="/">Главная</a> / <a href="/blog.html">Блог</a></div>
  <h1>Пять процессов, которые стоит автоматизировать в первую очередь</h1>
  <div class="meta"><span class="tag">Автоматизация</span><time datetime="2025-12-04">4 декабря 2025</time><span>5 мин</span></div>
  <p>Автоматизация не обязана быть масштабным проектом на год. Часто достаточно убрать несколько рутинных операций, чтобы команда освободила десятки часов в месяц. Вот с чего мы рекомендуем начинать.</p>
  <h2>1. Обработка входящих заявок</h2>
  <p>Заявки с сайта, почты и мессенджеров должны попадать в единую CRM, а менеджер получать уведомление с контекстом клиента. Это сокращает время реакции и убирает потерянные обращения.</p>
  <h2>2. Выставление счетов и документов</h2>
  <p>Шаблоны договоров, счетов и актов, которые формируются по данным сделки, исключают ошибки и экономят время бухгалтерии.</p>
  <h2>3. Сверка платежей</h2>
  <p>Автоматическое сопоставление оплат с заказами по выпискам банка избавляет от ежедневной ручной проверки.</p>
  <h2>4. Складские остатки</h2>
  <p>Единый источник правды по остаткам и автоматическая выгрузка на маркетплейсы предотвращают продажи товара, которого уже нет.</p>
  <h2>5. Регулярная отчётность</h2>
  <p>Дашборды, обновляемые из учётных систем, заменяют еженедельные выгрузки в таблицы и позволяют принимать решения по актуальным данным.</p>
  <div class="article-nav"><a href="/blog.html">← Все статьи</a><a href="/contacts.html">Обсудить автоматизацию →</a></div>
</article>
DECOY_POST3_EOF

    _decoy_page "$r/blog/chek-list-zapuska-sayta.html" \
        "Чек-лист запуска сайта — блог __BRAND__" \
        "Что проверить перед запуском сайта: редиректы, метаданные, скорость, формы, безопасность и резервные копии." \
        "blog/chek-list-zapuska-sayta.html" <<'DECOY_POST4_EOF'
<article class="article">
  <div class="crumbs"><a href="/">Главная</a> / <a href="/blog.html">Блог</a></div>
  <h1>Чек-лист запуска сайта: что проверить перед релизом</h1>
  <div class="meta"><span class="tag">Разработка</span><time datetime="2025-10-15">15 октября 2025</time><span>4 мин</span></div>
  <p>Запуск сайта — момент, когда мелкие недочёты становятся заметными для всех. Мы используем короткий чек-лист, который помогает не потерять трафик и заявки.</p>
  <h2>Содержимое и SEO</h2>
  <ul>
    <li>У каждой страницы есть уникальные заголовок и описание.</li>
    <li>Настроены 301-редиректы со старых адресов.</li>
    <li>Созданы файлы robots.txt и sitemap.xml, указан канонический адрес.</li>
    <li>Для страницы 404 подготовлен понятный экран с навигацией.</li>
  </ul>
  <h2>Технические проверки</h2>
  <ul>
    <li>Сертификат HTTPS действителен, HTTP перенаправляется на HTTPS.</li>
    <li>Страницы быстро открываются на мобильных устройствах, изображения оптимизированы.</li>
    <li>Включены сжатие и кэширование статики.</li>
    <li>Настроены резервные копии и мониторинг доступности.</li>
  </ul>
  <h2>Формы и сценарии</h2>
  <ul>
    <li>Формы проверяют корректность данных и показывают понятные ошибки.</li>
    <li>Заявки приходят ответственному сотруднику и дублируются в CRM.</li>
    <li>Основные сценарии пройдены вручную на разных браузерах и устройствах.</li>
  </ul>
  <div class="article-nav"><a href="/blog.html">← Все статьи</a><a href="/blog/skolko-stoit-sait.html">Сколько стоит сайт →</a></div>
</article>
DECOY_POST4_EOF
}

# --------------------------------------------------------------- 3. nginx.conf --

write_xhttp_config() {
    local domain="$1" location="$2" conf_path="/etc/nginx/conf.d/xhttp.conf"
    local webroot="$DECOY_ROOT_DEFAULT" headers static_locations

    mkdir -p "$webroot"
    if [[ "$DECOY_DEPLOYED" -ne 1 && ! -f "$webroot/index.html" ]]; then
        echo "<html><body>It works.</body></html>" > "$webroot/index.html"
    fi

    # add_header в location отменяет наследование заголовков сервера, поэтому
    # набор повторяется в каждом статическом location. XHTTP location их не получает.
    headers="        add_header Alt-Svc 'h3=\":443\"; ma=86400' always;
        add_header Strict-Transport-Security \"max-age=31536000\" always;
        add_header X-Content-Type-Options \"nosniff\" always;
        add_header Referrer-Policy \"strict-origin-when-cross-origin\" always;"

    if [[ "$DECOY_DEPLOYED" -eq 1 ]]; then
        headers="${headers}
        add_header X-Frame-Options \"SAMEORIGIN\" always;
        add_header Permissions-Policy \"camera=(), microphone=(), geolocation=(), interest-cohort=()\" always;
        add_header Content-Security-Policy \"default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'\" always;"

        # Только prefix- и exact-location (без regex), чтобы не перехватывать путь XHTTP.
        static_locations="    error_page 404 /404.html;

    location = /404.html {
        root ${webroot};
        internal;
${headers}
    }

    location ^~ /assets/ {
        root ${webroot};
        try_files \$uri =404;
        expires 7d;
        access_log off;
${headers}
    }

    location = /favicon.ico {
        root ${webroot};
        expires 7d;
        access_log off;
${headers}
    }

    location = /favicon.svg {
        root ${webroot};
        expires 7d;
        access_log off;
${headers}
    }

    location / {
        root ${webroot};
        index index.html;
        try_files \$uri \$uri.html \$uri/index.html =404;
${headers}
    }"
    else
        static_locations="    location / {
        root ${webroot};
        index index.html;
${headers}
    }"
    fi

    log_info "Пишу конфиг ${conf_path} (location /${location}/)..."
    cat > "$conf_path" <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name ${domain};
    server_tokens off;

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen 443 quic reuseport;
    listen [::]:443 ssl;
    listen [::]:443 quic;

    server_name ${domain};
    server_tokens off;

    http2 on;
    http3 on;
    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256;

    add_header Alt-Svc 'h3=":443"; ma=86400';

    gzip on;
    gzip_vary on;
    gzip_comp_level 5;
    gzip_min_length 256;
    gzip_types text/plain text/css text/xml application/xml application/javascript text/javascript application/json image/svg+xml image/x-icon;

    client_header_timeout 5m;
    keepalive_timeout 5m;

    location /${location}/ {
        client_max_body_size 0;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        client_body_timeout 5m;
        grpc_read_timeout 315;
        grpc_send_timeout 5m;
        grpc_pass unix:/dev/shm/xrxh.socket;
    }

${static_locations}

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

    local backup
    backup="${compose_path}.bak.$(date +%Y%m%d%H%M%S)"
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
    local location
    location="$(ask "Введите location для XHTTP" "cloudst")"
    location="${location#/}"
    location="${location%/}"
    if [[ -z "$location" ]]; then
        log_err "Location не указан, выхожу."
        exit 1
    fi
    if [[ ! "$location" =~ ^[A-Za-z0-9._/-]+$ ]] || [[ "$location" == *..* ]]; then
        log_err "Location может содержать только буквы, цифры, точку, '_', '-' и '/'. Пример: cloudst"
        exit 1
    fi
    deploy_decoy_site "$domain"
    write_xhttp_config "$domain" "$location"
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
    log_ok "Готово! Домен: ${domain}, location: /${location}/"
    log_ok "Конфиг nginx: /etc/nginx/conf.d/xhttp.conf"
    if [[ "$DECOY_DEPLOYED" -eq 1 ]]; then
        log_ok "Сайт-прикрытие: https://${domain}/ (файлы в ${DECOY_ROOT_DEFAULT})"
    fi
    log_ok "Unix-socket для XHTTP: /dev/shm/xrxh.socket (должен слушать xray/remnanode внутри контейнера)"
}

main "$@"
