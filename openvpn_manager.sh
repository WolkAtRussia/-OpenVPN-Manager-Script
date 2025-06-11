#!/bin/bash

# Проверка на root
if [ "$EUID" -ne 0 ]; then
  echo "Этот скрипт должен быть запущен с правами root. Используйте sudo."
  exit 1
fi

# Функция определения внешнего интерфейса
get_external_interface() {
  ip route | grep default | awk '{print $5}'
}

# Функция установки OpenVPN
setup_openvpn() {
  echo "### Установка OpenVPN ###"
  apt update && apt upgrade -y
  apt install -y openvpn easy-rsa

  mkdir -p /etc/openvpn/easy-rsa
  cp -r /usr/share/easy-rsa/* /etc/openvpn/easy-rsa/
  cd /etc/openvpn/easy-rsa/

  ./easyrsa init-pki
  echo "Установка переменных (можно оставить по умолчанию)..."
  ./easyrsa build-ca nopass

  echo "Генерация сертификата сервера..."
  ./easyrsa gen-req server nopass
  ./easyrsa sign-req server server

  ./easyrsa gen-dh
  openvpn --genkey --secret ta.key

  cp pki/ca.crt pki/private/ca.key pki/issued/server.crt pki/private/server.key pki/dh.pem ta.key /etc/openvpn/

  cat > /etc/openvpn/server.conf <<EOF
port 1194
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"
keepalive 10 120
tls-auth ta.key 0
cipher AES-256-CBC
persist-key
persist-tun
status openvpn-status.log
verb 3
EOF

  # Включение IP-форвардинга
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  sysctl -p

  # Настройка iptables
  EXT_IF=$(get_external_interface)
  iptables -t nat -A POSTROUTING -o $EXT_IF -j MASQUERADE
  iptables -A FORWARD -i tun0 -j ACCEPT
  iptables -A FORWARD -i $EXT_IF -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT
  iptables-save > /etc/iptables.rules

  # Настройка firewall (если используется ufw)
  if command -v ufw &> /dev/null; then
    ufw allow 1194/udp
    sed -i '/DEFAULT_FORWARD_POLICY/s/DROP/ACCEPT/' /etc/default/ufw
    ufw reload
  fi

  systemctl enable --now openvpn@server
  echo "Сервер OpenVPN успешно настроен!"
  echo "Внешний интерфейс для MASQUERADE: $EXT_IF"
}

# Функция диагностики OpenVPN
diagnose_openvpn() {
  echo "### Диагностика OpenVPN ###"
  
  # Проверка статуса сервиса
  echo -e "\n[1] Статус сервиса OpenVPN:"
  systemctl status openvpn@server --no-pager
  
  # Проверка интерфейсов
  echo -e "\n[2] Сетевые интерфейсы (tun/tap):"
  ip a | grep -E '(tun|tap)' || echo "Интерфейсы tun/tap не найдены!"
  
  # Проверка маршрутизации
  echo -e "\n[3] Таблица маршрутизации:"
  ip route
  
  # Проверка форвардинга
  echo -e "\n[4] IP Forwarding:"
  sysctl net.ipv4.ip_forward
  
  # Проверка правил iptables
  echo -e "\n[5] Правила iptables (NAT и FORWARD):"
  iptables -t nat -L -n -v
  iptables -L FORWARD -n -v
  
  # Проверка подключённых клиентов
  echo -e "\n[6] Активные клиенты:"
  grep "CLIENT_LIST" /etc/openvpn/openvpn-status.log 2>/dev/null || echo "Нет активных клиентов"
  
  # Проверка логов
  echo -e "\n[7] Последние логи OpenVPN:"
  journalctl -u openvpn@server -n 20 --no-pager
  
  # Проверка DNS
  echo -e "\n[8] Проверка DNS:"
  ping -c 2 8.8.8.8
  ping -c 2 google.com || echo "DNS не работает!"
}

# Функция генерации клиентского конфига
generate_client() {
  echo "### Генерация клиента ###"
  if [ -z "$1" ]; then
    read -p "Введите имя клиента: " CLIENT_NAME
  else
    CLIENT_NAME="$1"
  fi

  cd /etc/openvpn/easy-rsa/
  ./easyrsa gen-req "$CLIENT_NAME" nopass
  ./easyrsa sign-req client "$CLIENT_NAME"

  mkdir -p ~/openvpn-clients/"$CLIENT_NAME"
  cp pki/ca.crt pki/issued/"$CLIENT_NAME".crt pki/private/"$CLIENT_NAME".key ta.key ~/openvpn-clients/"$CLIENT_NAME"/

  read -p "Введите IP-адрес сервера: " SERVER_IP
  cat > ~/openvpn-clients/"$CLIENT_NAME"/"$CLIENT_NAME".ovpn <<EOF
client
dev tun
proto udp
remote $SERVER_IP 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-CBC
verb 3

<ca>
$(cat pki/ca.crt)
</ca>

<cert>
$(cat pki/issued/"$CLIENT_NAME".crt)
</cert>

<key>
$(cat pki/private/"$CLIENT_NAME".key)
</key>

<tls-auth>
$(cat ta.key)
</tls-auth>
key-direction 1
EOF

  echo "Клиентский конфиг создан: ~/openvpn-clients/$CLIENT_NAME/$CLIENT_NAME.ovpn"
}

# Функция удаления клиента
delete_client() {
  echo "### Удаление клиента ###"
  if [ -z "$1" ]; then
    read -p "Введите имя клиента: " CLIENT_NAME
  else
    CLIENT_NAME="$1"
  fi

  cd /etc/openvpn/easy-rsa/
  ./easyrsa revoke "$CLIENT_NAME"
  ./easyrsa gen-crl

  rm -rf ~/openvpn-clients/"$CLIENT_NAME"
  echo "Клиент $CLIENT_NAME удалён!"
}

# Функция перезапуска OpenVPN
restart_openvpn() {
  echo "### Перезапуск OpenVPN ###"
  systemctl restart openvpn@server
  systemctl status openvpn@server --no-pager
}

# Функция проверки статуса
check_status() {
  echo "### Статус OpenVPN ###"
  systemctl status openvpn@server --no-pager
  echo -e "\n### Активные клиенты ###"
  grep "CLIENT_LIST" /etc/openvpn/openvpn-status.log 2>/dev/null || echo "Нет активных клиентов."
}

# Главное меню
while true; do
  echo -e "\n=== OpenVPN Менеджер ==="
  echo "1) Установить и настроить OpenVPN"
  echo "2) Создать клиентский конфиг"
  echo "3) Удалить клиентский конфиг"
  echo "4) Перезапустить OpenVPN"
  echo "5) Проверить статус сервера"
  echo "6) Диагностика OpenVPN"
  echo "7) Выход"
  read -p "Выберите действие [1-7]: " CHOICE

  case $CHOICE in
    1) setup_openvpn ;;
    2) generate_client ;;
    3) delete_client ;;
    4) restart_openvpn ;;
    5) check_status ;;
    6) diagnose_openvpn ;;
    7) exit 0 ;;
    *) echo "Неверный выбор! Попробуйте снова." ;;
  esac
done
