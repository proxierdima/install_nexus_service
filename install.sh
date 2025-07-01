#!/bin/bash

set -e

curl https://cli.nexus.xyz/ | sh

SERVICE_NAME="nexus-node"
THREADS="6"
USER="root"
BIN_PATH="/root/.nexus/bin/nexus-network"
CLI_BIN="nexus-cli"
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

# Получение адреса кошелька
read -p "Введите адрес кошелька: " WALLET
if [[ -z "$WALLET" ]]; then
  echo "❌ Адрес кошелька не может быть пустым"
  exit 1
fi

# Регистрация пользователя
echo "🔐 Регистрируем пользователя..."
nexus-cli register-user --wallet-address "$WALLET" || {
  echo "❌ Не удалось зарегистрировать пользователя"
  exit 1
}

# Регистрация ноды
echo "🆔 Регистрируем ноду..."
NODE_ID=$(nexus-cli register-node | grep "Node registered successfully" | grep -oE '[0-9]+')
if [[ -z "$NODE_ID" ]]; then
  echo "❌ Не удалось получить node ID"
  exit 1
fi
echo "✅ Node ID: $NODE_ID"

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
    echo "✅ Добавлен $SERVICE_NAME в список мониторинга"
    systemctl restart server-monitor || echo "⚠️ Не удалось перезапустить мониторинг"
  else
    echo "ℹ️ $SERVICE_NAME уже отслеживается"
  fi
else
  echo "⚠️ Мониторинг-скрипт не найден по пути: $MONITOR_SCRIPT (пропущено)"
fi

# Вывод статуса
echo "✅ Установка завершена!"
systemctl status "$SERVICE_NAME" --no-pager
