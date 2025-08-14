#!/bin/bash

# Проверяем, запущен ли скрипт от root
if [ "$(id -u)" -ne 0 ]; then
    echo "Этот скрипт должен быть запущен с правами root" >&2
    exit 1
fi

# Запрашиваем новый порт у пользователя
read -p "Введите новый порт SSH (рекомендуется в диапазоне 1024-49151): " new_port

# Проверяем, что введённое значение - число
if ! [[ "$new_port" =~ ^[0-9]+$ ]]; then
    echo "Ошибка: порт должен быть числом" >&2
    exit 1
fi

# Проверяем, что порт в допустимом диапазоне
if [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
    echo "Ошибка: порт должен быть в диапазоне 1-65535" >&2
    exit 1
fi

# Изменяем порт в sshd_config
echo "Изменение порта SSH на $new_port..."
sed -i "s/^#Port 22/Port $new_port/" /etc/ssh/sshd_config
sed -i "s/^Port [0-9]\+/Port $new_port/" /etc/ssh/sshd_config
if ! grep -q "^Port $new_port" /etc/ssh/sshd_config; then
    echo "Port $new_port" >> /etc/ssh/sshd_config
fi

# Проверяем, установлен ли UFW
if ! command -v ufw &> /dev/null; then
    echo "UFW не установлен, устанавливаем..."
    apt-get update
    apt-get install -y ufw
fi

# Включаем UFW, если он выключен
if ! ufw status | grep -q "Status: active"; then
    echo "Включаем UFW..."
    ufw --force enable
fi

# Открываем новый порт в UFW
echo "Открываем порт $new_port в UFW..."
ufw allow "$new_port"/tcp

# Закрываем старый порт 22, если он открыт
if ufw status | grep -q "22/tcp"; then
    echo "Закрываем порт 22 в UFW..."
    ufw delete allow 22/tcp
fi

# Перезапускаем SSH-сервер
echo "Перезапускаем SSH-сервер..."
systemctl restart sshd

# Проверяем, что SSH слушает на новом порту
echo "Проверяем новый порт..."
ss -tulnp | grep "ssh"

echo "Готово! SSH теперь работает на порту $new_port"
echo "АХТУНГ: Не закрывайте это соединение, пока не убедитесь, что можете подключиться через новый порт!"
echo "Для подключения используйте команду: ssh -p $new_port user@your_vps_ip"
