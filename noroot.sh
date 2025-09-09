#!/bin/bash

# Проверка на root
if [ "$(id -u)" -ne 0 ]; then
    echo "➠ Запустите скрипт с sudo: sudo $0" >&2
    exit 1
fi

# Запрос имени пользователя
read -p "➠ Введите имя нового пользователя: " username

# Создание пользователя с паролем
echo "➠ Создаю пользователя $username..."
adduser --gecos "" "$username" || { echo "✗ Ошибка при создании пользователя"; exit 1; }

# Обновление пакетов и установка sudo
echo "➠ Обновляю пакеты и устанавливаю sudo..."
apt update && apt install -y sudo || { echo "✗ Ошибка при установке sudo"; exit 1; }

# Добавление пользователя в группу sudo
echo "➠ Добавляю $username в группу sudo..."
usermod -aG sudo "$username" || { echo "✗ Ошибка при добавлении в sudo"; exit 1; }

### 🔹Sudo С паролем 
echo "$username ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Отключение root-логина в SSH
echo "➠ Отключаю вход под root в SSH..."
sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config

# Перезапуск SSH
echo "➠ Перезапускаю SSH..."
systemctl restart ssh

# Итог
echo "
✅ Готово!
-------------------------------------------
▪ Новый пользователь: $username
▪ Пароль: тот, который вы задали
▪ Sudo: разрешён (с запросом пароля)
▪ Root-логин: ОТКЛЮЧЁН

🔐 Теперь подключайтесь так:
ssh $username@ваш_сервер_IP
"
