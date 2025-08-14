#!/bin/bash

cd /opt/remnanode/ || { echo "Не удалось перейти в /opt/remnanode/"; exit 1; }

sudo docker compose pull && \
sudo docker compose down && \
sudo docker compose up -d && \
sudo docker compose logs -f