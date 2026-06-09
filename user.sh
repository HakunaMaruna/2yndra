#!/bin/bash
set -euo pipefail

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
  echo "Этот скрипт нужно запускать от root (sudo)." >&2
  exit 1
fi

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_menu() {
  clear
  echo -e "${YELLOW}=== Системное меню ===${NC}"
  echo "1) Обновить репозитории (apt update)"
  echo "2) Установить Docker"
  echo "3) Создать пользователя SSH (только туннель, без установки программ)"
  echo "4) Удалить пользователя"
  echo "0) Выход"
  echo ""
}

read_yes_no() {
  local prompt="$1"
  while true; do
    read -rp "$prompt (Да/Нет): " choice
    # Приводим к нижнему регистру для унификации
    choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]')

    case "$choice" in
      "да"|"д"|"y"|"yes")
        echo "yes"
        return 0
        ;;
      "нет"|"н"|"n"|"no")
        echo "no"
        return 0
        ;;
      *)
        echo -e "${RED}Пожалуйста, введите Да или Нет (или Y/N).${NC}"
        ;;
    esac
  done
}

# Пункт 1: Обновление репозиториев и системы
do_update() {
  echo -e "${GREEN}Выполняем apt update...${NC}"
  apt update -y

  if [[ $(read_yes_no "Хотите обновить систему (apt upgrade)?") == "yes" ]]; then
    echo -e "${GREEN}Выполняем apt upgrade...${NC}"
    apt upgrade -y
    echo -e "${GREEN}Система обновлена.${NC}"
  else
    echo "Пропуск обновления системы."
  fi
}

# Пункт 2: Установка Docker
do_install_docker() {
  if [[ $(read_yes_no "Установить Docker?") != "yes" ]]; then
    echo "Установка Docker пропущена."
    return
  fi

  # Базовая проверка наличия curl
  if ! command -v curl &> /dev/null; then
    echo "Устанавливаем curl для загрузки скрипта Docker..."
    apt update && apt install -y curl
  fi

  echo "Загружаем официальный скрипт установки Docker..."
  curl -fsSL https://get.docker.com -o get-docker.sh
  sh get-docker.sh
  rm get-docker.sh

  echo -e "${GREEN}Docker установлен.${NC}"
}

# Пункт 3: Создать пользователя SSH только для туннеля
do_create_ssh_user() {
  read -rp "Введите имя нового пользователя (латинские буквы, без спецсимволов): " username
  if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo -e "${RED}Некорректное имя пользователя.${NC}"
    return 1
  fi

  # Генерируем случайный пароль
  password=$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9_!@#$%')

  # Создаём пользователя с минимальной оболочкой (nologin)
  useradd -m -s /usr/sbin/nologin "$username"

  # Устанавливаем пароль
  echo "${username}:${password}" | chpasswd

  echo -e "${GREEN}Пользователь '$username' создан.${NC}"
  echo -e "${YELLOW}Пароль:${NC} $password"
  echo "Пользователь не может запускать интерактивные программы (оболочка /usr/sbin/nologin)."
  echo "SSH-туннели будут работать."
}

# Пункт 4: Удалить пользователя
do_delete_user() {
  # Получаем список пользователей (UID >= 1000)
  mapfile -t users < <(getent passwd | awk -F: '$3 >= 1000 {print $1}' | sort)

  if [[ ${#users[@]} -eq 0 ]]; then
    echo "Нет пользователей для удаления (UID >= 1000)."
    return  # Завершаем функцию, если пользователей нет
  fi

  echo "Список пользователей (UID >= 1000):"
  for i in "${!users[@]}"; do
    echo "$((i+1))) ${users[i]}"
  done

  read -rp "Введите номер пользователя для удаления: " choice
  # Проверяем, что выбор корректен
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#users[@]} )); then
    echo -e "${RED}Неверный выбор.${NC}"
    return 1
  fi

  target_user="${users[$((choice-1))]}"

  if [[ $(read_yes_no "Вы уверены, что хотите удалить пользователя '$target_user'?") != "yes" ]]; then
    echo "Удаление отменено."
    return
  fi

  userdel -r "$target_user"
  echo -e "${GREEN}Пользователь '$target_user' удалён вместе с домашней директорией.${NC}"
}

# Основной цикл меню
while true; do
  print_menu
  read -rp "Выберите пункт меню: " option

  case "$option" in
    1) do_update ;;
    2) do_install_docker ;;
    3) do_create_ssh_user ;;
    4) do_delete_user ;;
    0) echo "Выход из скрипта."; break ;;
    *) echo -e "${RED}Неверный пункт меню.${NC}"; sleep 1 ;;
  esac

  echo ""
  read -rp "Нажмите Enter, чтобы продолжить..."
done
