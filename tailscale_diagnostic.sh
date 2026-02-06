#!/bin/sh
# tailscale_diagnostic.sh - Диагностика настроек Tailscale на OpenWrt

# --- ЦВЕТА ---
CLR_OFF="\033[0m"
RED="\033[1;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"

# --- НАСТРОЙКА ЛОГИРОВАНИЯ ---
LOG_FILE="/root/tailscale_diagnostic.log"
rm -f "$LOG_FILE"

clear

exec > >(tee -a "$LOG_FILE") 2>&1

echo "Диагностика Tailscale запущена: $(date '+%Y-%m-%d %H:%M:%S')"
printf "Лог сохраняется в: ${YELLOW}%s${CLR_OFF}\n" "$LOG_FILE"
echo "--------------------------------------------------------------"

# --- ПРОВЕРКА НАЛИЧИЯ TAILSCALE ---
if ! opkg list-installed | grep -q "^tailscale"; then
    printf "${RED}ОШИБКА: Tailscale не установлен!${CLR_OFF}\n"
    exit 1
fi

TS_CONFIG="/etc/config/tailscale"
if [ ! -f "$TS_CONFIG" ]; then
    printf "${RED}ОШИБКА: Файл конфигурации %s не найден!${CLR_OFF}\n" "$TS_CONFIG"
    exit 1
fi

# --- ПОЛУЧЕНИЕ ВЕРСИИ TAILSCALE ---
TS_VERSION=$(tailscale version 2>/dev/null | head -n1 | awk '{print $1}')
if [ -z "$TS_VERSION" ]; then
    TS_VERSION=$(opkg list-installed tailscale | awk '{print $3}')
fi

# Проверка статуса службы
if /etc/init.d/tailscale status 2>/dev/null | grep -q "running"; then
    TS_STATUS="${GREEN}RUNNING${CLR_OFF}"
    TS_RUNNING=1
else
    TS_STATUS="${RED}STOPPED${CLR_OFF}"
    TS_RUNNING=0
fi

# Проверка автозапуска
if [ -f /etc/rc.d/S*tailscale ] || [ -L /etc/rc.d/S*tailscale ]; then
    TS_AUTOSTART="${GREEN}РАЗРЕШЁН${CLR_OFF}"
else
    TS_AUTOSTART="${YELLOW}ОТКЛЮЧЕН${CLR_OFF}"
fi

echo ""
printf "= ИНФОРМАЦИЯ О TAILSCALE:\n"
printf "  Версия: ${CYAN}%-15s${CLR_OFF} | Статус: %b | Автозапуск: %b\n" "${TS_VERSION:-UNKNOWN}" "$TS_STATUS" "$TS_AUTOSTART"

echo ""
echo "= АНАЛИЗ КОНФИГУРАЦИИ /etc/config/tailscale:"
echo ""
echo "1. ОБЯЗАТЕЛЬНЫЕ ПАРАМЕТРЫ:"

# 1.1) enabled
ENABLED=$(uci -q get tailscale.settings.enabled)
if [ "$ENABLED" = "1" ]; then
    printf "  ${GREEN}[OK]${CLR_OFF}   %-30s | ${GREEN}%s${CLR_OFF}\n" "enabled" "1"
elif [ -z "$ENABLED" ]; then
    printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | ${RED}НЕ НАЙДЕН${CLR_OFF}\n" "enabled"
else
    printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | ${RED}%s${CLR_OFF} (должно быть 1)\n" "enabled" "$ENABLED"
fi

# 1.2) accept_dns (зависит от версии)
ACCEPT_DNS=$(uci -q get tailscale.settings.accept_dns)
EXPECTED_DNS="1"

if [ -n "$TS_VERSION" ]; then
    TS_VER_NUM=$(echo "$TS_VERSION" | sed 's/[^0-9.]//g')
    
    # Проверяем версию >= 1.92.5
    if [ "$(printf '%s\n' "$TS_VER_NUM" "1.92.5" | sort -V | tail -n1)" = "$TS_VER_NUM" ] && \
       [ "$TS_VER_NUM" != "1.92.4" ]; then
        EXPECTED_DNS="0"
    fi
fi

if [ "$ACCEPT_DNS" = "$EXPECTED_DNS" ]; then
    printf "  ${GREEN}[OK]${CLR_OFF}   %-30s | ${GREEN}%s${CLR_OFF}\n" "accept_dns" "$ACCEPT_DNS"
elif [ -z "$ACCEPT_DNS" ]; then
    printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | ${RED}НЕ НАЙДЕН${CLR_OFF} (должно быть %s)\n" "accept_dns" "$EXPECTED_DNS"
else
    printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | ${RED}%s${CLR_OFF} (должно быть %s)\n" "accept_dns" "$ACCEPT_DNS" "$EXPECTED_DNS"
fi

# 1.3) accept_routes
ACCEPT_ROUTES=$(uci -q get tailscale.settings.accept_routes)
if [ "$ACCEPT_ROUTES" = "1" ]; then
    printf "  ${GREEN}[OK]${CLR_OFF}   %-30s | ${GREEN}%s${CLR_OFF}\n" "accept_routes" "1"
elif [ -z "$ACCEPT_ROUTES" ]; then
    printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | ${RED}НЕ НАЙДЕН${CLR_OFF}\n" "accept_routes"
else
    printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | ${RED}%s${CLR_OFF} (должно быть 1)\n" "accept_routes" "$ACCEPT_ROUTES"
fi

# 1.4) hostname (если указан - проверяем формат)
HOSTNAME=$(uci -q get tailscale.settings.hostname)
if [ -n "$HOSTNAME" ]; then
    if echo "$HOSTNAME" | grep -qE '^[a-zA-Z0-9.-]+$'; then
        printf "  ${GREEN}[OK]${CLR_OFF}   %-30s | ${CYAN}%s${CLR_OFF}\n" "hostname" "$HOSTNAME"
    else
        printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | ${RED}%s${CLR_OFF}\n" "hostname" "$HOSTNAME"
        printf "         ${YELLOW}Недопустимые символы! Разрешены: a-z, A-Z, 0-9, '-', '.'${CLR_OFF}\n"
    fi
fi

echo ""
echo "2. ОПЦИОНАЛЬНЫЕ ПАРАМЕТРЫ:"

# 2.1) fw_mode
FW_MODE=$(uci -q get tailscale.settings.fw_mode)
if [ "$FW_MODE" = "nftables" ]; then
    printf "  ${GREEN}[ИНФО]${CLR_OFF} %-30s | ${CYAN}nftables${CLR_OFF}\n" "fw_mode"
elif [ "$FW_MODE" = "iptables" ]; then
    printf "  ${YELLOW}[ИНФО]${CLR_OFF} %-30s | ${CYAN}iptables${CLR_OFF}\n" "fw_mode"
elif [ -z "$FW_MODE" ]; then
    printf "  ${YELLOW}[ИНФО]${CLR_OFF} %-30s | ${YELLOW}не установлен${CLR_OFF} (по умолчанию nftables)\n" "fw_mode"
else
    printf "  ${YELLOW}[ИНФО]${CLR_OFF} %-30s | ${CYAN}%s${CLR_OFF}\n" "fw_mode" "$FW_MODE"
fi

# 2.2) log_stdout
LOG_STDOUT=$(uci -q get tailscale.settings.log_stdout)
if [ "$LOG_STDOUT" = "1" ]; then
    printf "  ${GREEN}[ИНФО]${CLR_OFF} %-30s | ${GREEN}включен${CLR_OFF}\n" "log_stdout"
else
    printf "  ${YELLOW}[ИНФО]${CLR_OFF} %-30s | ${YELLOW}выключен${CLR_OFF}\n" "log_stdout"
fi

# 2.3) log_stderr
LOG_STDERR=$(uci -q get tailscale.settings.log_stderr)
if [ "$LOG_STDERR" = "1" ]; then
    printf "  ${GREEN}[ИНФО]${CLR_OFF} %-30s | ${GREEN}включен${CLR_OFF}\n" "log_stderr"
else
    printf "  ${YELLOW}[ИНФО]${CLR_OFF} %-30s | ${YELLOW}выключен${CLR_OFF}\n" "log_stderr"
fi

# 2.4) disable_snat_subnet_routes
SNAT=$(uci -q get tailscale.settings.disable_snat_subnet_routes)
if [ "$SNAT" = "0" ]; then
    printf "  ${GREEN}[ИНФО]${CLR_OFF} %-30s | ${GREEN}SNAT включен${CLR_OFF}\n" "disable_snat_subnet_routes"
elif [ "$SNAT" = "1" ]; then
    printf "  ${YELLOW}[ИНФО]${CLR_OFF} %-30s | ${YELLOW}SNAT выключен${CLR_OFF}\n" "disable_snat_subnet_routes"
else
    printf "  ${YELLOW}[ИНФО]${CLR_OFF} %-30s | ${YELLOW}не установлен${CLR_OFF}\n" "disable_snat_subnet_routes"
fi

echo ""
echo "3. ПРОВЕРКА ВЫХОДНОГО УЗЛА (EXIT NODE):"

# 3.1) advertise_exit_node
EXIT_NODE=$(uci -q get tailscale.settings.advertise_exit_node)
if [ "$EXIT_NODE" = "1" ]; then
    printf "  ${GREEN}[OK]${CLR_OFF}   %-30s | ${GREEN}включен${CLR_OFF}\n" "advertise_exit_node"
    
    # 3.2) advertise_routes с проверкой подсети
    ADVERTISED_ROUTES=$(uci -q get tailscale.settings.advertise_routes)
    
    if [ -z "$ADVERTISED_ROUTES" ]; then
        printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | ${RED}не указаны${CLR_OFF}\n" "advertise_routes"
    else
        # Получаем подсеть роутера
        ROUTER_SUBNET=$(ip -4 route show dev br-lan 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | head -n1)
        
        if [ -n "$ROUTER_SUBNET" ]; then
            # Сравниваем
            if echo "$ADVERTISED_ROUTES" | grep -qF "$ROUTER_SUBNET"; then
                printf "  ${GREEN}[OK]${CLR_OFF}   %-30s | ${CYAN}%s${CLR_OFF} ${GREEN}= %s (br-lan)${CLR_OFF}\n" "advertise_routes" "$ADVERTISED_ROUTES" "$ROUTER_SUBNET"
            else
                printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | ${CYAN}%s${CLR_OFF} ${RED}!= %s (br-lan)${CLR_OFF}\n" "advertise_routes" "$ADVERTISED_ROUTES" "$ROUTER_SUBNET"
            fi
        else
            # Если не удалось определить подсеть роутера - просто выводим advertise_routes
            printf "  ${GREEN}[OK]${CLR_OFF}   %-30s | ${CYAN}%s${CLR_OFF}\n" "advertise_routes" "$ADVERTISED_ROUTES"
            printf "  ${YELLOW}[ИНФО]${CLR_OFF} %-30s | ${YELLOW}не удалось определить${CLR_OFF}\n" "Подсеть роутера (br-lan)"
        fi
    fi
else
    printf "  ${YELLOW}[ИНФО]${CLR_OFF} %-30s | ${YELLOW}выключен${CLR_OFF}\n" "advertise_exit_node"
fi

echo ""
echo "= СТАТУС ПОДКЛЮЧЕНИЯ:"

# Проверка статуса через tailscale
if [ "$TS_RUNNING" = "1" ]; then
    TS_STATUS_OUTPUT=$(tailscale status 2>/dev/null)
    
    if [ $? -eq 0 ] && [ -n "$TS_STATUS_OUTPUT" ]; then
        printf "  ${GREEN}[OK]${CLR_OFF}   Tailscale: ${GREEN}подключен${CLR_OFF}\n"
        
        # IP адреса Tailscale
        TS_IP4=$(tailscale ip -4 2>/dev/null)
        TS_IP6=$(tailscale ip -6 2>/dev/null)
        
        if [ -n "$TS_IP4" ]; then
            printf "  IPv4: %s\n" "$TS_IP4"
        fi
        
        if [ -n "$TS_IP6" ]; then
            printf "  IPv6: %s\n" "$TS_IP6"
        fi
    else
        printf "  ${YELLOW}[ВНИМАНИЕ]${CLR_OFF} Tailscale запущен, но нет информации о подключении\n"
    fi
else
    printf "  ${RED}[КРИТ]${CLR_OFF} Tailscale: ${RED}не запущен${CLR_OFF}\n"
fi

echo ""
echo "= ДОПОЛНИТЕЛЬНЫЕ ПРОВЕРКИ:"

# Проверка интерфейса tailscale0
if [ -d "/sys/class/net/tailscale0" ]; then
    printf "  ${GREEN}[OK]${CLR_OFF}   Интерфейс tailscale0: ${GREEN}существует${CLR_OFF}\n"
else
    printf "  ${RED}[КРИТ]${CLR_OFF} Интерфейс tailscale0: ${RED}не найден${CLR_OFF}\n"
fi

# Проверка правил firewall (только кастомные)
FW_RULES_ALL=$(uci show firewall 2>/dev/null | grep -i tailscale)

if [ -n "$FW_RULES_ALL" ]; then
    # Фильтруем стандартные правила
    FW_RULES_CUSTOM=$(echo "$FW_RULES_ALL" | grep -v "firewall.tszone.name='tailscale'" | \
                      grep -v "firewall.tszone.device='tailscale+'" | \
                      grep -v "firewall.ts_ac_lan.src='tailscale'" | \
                      grep -v "firewall.ts_ac_wan.src='tailscale'" | \
                      grep -v "firewall.lan_ac_ts.dest='tailscale'")
    
    if [ -n "$FW_RULES_CUSTOM" ]; then
        printf "  ${GREEN}[ИНФО]${CLR_OFF} Найдены кастомные правила firewall для Tailscale:\n"
        echo "$FW_RULES_CUSTOM" | while read -r rule; do
            printf "    ${CYAN}%s${CLR_OFF}\n" "$rule"
        done
    fi
fi

echo ""
echo "--------------------------------------------------------------"
echo "Диагностика завершена: $(date '+%Y-%m-%d %H:%M:%S')"

# Очистка escape-последовательностей из лога
if [ -f "$LOG_FILE" ]; then
    sed -i 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$LOG_FILE"
fi
