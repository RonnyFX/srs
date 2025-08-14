#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Настройка SNI сайта ===${NC}"

# Обновление системы
echo -e "${YELLOW}Обновляем систему...${NC}"
sudo apt update && sudo apt upgrade -y

# Установка Nginx и Certbot
echo -e "${YELLOW}Устанавливаем Nginx и Certbot...${NC}"
sudo apt install -y nginx certbot python3-certbot-nginx python3-certbot-dns-cloudflare

# Удаление default конфигурации
echo -e "${YELLOW}Удаляем default конфигурацию Nginx...${NC}"
sudo rm -f /etc/nginx/sites-enabled/default

# Создание директории для сайта
echo -e "${YELLOW}Создаем директорию для сайта...${NC}"
sudo mkdir -p /var/www/html/site

# Запрос GitHub репозитория
echo -e "${YELLOW}Настройка загрузки файлов с GitHub:${NC}"
read -p "Введите URL GitHub репозитория (например: https://github.com/username/repo): " github_repo
read -p "Введите ветку (или Enter для main): " branch
branch=${branch:-main}
read -p "Введите подпапку в репозитории (например: site, или Enter если файлы в корне): " subfolder

# Создаем временную директорию для клонирования
temp_dir="/tmp/github_temp_$$"
echo -e "${YELLOW}Создаем временную директорию...${NC}"
sudo mkdir -p $temp_dir

# Загрузка файлов с GitHub
echo -e "${YELLOW}Загружаем файлы с GitHub...${NC}"
if command -v git &> /dev/null; then
    sudo git clone -b $branch $github_repo $temp_dir
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Репозиторий склонирован${NC}"
        
        # Копируем файлы из подпапки или корня
        if [ -n "$subfolder" ] && [ -d "$temp_dir/$subfolder" ]; then
            echo -e "${YELLOW}Копируем файлы из подпапки '$subfolder'...${NC}"
            sudo cp -r $temp_dir/$subfolder/* /var/www/html/site/
        else
            echo -e "${YELLOW}Копируем файлы из корня репозитория...${NC}"
            sudo cp -r $temp_dir/* /var/www/html/site/
        fi
        
        sudo chown -R www-data:www-data /var/www/html/site
        echo -e "${GREEN}Файлы загружены с GitHub${NC}"
    else
        echo -e "${RED}Ошибка при клонировании репозитория${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}Git не установлен. Устанавливаем...${NC}"
    sudo apt install -y git
    sudo git clone -b $branch $github_repo $temp_dir
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Репозиторий склонирован${NC}"
        
        # Копируем файлы из подпапки или корня
        if [ -n "$subfolder" ] && [ -d "$temp_dir/$subfolder" ]; then
            echo -e "${YELLOW}Копируем файлы из подпапки '$subfolder'...${NC}"
            sudo cp -r $temp_dir/$subfolder/* /var/www/html/site/
        else
            echo -e "${YELLOW}Копируем файлы из корня репозитория...${NC}"
            sudo cp -r $temp_dir/* /var/www/html/site/
        fi
        
        sudo chown -R www-data:www-data /var/www/html/site
        echo -e "${GREEN}Файлы загружены с GitHub${NC}"
    else
        echo -e "${RED}Ошибка при клонировании репозитория${NC}"
        exit 1
    fi
fi

# Очищаем временную директорию
echo -e "${YELLOW}Очищаем временные файлы...${NC}"
sudo rm -rf $temp_dir

# Настройка Cloudflare DNS
echo -e "${YELLOW}Настройка Cloudflare DNS:${NC}"
read -p "Введите ваш Cloudflare API токен: " cf_token
read -p "Введите ваш домен (например: example.com): " domain

# Создание конфигурации Cloudflare
echo -e "${YELLOW}Создаем конфигурацию Cloudflare...${NC}"
sudo mkdir -p /etc/letsencrypt
echo "dns_cloudflare_api_token = $cf_token" | sudo tee /etc/letsencrypt/cloudflare.ini > /dev/null
sudo chmod 600 /etc/letsencrypt/cloudflare.ini

# Получение SSL сертификата
echo -e "${YELLOW}Получаем SSL сертификат...${NC}"
sudo certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
    -d $domain \
    -d *.$domain \
    --non-interactive \
    --agree-tos \
    --email admin@$domain

if [ $? -eq 0 ]; then
    echo -e "${GREEN}SSL сертификат получен успешно!${NC}"
else
    echo -e "${RED}Ошибка при получении SSL сертификата${NC}"
    exit 1
fi

# Создание конфигурации Nginx
echo -e "${YELLOW}Создаем конфигурацию Nginx...${NC}"
sudo tee /etc/nginx/sites-available/sni.conf > /dev/null <<EOF
server {
    listen 80;
    server_name $domain;

    location /.well-known/acme-challenge/ {
        allow all;
        root /var/www/html/site;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 127.0.0.1:8443 ssl http2 proxy_protocol;
    server_name $domain;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384';
    ssl_session_cache shared:SSL:1m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # Настройки Proxy Protocol
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;

    root /var/www/html/site;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

# Включение сайта
echo -e "${YELLOW}Включаем сайт...${NC}"
sudo ln -sf /etc/nginx/sites-available/sni.conf /etc/nginx/sites-enabled/

# Проверка конфигурации и перезагрузка
echo -e "${YELLOW}Проверяем конфигурацию Nginx...${NC}"
if sudo nginx -t; then
    echo -e "${GREEN}Конфигурация корректна${NC}"
    echo -e "${YELLOW}Перезагружаем Nginx...${NC}"
    sudo systemctl restart nginx
    sudo systemctl enable nginx
    
    echo -e "${GREEN}=== SNI сайт настроен успешно! ===${NC}"
    echo -e "${YELLOW}Ваш сайт доступен по адресу: https://$domain${NC}"
    echo -e "${YELLOW}Порт 8443 настроен для проксирования${NC}"
else
    echo -e "${RED}Ошибка в конфигурации Nginx${NC}"
    exit 1
fi

# Настройка автообновления сертификата
echo -e "${YELLOW}Настраиваем автообновление сертификата...${NC}"
sudo tee /etc/cron.d/certbot-renew > /dev/null <<EOF
0 12 * * * /usr/bin/certbot renew --quiet
EOF

echo -e "${GREEN}Автообновление сертификата настроено${NC}"
echo -e "${GREEN}Скрипт завершен!${NC}"