#!/bin/bash

read -p "Введите IP, для которого открыть порт 9100: " ALLOWED_IP

# Скачиваем Node Exporter
wget https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz

# Распаковываем архив
tar xvf node_exporter-1.8.2.linux-amd64.tar.gz

# Удаляем архив
rm node_exporter-1.8.2.linux-amd64.tar.gz

# Перемещаем папку
sudo mv node_exporter-1.8.2.linux-amd64 node_exporter

# Делаем бинарник исполняемым
chmod +x node_exporter/node_exporter

# Перемещаем бинарник в /usr/bin
sudo mv node_exporter/node_exporter /usr/bin/

# Удаляем временную папку
rm -Rvf node_exporter/

# Создаём systemd-сервис
sudo tee /etc/systemd/system/exporterd.service > /dev/null <<EOF
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=root
ExecStart=/usr/bin/node_exporter

[Install]
WantedBy=multi-user.target
EOF

# Запускаем сервис и добавляем в автозапуск
sudo systemctl daemon-reload
sudo systemctl enable exporterd.service
sudo systemctl start exporterd.service

# Открываем порт только для указанного IP
sudo ufw allow from $ALLOWED_IP to any port 9100
