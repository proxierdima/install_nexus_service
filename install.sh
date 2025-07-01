#!/bin/bash

set -e

# 0. Удаление старого сервиса
if [[ -f "/etc/systemd/system/nexus-node.service" ]]; then
  echo "⚠️ Обнаружен существующий systemd-сервис nexus-node"
  echo "⏹ Останавливаем и удаляем старый сервис..."
  systemctl stop nexus-node || true
  systemctl disable nexus-node || true
  rm -f /etc/systemd/system/nexus-node.service
  systemctl daemon-reload
  echo "✅ Старый nexus-node.service удалён"
else
  echo "ℹ️ systemd-сервис nexus-node отсутствует — продолжаем"
fi

curl https://cli.nexus.xyz/ | sh

source /root/.bashrc

SERVICE_NAME="nexus-node"
THREADS="6"
USER="root"
BIN_PATH="/root/.nexus/bin/nexus-network"
CLI_BIN="nexus-cli"
CONFIG_FILE="/root/.nexus/config.json"
LOG_PATH="/var/log/${SERVICE_NAME}.log"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
LOGROTATE_FILE="/etc/logrotate.d/${SERVICE_NAME}"
MONITOR_SCRIPT="/opt/monitor.sh"

# Проверка бинарников
for cmd in "$BIN_PATH" "$CLI_BIN"; do
  if [[ ! -x "$cmd" && -z "$(command -v $cmd)" ]]; then
    echo "❌ Не найден: $cmd"
    exit 1
  fi
done

# Установка jq при необходимости
if ! command -v jq &>/dev/null; then
  echo "📦 Устанавливаем jq..."
  apt-get update -y && apt-get install -y jq
fi

# Получение node_id и wallet из config или регистрация
if [[ -f "$CONFIG_FILE" ]]; then
  echo "📁 Обнаружен конфиг: $CONFIG_FILE"
  NODE_ID=$(jq -r '.node_id' "$CONFIG_FILE")
  WALLET=$(jq -r '.wallet_address' "$CONFIG_FILE")

  if [[ -z "$NODE_ID" || -z "$WALLET" || "$NODE_ID" == "null" || "$WALLET" == "null" ]]; then
    echo "❌ config.json повреждён или неполный."

    read -p "❓ Удалить повреждённый конфиг и зарегистрировать заново? (y/N): " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
      rm -f "$CONFIG_FILE"
      echo "🗑️ Удалён: $CONFIG_FILE"

      read -p "Введите адрес кошелька: " WALLET
      if [[ -z "$WALLET" ]]; then
        echo "❌ Адрес кошелька не может быть пустым"
        exit 1
      fi

      echo "🔐 Регистрируем пользователя..."
      nexus-cli register-user --wallet-address "$WALLET" || {
        echo "❌ Не удалось зарегистрировать пользователя"
        exit 1
      }

      echo "🆔 Регистрируем ноду..."
      NODE_ID=$(nexus-cli register-node | grep "Node registered successfully" | grep -oE '[0-9]+')
      if [[ -z "$NODE_ID" ]]; then
        echo "❌ Не удалось получить node ID"
        exit 1
      fi
      echo "✅ Node ID: $NODE_ID"
    else
      echo "🚫 Прервано пользователем"
      exit 1
    fi
  else
    echo "✅ Используем node_id: $NODE_ID"
  fi
else
  read -p "Введите адрес кошелька: " WALLET
  if [[ -z "$WALLET" ]]; then
    echo "❌ Адрес кошелька не может быть пустым"
    exit 1
  fi

  echo "🔐 Регистрируем пользователя..."
  nexus-cli register-user --wallet-address "$WALLET" || {
    echo "❌ Не удалось зарегистрировать пользователя"
    exit 1
  }

  echo "🆔 Регистрируем ноду..."
  NODE_ID=$(nexus-cli register-node | grep "Node registered successfully" | grep -oE '[0-9]+')
  if [[ -z "$NODE_ID" ]]; then
    echo "❌ Не удалось получить node ID"
    exit 1
  fi
  echo "✅ Node ID: $NODE_ID"
fi

# Создание systemd unit-файла
echo "📦 Создаём systemd unit: $SERVICE_FILE"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Nexus Network Node
After=network.target

[Service]
Type=simple
ExecStart=$BIN_PATH start --node-id $NODE_ID --max-threads $THREADS --headless
Restart=always
RestartSec=5
User=$USER
WorkingDirectory=/root
StandardOutput=append:$LOG_PATH
StandardError=append:$LOG_PATH

[Install]
WantedBy=multi-user.target
EOF

# Настройка logrotate
echo "🌀 Настраиваем logrotate: $LOGROTATE_FILE"
cat > "$LOGROTATE_FILE" <<EOF
$LOG_PATH {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF

# Перезапуск systemd
echo "🔄 Перезапуск systemd..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

# Добавление в мониторинг
if [[ -f "$MONITOR_SCRIPT" ]]; then
  echo "📡 Обновляем мониторинг: $MONITOR_SCRIPT"
  if ! grep -q "$SERVICE_NAME" "$MONITOR_SCRIPT"; then
    sed -i "/^services=(/ s/)/ \"$SERVICE_NAME\")/" "$MONITOR_SCRIPT"
    echo "✅ Добавлен $SERVICE_NAME в мониторинг"
    systemctl restart server-monitor || echo "⚠️ Не удалось перезапустить мониторинг"
  else
    echo "ℹ️ $SERVICE_NAME уже отслеживается"
  fi
else
  echo "⚠️ Мониторинг-скрипт не найден по пути: $MONITOR_SCRIPT (пропущено)"
fi

# Финальный вывод
echo "✅ Установка завершена!"
systemctl status "$SERVICE_NAME" --no-pager
