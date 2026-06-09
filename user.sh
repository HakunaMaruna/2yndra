#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт нужно запускать от root (sudo)." >&2
   exit 1
fi

read -p "Введите имя нового пользователя (только латинские буквы, без спецсимволов): " username

if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
   echo "Некорректное имя пользователя." >&2
   exit 1
fi

# Генерация пароля
password=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9!@#$%^&*')

# Создание пользователя: /usr/sbin/nologin запрещает локальный вход
useradd -m -s /usr/sbin/nologin "$username"

# Установка пароля
echo "${username}:${password}" | chpasswd

echo "Пользователь '$username' создан."
echo "Сгенерированный пароль: $password"

# Запрет sudo: правило, которое при вызове sudo всегда выполняет /bin/false
echo "${username} ALL=(ALL) NOPASSWD: /bin/false" > /etc/sudoers.d/"${username}_no_sudo"
chmod 0440 /etc/sudoers.d/"${username}_no_sudo"

# Убираем из групп, которые могут давать права (на Ubuntu это в первую очередь sudo)
if id "$username" | grep -q "\bsudo\b"; then
   gpasswd -d "$username" sudo || true
fi

# Запрет установки программ: блокируем прямой запуск apt/apt-get через ACL (если acl есть)
if command -v setfacl &> /dev/null; then
   for cmd in /usr/bin/apt /usr/bin/apt-get; do
      if [[ -x "$cmd" ]]; then
         setfacl -m u:"${username}:---" "$cmd" 2>/dev/null || true
      fi
   done
fi

# Настройка SSH только для туннелирования
SSHD_CONFIG="/etc/ssh/sshd_config"

if ! grep -q "^Match User ${username}" "$SSHD_CONFIG"; then
   cat >> "$SSHD_CONFIG" <<EOF

Match User ${username}
    AllowTcpForwarding yes
    X11Forwarding no
    PermitTunnel yes
    # ForceCommand не даёт запустить интерактивную оболочку.
    # sleep infinity держит соединение открытым для туннелей, но не пускает shell.
    ForceCommand echo 'Tunneling only'; sleep infinity
    # ChrootDirectory можно включить, только если вы подготовили окружение внутри него.
    # Пока закомментировано, чтобы не сломать вход.
    # ChrootDirectory /home/${username}
EOF
   echo "Добавлен блок Match User для ${username} в sshd_config."
   echo "После завершения нужно перезапустить sshd: sudo systemctl restart ssh"
else
   echo "Пользователь уже имеет блок Match в sshd_config — проверьте вручную."
fi

echo ""
echo "=== Готово ==="
echo "Пользователь: $username"
echo "Пароль: $password"
echo ""
echo "Обязательно выполните:"
echo "  sudo systemctl restart ssh"
echo ""
echo "Как проверить туннель:"
echo "  ssh -N -L 8080:localhost:80 ${username}@ваш_сервер"
echo "Попытка обычного входа (ssh ${username}@ваш_сервер) должна выводить 'Tunneling only' и закрывать сессию."
