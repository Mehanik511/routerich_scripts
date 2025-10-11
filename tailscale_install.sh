#!/bin/sh
# Ахтунг! Вайбкодинг!
# Скрипт для удаления, установки и настройки Tailscale
PACKAGES="tailscale tailscale-lite luci-app-tailscale luci-i18n-tailscale-ru"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

# Переменные для отслеживания статуса установки
PACKAGES_REMOVED=0
PACKAGES_NOT_INSTALLED=0
TAILSCALE_SETUP_COMPLETED=0  # Флаг для отслеживания завершения настройки
SELECTED_ACTION=""  # Выбранное действие

show_menu() {
    printf "${PURPLE}=== Скрипт управления Tailscale ===${NC}\n"
    printf "${CYAN}Выберите действие:${NC}\n"
    printf "${YELLOW}1) Полная переустановка (удаление + установка + настройка)${NC}\n"
    printf "${YELLOW}2) Перенастройка (только настройка)${NC}\n"
    printf "${YELLOW}3) Только удаление${NC}\n"
    printf "${YELLOW}4) Отмена${NC}\n"
    printf "${CYAN}Введите номер действия (1-4): ${NC}"
}

remove_package() {
    local package=$1
    if opkg list-installed | grep -q "^$package -"; then
        opkg remove --force-removal-of-dependent-packages --force-remove $package
        if [ $? -eq 0 ]; then
            printf "${GREEN}[OK] Пакет $package успешно удален${NC}\n"
            PACKAGES_REMOVED=1
        else
            printf "${RED}[ERROR] Ошибка при удалении пакета $package${NC}\n"
        fi
    else
        printf "${YELLOW}[INFO] Пакет $package не установлен, пропускаем${NC}\n"
        PACKAGES_NOT_INSTALLED=1
    fi
}

create_tailscale_symlink() {
    printf "${YELLOW}[INFO] Проверяем расположение бинарников Tailscale...${NC}\n"
    
    # Проверка, что tailscaled существует в директории /usr/sbin/
    if [ -f /usr/sbin/tailscaled ] && [ ! -f /usr/bin/tailscaled ]; then
        printf "${YELLOW}[INFO] Создаем симлинк из /usr/sbin/tailscaled в /usr/bin/tailscaled${NC}\n"
        ln -sf /usr/sbin/tailscaled /usr/bin/tailscaled
        if [ $? -eq 0 ]; then
            printf "${GREEN}[OK] Симлинк успешно создан${NC}\n"
        else
            printf "${RED}[ERROR] Не удалось создать симлинк${NC}\n"
        fi
    elif [ -f /usr/bin/tailscaled ]; then
        printf "${GREEN}[OK] tailscaled уже существует в /usr/bin/${NC}\n"
    else
        printf "${YELLOW}[INFO] Бинарник tailscaled не найден${NC}\n"
    fi
    
    # Проверка существования tailscale CLI бинарника
    if [ -f /usr/sbin/tailscale ] && [ ! -f /usr/bin/tailscale ]; then
        printf "${YELLOW}[INFO] Создаем симлинк из /usr/sbin/tailscale в /usr/bin/tailscale${NC}\n"
        ln -sf /usr/sbin/tailscale /usr/bin/tailscale
        if [ $? -eq 0 ]; then
            printf "${GREEN}[OK] Симлинк для tailscale CLI успешно создан${NC}\n"
        else
            printf "${RED}[ERROR] Не удалось создать симлинк для tailscale CLI${NC}\n"
        fi
    elif [ -f /usr/bin/tailscale ]; then
        printf "${GREEN}[OK] tailscale CLI уже существует в /usr/bin/${NC}\n"
    else
        printf "${YELLOW}[INFO] Бинарник tailscale CLI не найден${NC}\n"
    fi
}

configure_network() {
    printf "${YELLOW}[INFO] Проверяем настройки сети...${NC}\n"
    
    # Проверка существования интерфейса tailscale в конфигурации сети
    if ! uci show network | grep -q "network.tailscale"; then
        printf "${YELLOW}[INFO] Добавляем интерфейс tailscale в конфигурацию сети...${NC}\n"
        
        # Добавление интерфейса tailscale в конфигурацию сети
        uci set network.tailscale=interface
        uci set network.tailscale.proto='none'
        uci set network.tailscale.device='tailscale0'
        uci set network.tailscale.delegate='0'
        
        uci commit network
        printf "${GREEN}[OK] Интерфейс tailscale добавлен в конфигурацию сети${NC}\n"
        
        # Перезагрузка сети для применения изменений
        printf "${YELLOW}[INFO] Перезагружаем сеть...${NC}\n"
        /etc/init.d/network reload
        sleep 3
    else
        printf "${GREEN}[OK] Интерфейс tailscale уже есть в конфигурации сети${NC}\n"
    fi
}

configure_firewall() {
    printf "${YELLOW}[INFO] Проверяем настройки фаервола...${NC}\n"
    
    # Настройка сетевого интерфейса
    configure_network
    
    # Проверка существования зоны фаервола
    if ! uci show firewall | grep -q "zone.*tailscale"; then
        printf "${YELLOW}[INFO] Добавляем зону Tailscale в фаервол...${NC}\n"
        
        # Добавление зоны в фаервол (дефолтные настройки из luci)
        uci add firewall zone
        uci set firewall.@zone[-1].name='tailscale'
        uci set firewall.@zone[-1].input='ACCEPT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].forward='ACCEPT'
        uci set firewall.@zone[-1].masq='1'
        uci set firewall.@zone[-1].mtu_fix='1'
        uci set firewall.@zone[-1].network='tailscale'
        
        # Добавление перенаправлений (дефолтные настройки из luci)
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='tailscale'
        uci set firewall.@forwarding[-1].dest='lan'
        
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].dest='tailscale'
        
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='tailscale'
        uci set firewall.@forwarding[-1].dest='wan'
        
        uci commit firewall
        printf "${GREEN}[OK] Настройки фаервола добавлены${NC}\n"
        
        # Перезапуск фаервола для применения изменений
        printf "${YELLOW}[INFO] Перезапускаем фаервол...${NC}\n"
        /etc/init.d/firewall restart
        sleep 2
    else
        printf "${GREEN}[OK] Настройки фаервола для Tailscale уже существуют${NC}\n"
        
        # Проверка, что сеть правильно установлена в зоне
        ZONE_CONFIG=$(uci show firewall | grep "zone.*tailscale" | cut -d'=' -f1 | cut -d'.' -f1-2)
        if [ -n "$ZONE_CONFIG" ]; then
            ZONE_NETWORK=$(uci get $ZONE_CONFIG.network 2>/dev/null)
            if [ "$ZONE_NETWORK" != "tailscale" ]; then
                printf "${YELLOW}[INFO] Обновляем настройки зоны tailscale...${NC}\n"
                uci set $ZONE_CONFIG.network='tailscale'
                uci commit firewall
                /etc/init.d/firewall restart
                sleep 2
            fi
        fi
    fi
}

verify_configuration() {
    printf "${YELLOW}[INFO] Проверяем конфигурацию...${NC}\n"
    
    # Проверка конфигурации сети
    printf "${CYAN}1. Проверка конфигурации сети:${NC}\n"
    if uci show network.tailscale >/dev/null 2>&1; then
        printf "${GREEN}[OK] Интерфейс tailscale в конфигурации сети${NC}\n"
        uci show network.tailscale
    else
        printf "${RED}[ERROR] Интерфейс tailscale отсутствует в конфигурации сети${NC}\n"
    fi
    
    # Проверка конфигурации фаервола
    printf "${CYAN}2. Проверка конфигурации фаервола:${NC}\n"
    if uci show firewall | grep -q "zone.*tailscale"; then
        printf "${GREEN}[OK] Зона tailscale в конфигурации фаервола${NC}\n"
        ZONE_CONFIG=$(uci show firewall | grep "zone.*tailscale" | cut -d'=' -f1 | cut -d'.' -f1-2)
        uci show $ZONE_CONFIG
    else
        printf "${RED}[ERROR] Зона tailscale отсутствует в конфигурации фаервола${NC}\n"
    fi
    
    # Проверка видимости в системе
    printf "${CYAN}3. Проверка видимости в системе:${NC}\n"
    if ubus list network.interface.tailscale >/dev/null 2>&1; then
        printf "${GREEN}[OK] Интерфейс tailscale виден в системе${NC}\n"
    else
        printf "${YELLOW}[WARNING] Интерфейс tailscale может не отображаться в веб-интерфейсе${NC}\n"
        printf "${YELLOW}Попробуйте перезагрузить устройство${NC}\n"
    fi
}

get_network_info() {
    printf "${YELLOW}[INFO] Определяем сетевые настройки...${NC}\n"
    
    # Получение подсети роутера для команды (например, 192.168.1.0/24)
    ROUTER_SUBNET=$(uci get network.lan.ipaddr 2>/dev/null | cut -d. -f1-3)
    if [ -n "$ROUTER_SUBNET" ]; then
        ROUTER_SUBNET="${ROUTER_SUBNET}.0/24"
        printf "${GREEN}[OK] Подсеть роутера: $ROUTER_SUBNET${NC}\n"
    else
        printf "${RED}[ERROR] Не удалось определить подсеть роутера${NC}\n"
        return 1
    fi
    
    # Получение имени роутера для команды
    ROUTER_HOSTNAME=$(uci get system.@system[0].hostname 2>/dev/null)
    if [ -z "$ROUTER_HOSTNAME" ]; then
        ROUTER_HOSTNAME="routerich"
        printf "${YELLOW}[INFO] Используем hostname по умолчанию: $ROUTER_HOSTNAME${NC}\n"
    else
        printf "${GREEN}[OK] Hostname роутера: $ROUTER_HOSTNAME${NC}\n"
    fi
    
    return 0
}

setup_tailscale() {
    printf "${YELLOW}[INFO] Настраиваем Tailscale...${NC}\n"
    
    # Получение информации о сети
    if ! get_network_info; then
        printf "${RED}[ERROR] Не удалось получить сетевые настройки${NC}\n"
        return 1
    fi
    
    # Запрос ключа аутентификации
    printf "${YELLOW}[INFO] Введите ключ аутентификации Tailscale: ${NC}"
    read AUTH_KEY
    
    if [ -z "$AUTH_KEY" ]; then
        printf "${RED}[ERROR] Ключ аутентификации не может быть пустым${NC}\n"
        return 1
    fi
    
    # Сборка команды
    TAILSCALE_CMD="tailscale up --accept-routes --advertise-exit-node --advertise-routes=$ROUTER_SUBNET --hostname=$ROUTER_HOSTNAME --login-server=https://rc.routerich.ru/ --auth-key=$AUTH_KEY"
    
    printf "${CYAN}[INFO] Выполняем команду: $TAILSCALE_CMD${NC}\n"
    
    # Выполнение команды
    if $TAILSCALE_CMD; then
        printf "${GREEN}[OK] Tailscale успешно настроен${NC}\n"
        
        # Проверка статуса
        printf "${YELLOW}[INFO] Проверяем статус Tailscale...${NC}\n"
        tailscale status
        
        # Проверка tailscale0 интерфейса
        printf "${YELLOW}[INFO] Проверяем сетевой интерфейс...${NC}\n"
        if ip link show tailscale0 >/dev/null 2>&1 || ifconfig tailscale0 >/dev/null 2>&1; then
            printf "${GREEN}[OK] Сетевой интерфейс tailscale0 создан${NC}\n"
            ifconfig tailscale0 | grep -E "(inet|RX|TX)"
        else
            printf "${RED}[ERROR] Сетевой интерфейс tailscale0 не найден${NC}\n"
        fi
        
        # Проверка конфигурации
        verify_configuration
        
        # Возможные инструкции
        printf "${PURPLE}\n=== ИНСТРУКЦИЯ ===${NC}\n"
        printf "${CYAN}Чтобы пускать трафик через Podkop, посмотрите инструкцию по ссылке:${NC}\n"
        printf "${CYAN}https://docs.routerich.ru/ru/remote в разделе ExitNode${NC}\n"
        printf "${CYAN}Панель управления доступна по ссылке:${NC}\n"
        printf "${CYAN}https://remote.routerich.ru/dashboard${NC}\n"
        printf "${PURPLE}=================${NC}\n"
        
        # Установка флага завершения установки
        TAILSCALE_SETUP_COMPLETED=1
        
    else
        printf "${RED}[ERROR] Не удалось настроить Tailscale${NC}\n"
        return 1
    fi
    
    return 0
}

install_tailscale() {
    printf "${YELLOW}[INFO] Устанавливаем Tailscale...${NC}\n"
    
    # Обновление списка пакетов
    printf "${YELLOW}[INFO] Обновляем список пакетов...${NC}\n"
    opkg update
    
    if opkg install tailscale; then
        printf "${GREEN}[OK] Tailscale успешно установлен${NC}\n"
        
        # Создание симлинков после установки
        create_tailscale_symlink
        
        # Настройка фаервола
        configure_firewall
        
        # Запрос на запуск
        printf "${YELLOW}[INFO] Запускаем и включаем сервис Tailscale? (y/n): ${NC}"
        read start_service
        case $start_service in
            [Yy]* )
                /etc/init.d/tailscale start
                /etc/init.d/tailscale enable
                printf "${GREEN}[OK] Сервис Tailscale запущен и включен${NC}\n"
                
                # Ожидание запуска
                sleep 5
                
                # Проверка статуса
                if /etc/init.d/tailscale running; then
                    printf "${GREEN}[OK] Сервис Tailscale работает${NC}\n"
                    
                    # Установка
                    setup_tailscale
                else
                    printf "${RED}[ERROR] Сервис Tailscale не запустился${NC}\n"
                fi
                ;;
            * )
                printf "${YELLOW}[INFO] Вы можете запустить Tailscale позже: /etc/init.d/tailscale start${NC}\n"
                printf "${YELLOW}[INFO] И затем настроить его вручную${NC}\n"
                ;;
        esac
    else
        printf "${RED}[ERROR] Не удалось установить Tailscale${NC}\n"
    fi
}

remove_tailscale() {
    printf "${YELLOW}[INFO] Начинаем удаление Tailscale...${NC}\n"
    
    # Удаление всех пакетов из списка tailscale*
    for pkg in $PACKAGES; do
        remove_package $pkg
    done

    # Очистка возможных конфигов
    printf "${YELLOW}[INFO] Очищаем конфигурационные файлы...${NC}\n"
    rm -rf /etc/tailscale 2>/dev/null && printf "${GREEN}[OK] Удален /etc/tailscale${NC}\n"
    rm -rf /etc/config/tailscale 2>/dev/null && printf "${GREEN}[OK] Удален /etc/config/tailscale${NC}\n"
    rm -f /etc/init.d/tailscale 2>/dev/null && printf "${GREEN}[OK] Удален /etc/init.d/tailscale${NC}\n"

    # Удаление интерфейса из конфигурации сети
    printf "${YELLOW}[INFO] Удаляем интерфейс из конфигурации сети...${NC}\n"
    uci delete network.tailscale 2>/dev/null && uci commit network && printf "${GREEN}[OK] Интерфейс tailscale удален из конфигурации сети${NC}\n"

    printf "\n${GREEN}[OK] Процесс удаления завершен${NC}\n"

    # Запрос на перезагрузку при удалении пакета
    if [ $PACKAGES_REMOVED -eq 1 ]; then
        printf "${YELLOW}[INFO] Рекомендуется перезагрузить устройство${NC}\n"
        printf "${YELLOW}[INFO] Перезагрузить сейчас? (y/n): ${NC}"
        read answer
        case $answer in
            [Yy]* )
                printf "${YELLOW}[INFO] Перезагружаем...${NC}\n"
                reboot
                ;;
            * )
                printf "${YELLOW}[INFO] Перезагрузка отменена${NC}\n"
                ;;
        esac
    fi
}

reconfigure_tailscale() {
    printf "${YELLOW}[INFO] Начинаем перенастройку Tailscale...${NC}\n"
    
    # Проверка, что Tailscale установлен
    if ! opkg list-installed | grep -q "^tailscale -"; then
        printf "${RED}[ERROR] Tailscale не установлен. Сначала установите Tailscale.${NC}\n"
        return 1
    fi
    
    # Создание симлинков
    create_tailscale_symlink
    
    # Настройка фаервола
    configure_firewall
    
    # Проверка, что сервис запущен
    if ! /etc/init.d/tailscale running; then
        printf "${YELLOW}[INFO] Запускаем сервис Tailscale...${NC}\n"
        /etc/init.d/tailscale start
        sleep 3
    fi
    
    # Установка
    setup_tailscale
}

full_reinstall() {
    printf "${YELLOW}[INFO] Начинаем полную переустановку Tailscale...${NC}\n"
    
    # Шаг 1: Удалить существующие пакеты
    remove_tailscale
    
    # Шаг 2: Установить и настроить
    if [ $PACKAGES_REMOVED -eq 1 ]; then
        printf "\n${BLUE}[INFO] Переходим к установке...${NC}\n"
        install_tailscale
    else
        printf "${YELLOW}[INFO] Пакеты не были удалены, установка не требуется${NC}\n"
    fi
}

# Главный скрипт
show_menu
read SELECTED_ACTION

case $SELECTED_ACTION in
    1)
        printf "\n${PURPLE}Выбрана полная переустановка${NC}\n"
        full_reinstall
        ;;
    2)
        printf "\n${PURPLE}Выбрана перенастройка${NC}\n"
        reconfigure_tailscale
        ;;
    3)
        printf "\n${PURPLE}Выбрано удаление${NC}\n"
        remove_tailscale
        ;;
    4)
        printf "\n${YELLOW}[INFO] Отмена выполнения скрипта${NC}\n"
        exit 0
        ;;
    *)
        printf "\n${RED}[ERROR] Неверный выбор. Введите число от 1 до 4.${NC}\n"
        exit 1
        ;;
esac

printf "\n${YELLOW}[INFO] Скрипт завершен${NC}\n"