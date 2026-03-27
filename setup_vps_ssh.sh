#!/bin/bash

# Скрипт для настройки SSH доступа по ключам и отключения парольной аутентификации
# ВАЖНО: Запускать непосредственно на самом VPS от имени root

echo "================================================="
echo "   Настройка SSH (отключение пароля для root)"
echo "================================================="
echo ""

# Проверка, что скрипт запущен от root
if [ "$(id -u)" -ne 0 ]; then
    echo "Ошибка: Этот скрипт должен быть запущен от имени пользователя root (или через sudo)."
    exit 1
fi

echo "Пожалуйста, вставьте ваш ПУБЛИЧНЫЙ SSH ключ"
echo "(Обычно он начинается с ssh-rsa, ssh-ed25519 или ecdsa-sha2-nistp256):"
read -p "> " PUB_KEY

if [ -z "$PUB_KEY" ]; then
    echo "Ошибка: Ключ не может быть пустым."
    exit 1
fi

# Базовая проверка формата ключа
if [[ "$PUB_KEY" != ssh-* ]] && [[ "$PUB_KEY" != ecdsa-* ]]; then
    echo "Предупреждение: Введенная строка не похожа на стандартный SSH публичный ключ."
    read -p "Вы уверены, что хотите продолжить? (y/n): " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "Отмена."
        exit 1
    fi
fi

# Настройка папки .ssh и authorized_keys
mkdir -p /root/.ssh
chmod 700 /root/.ssh

# Добавляем ключ в authorized_keys, если его там еще нет
if grep -qF "$PUB_KEY" /root/.ssh/authorized_keys 2>/dev/null; then
    echo "Этот ключ уже присутствует в /root/.ssh/authorized_keys."
else
    echo "$PUB_KEY" >> /root/.ssh/authorized_keys
    echo "Ключ успешно добавлен в /root/.ssh/authorized_keys."
fi
chmod 600 /root/.ssh/authorized_keys

# Резервная копия конфига SSH
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
echo "Создана резервная копия конфигурации SSH: /etc/ssh/sshd_config.bak"

# Настройка sshd_config
# 1. Отключаем вход по паролю (раскомментируем и меняем значение, либо добавляем в конец)
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
if ! grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config; then
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
fi

# 2. Разрешаем root логин только по ключам (prohibit-password)
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
if ! grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then
    echo "PermitRootLogin prohibit-password" >> /etc/ssh/sshd_config
fi

echo "Конфигурация SSH обновлена. Перезапуск службы..."

# Перезапуск службы SSH (поддержка systemd и init.d, а также названий ssh/sshd)
if command -v systemctl >/dev/null 2>&1; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd
else
    service ssh restart 2>/dev/null || service sshd restart
fi

echo ""
echo "================================================="
echo "УСПЕХ! Настройка завершена."
echo "Вход по паролю отключен."
echo ""
echo "ВАЖНО: Не закрывайте эту сессию терминала!"
echo "Откройте новое окно терминала и проверьте, что вы можете зайти на сервер по ключу."
echo "================================================="
