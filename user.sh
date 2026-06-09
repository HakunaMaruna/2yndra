#!/usr/bin/env bash
set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Функция для вывода ошибок
error() {
    echo -e "${RED}Ошибка: $1${NC}" >&2
}

# Функция для вывода успехов
success() {
    echo -e "${GREEN}$1${NC}"
}

# Функция для предупреждений
warning() {
    echo -e "${YELLOW}$1${NC}"
}

# Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Этот скрипт нужно запускать от root (sudo)."
        exit 1
    fi
}

# Валидация имени пользователя
validate_username() {
    local username=$1
    if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        return 1
    fi
    return 0
}

# Генерация пароля
generate_password() {
    openssl rand -base64 24 | tr -dc 'A-Za-z0-9!@#$%^&*'
}

# Создание пользователя
create_user() {
    read -p "Введите имя нового пользователя (только латинские буквы, без спецсимволов): " username

    if [[ -z "$username" ]]; then
        error "Имя пользователя не может быть пустым."
        return 1
    fi

    if ! validate_username "$username"; then
        error "Некорректное имя пользователя."
        return 1
    fi

    # Проверяем, существует ли пользователь
    if id "$username" &>/dev/null; then
        error "Пользователь '$username' уже существует."
        return 1
    fi

    # Генерация пароля
    password=$(generate_password)

    # Создание пользователя: /usr/sbin/nologin запрещает локальный вход
    useradd -m -s /usr/sbin/nologin "$username"

    # Установка пароля
    echo "${username}:${password}" | chpasswd

    success "Пользователь '$username' создан."

    # Запрет sudo
    echo "${username} ALL=(ALL) NOPASSWD: /bin/false" > /etc/sudoers.d/"${username}_no_sudo"
    chmod 0440 /etc/sudoers.d/"${username}_no_sudo"

    # Убираем из групп, которые могут давать права
    if id "$username" | grep -q "\bsudo\b"; then
        gpasswd -d "$username" sudo || true
    fi

    # Запрет установки программ через ACL
    if command -v setfacl &> /dev/null; then
        for cmd in /usr/bin/apt /usr/bin/apt-get; do
            if [[ -x "$cmd" ]]; then
                setfacl -m u:"${username}:---" "$cmd" 2>/dev/null || true
            fi
        done
    fi

    # Настройка SSH для туннелирования
    SSHD_CONFIG="/etc/ssh/sshd_config"

    if ! grep -q "^Match User ${username}" "$SSHD_CONFIG"; then
        cat >> "$SSHD_CONFIG" <<EOF

Match User ${username}
    AllowTcpForwarding yes
    X11Forwarding no
    PermitTunnel yes
    ForceCommand echo 'Tunneling only'; sleep infinity
EOF
        success "Добавлен блок Match User для ${username} в sshd_config."
    else
        warning "Пользователь уже имеет блок Match в sshd_config — проверьте вручную."
    fi

    echo ""
    success "=== Готово ==="
    echo "Пользователь: $username"
    echo "Пароль: $password"
    echo ""
    echo "Обязательно выполните:"
    echo "  sudo systemctl restart ssh"
    echo ""
    echo "Как проверить туннель:"
    echo "  ssh -N -L 8080:localhost:80 ${username}@ваш_сервер"
    echo "Попытка обычного входа (ssh ${username}@ваш_сервер) должна выводить 'Tunneling only' и закрывать сессию."
}

# Удаление пользователя
delete_user() {
    read -p "Введите имя пользователя для удаления: " username

    if [[ -z "$username" ]]; then
        error "Имя пользователя не может быть пустым."
        return 1
    fi

    # Проверяем существование пользователя
    if ! id "$username" &>/dev/null; then
        error "Пользователь '$username' не существует."
        return 1
    fi

    echo -n "Вы уверены, что хотите удалить пользователя '$username' и все его данные? (y/N): "
    read -r confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Удаление отменено."
        return 0
    fi

    # Удаляем файл sudoers
    sudoers_file="/etc/sudoers.d/${username}_no_sudo"
    if [[ -f "$sudoers_file" ]]; then
        rm -f "$sudoers_file"
        success "Удален файл sudoers для пользователя '$username'."
    fi

    # Удаляем ACL правила
    if command -v getfacl &> /dev/null; then
        for cmd in /usr/bin/apt /usr/bin/apt-get; do
            if [[ -x "$cmd" ]] && getfacl "$cmd" 2>/dev/null | grep -q "user:$username"; then
                setfacl -x u:"$username" "$cmd" 2>/dev/null || true
            fi
        done
        success "Удалены ACL правила для пользователя '$username'."
    fi

    # Удаляем блок из sshd_config
    SSHD_CONFIG="/etc/ssh/sshd_config"
    if grep -q "^Match User ${username}" "$SSHD_CONFIG"; then
        # Создаем временный файл без блока пользователя
        tmp_file=$(mktemp)
        awk -v user="$username" '
            /^Match User / {
                if ($3 == user) {
                    in_block = 1
                    next
                } else if (in_block) {
                    if (/^[^ ]/) in_block = 0
                    else next
                }
            }
            !in_block
        ' "$SSHD_CONFIG" > "$tmp_file"

        # Копируем обратно, если файл изменился
        if [[ $(wc -l < "$tmp_file") -lt $(wc -l < "$SSHD_CONFIG") ]]; then
            cp "$tmp_file" "$SSHD_CONFIG"
            success "Удален блок Match User для '$username' из sshd_config."
        fi
        rm -f "$tmp_file"
    fi

    # Удаляем пользователя и его домашнюю директорию
    userdel -r "$username" 2>/dev/null || userdel "$username"

    success
