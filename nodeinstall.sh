#!/bin/bash

# Установка докера
sudo curl -fsSL https://get.docker.com | sh
echo "Docker установлен"

# Создаём директории
sudo mkdir -p /opt/remnanode && cd /opt/remnanode
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
echo "Теперь нужно получить SECRET сертификат с панели управления:"
echo "1. Перейдите в главную панель во вкладку 'Ноды'"
echo "2. Нажмите кнопку 'Создать новую ноду или выберите существующую'"
echo "3. Скопируйте значение SECRET_KEY (можно с префиксом SECRET_KEY= или без него)"
echo ""
read -p "Вставьте значение ключа: " secret_key

# Нормализуем SSL_CERT: убираем возможный префикс
secret_key="${secret_key#SECRET_KEY=}"

echo "Переменные настроены"

# Настройка логирования
read -p "Включить ли логирование? (y/n): " enable_logs
if [[ "$enable_logs" =~ ^[YyДд]$ ]]; then
    echo "Настройка логирования..."
    sudo mkdir -p /var/log/remnanode
    sudo apt update && sudo apt install -y logrotate
    
    sudo tee /etc/logrotate.d/remnanode <<EOF
/var/log/remnanode/*.log {
      size 50M
      rotate 5
      compress
      missingok
      notifempty
      copytruncate
  }
EOF
    sudo logrotate -vf /etc/logrotate.d/remnanode
    LOG_VOLUME="        volumes:
            - '/var/log/remnanode:/var/log/remnanode'"
else
    LOG_VOLUME=""
fi

# Настройка net_admin
read -p "Включить ли net_admin? (y/n): " enable_net_admin
if [[ "$enable_net_admin" =~ ^[YyДд]$ ]]; then
    CAP_ADD="        cap_add:
            - NET_ADMIN"
else
    CAP_ADD=""
fi

# Создаём файл docker-compose.yml
cat <<EOF > docker-compose.yml
services:
    remnanode:
        container_name: remnanode
        hostname: remnanode
        image: remnawave/node:latest
        restart: always
        network_mode: host
        environment:
            - NODE_PORT=$port
            - SECRET_KEY="$secret_key"
$LOG_VOLUME
$CAP_ADD
EOF
echo "Файл docker-compose.yml создан"

# Запускаем ноду
sudo docker compose up -d
echo "Нода запущена ✅"

# Проверяем логи
sudo docker compose logs -f
