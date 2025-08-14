#!/bin/bash

# Установка докера
sudo curl -fsSL https://get.docker.com | sh
echo "Docker установлен"

# Создаём директории
mkdir -p /opt/remnanode && cd /opt/remnanode
echo "Директория /opt/remnanode создана"

# Функция для проверки и настройки UFW
setup_ufw() {
    if ! command -v ufw &> /dev/null; then
        echo "UFW не установлен. Устанавливаем..."
        sudo apt update && sudo apt install -y ufw
    fi
    
    if ! sudo ufw status | grep -q "Status: active"; then
        echo "UFW выключен. Включаем..."
        sudo ufw --force enable
    fi
}

# Функция для проверки порта
check_port() {
	local port=$1
	if command -v ss >/dev/null 2>&1; then
		if ss -tuln | awk '{print $5}' | grep -E "[:\.]${port}$" >/dev/null 2>&1; then
			return 1  # Порт занят
		fi
	elif command -v netstat >/dev/null 2>&1; then
		if netstat -tuln | awk '{print $4}' | grep -E "[:\.]${port}$" >/dev/null 2>&1; then
			return 1  # Порт занят
		fi
	else
		echo "Утилита для проверки портов не найдена. Устанавливаю net-tools..."
		sudo apt update && sudo apt install -y net-tools
		if netstat -tuln | awk '{print $4}' | grep -E "[:\.]${port}$" >/dev/null 2>&1; then
			return 1  # Порт занят
		fi
	fi
	return 0  # Порт свободен
}

# Функция для открытия порта в UFW
open_port() {
    local port=$1
    local ip=$2
    if [ -n "$ip" ]; then
        sudo ufw allow from $ip to any port $port
        echo "Порт $port открыт для IP $ip"
    else
        sudo ufw allow $port
        echo "Порт $port открыт для всех"
    fi
}

# Настраиваем UFW
setup_ufw

# Создаём файл .env с правильным форматом
echo "APP_PORT=" > .env

# Запрашиваем порт с проверкой
while true; do
    read -p "Введите порт для доступа к ноде: " port
    
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "Ошибка: порт должен быть числом от 1 до 65535"
        continue
    fi
    
    if ! check_port $port; then
        echo "Порт $port уже занят. Выберите другой порт."
        continue
    fi
    
    # Обновляем .env файл с выбранным портом
    sed -i "s/APP_PORT=/APP_PORT=$port/" .env
    
    # Запрашиваем IP для ограничения доступа к порту
    read -p "Введите IP адрес для ограничения доступа к порту $port (или Enter для всех): " ip
    if [ -n "$ip" ]; then
        open_port $port $ip
    else
        open_port $port
    fi
    
    break
done

# Запрашиваем SSL сертификат с панели
echo ""
echo "Теперь нужно получить SSL сертификат с панели управления:"
echo "1. Перейдите в главную панель во вкладку 'Ноды'"
echo "2. Нажмите кнопку 'Создать новую ноду или выберите существующую'"
echo "3. Скопируйте значение SSL_CERT (можно с префиксом SSL_CERT= или без него)"
echo ""
read -p "Вставьте значение SSL сертификата: " ssl_cert

# Нормализуем SSL_CERT: убираем возможный префикс
ssl_cert="${ssl_cert#SSL_CERT=}"

# Добавляем/обновляем SSL_CERT в .env файле
if grep -q '^SSL_CERT=' .env 2>/dev/null; then
	sed -i "s/^SSL_CERT=.*/SSL_CERT=$ssl_cert/" .env
else
	echo "SSL_CERT=$ssl_cert" >> .env
fi

echo "Переменные настроены"

# Создаём файл docker-compose.yml
tee docker-compose.yml <<EOF
services:
    remnanode:
        container_name: remnanode
        hostname: remnanode
        image: remnawave/node:latest
        restart: always
        network_mode: host
        env_file:
            - .env
EOF
echo "Файл docker-compose.yml создан"

# Запускаем ноду
docker compose up -d
echo "Нода запущена ✅"

# Проверяем логи
docker compose logs -f