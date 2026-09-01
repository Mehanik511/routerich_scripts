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
    TS_VERSION=$(opkg list-installed | grep -E "^tailscale(-lite)? " | awk '{print $3}' | head -n1)
fi

# --- ПОЛУЧЕНИЕ ВЕРСИИ LUCI-APP-TAILSCALE ---
# Схему параметров в /etc/config/tailscale задаёт веб-интерфейс, а не служба
LUCI_VERSION=$(opkg list-installed luci-app-tailscale 2>/dev/null | awk '{print $3}')
# Ревизию пакета (-r1) и суффиксы сборки отбрасываем: без этого дефис пропадает
# и версия склеивается (1.2.5-r1 -> 1.2.51, что "больше" 1.2.7)
LUCI_VER_NUM=$(echo "$LUCI_VERSION" | sed 's/-.*//; s/[^0-9.]//g')
TS_VER_NUM=$(echo "$TS_VERSION" | sed 's/-.*//; s/[^0-9.]//g')

# accept_dns заменён на dns_mode (UI: "DNS Mode") в службе с 1.102.0,
# в веб-интерфейсе — с 1.2.7 (у пакета LuCI собственная нумерация)
TS_VER_GE_1_102=0
LUCI_VER_GE_1_2_7=0
if [ -n "$TS_VER_NUM" ] && \
   [ "$(printf '%s\n' "$TS_VER_NUM" "1.102.0" | sort -V | tail -n1)" = "$TS_VER_NUM" ]; then
    TS_VER_GE_1_102=1
fi
if [ -n "$LUCI_VER_NUM" ] && \
   [ "$(printf '%s\n' "$LUCI_VER_NUM" "1.2.7" | sort -V | tail -n1)" = "$LUCI_VER_NUM" ]; then
    LUCI_VER_GE_1_2_7=1
fi

# Служба и веб-интерфейс должны быть по одну сторону порога
TS_LUCI_VER_MATCH=1
if [ -n "$TS_VER_NUM" ] && [ -n "$LUCI_VER_NUM" ] && \
   [ "$TS_VER_GE_1_102" != "$LUCI_VER_GE_1_2_7" ]; then
    TS_LUCI_VER_MATCH=0
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

if [ -z "$LUCI_VERSION" ]; then
    LUCI_VER_STATUS="${YELLOW}не установлен${CLR_OFF}"
elif [ "$TS_LUCI_VER_MATCH" = "0" ]; then
    LUCI_VER_STATUS="${YELLOW}расхождение версий${CLR_OFF}"
else
    LUCI_VER_STATUS="${GREEN}совместим со службой${CLR_OFF}"
fi
printf "  LuCI:   ${CYAN}%-15s${CLR_OFF} | Версии: %b\n" "${LUCI_VERSION:-UNKNOWN}" "$LUCI_VER_STATUS"

if [ "$TS_LUCI_VER_MATCH" = "0" ]; then
    printf "  ${YELLOW}[ИНФО]${CLR_OFF} Расхождение версий службы и веб-интерфейса: набор настроек может отличаться.\n"
    printf "         ${YELLOW}Обновите оба пакета до последней версии.${CLR_OFF}\n"
fi

echo ""
echo "= АНАЛИЗ КОНФИГУРАЦИИ /etc/config/tailscale:"
echo ""
echo "1. ОБЯЗАТЕЛЬНЫЕ ПАРАМЕТРЫ:"

# 1.1) enabled
ENABLED=$(uci -q get tailscale.settings.enabled)
if [ "$ENABLED" = "1" ]; then
    printf "  ${GREEN}[OK]${CLR_OFF}   %-30s | ${GREEN}%s${CLR_OFF} [%s]\n" "enabled" "1" "галочка \"Включить\""
elif [ -z "$ENABLED" ]; then
    printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | ${RED}НЕ НАЙДЕН${CLR_OFF} [%s]\n" "enabled" "галочка \"Включить\""
else
    printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | ${RED}%s${CLR_OFF} (должно быть 1) [%s]\n" "enabled" "$ENABLED" "галочка \"Включить\""
fi

# 1.2) accept_dns / dns_mode (зависит от версии)
ACCEPT_DNS=$(uci -q get tailscale.settings.accept_dns)
EXPECTED_DNS="1"
TS_VER_GE_1_92_5=0

# Проверяем версию службы >= 1.92.5
if [ -n "$TS_VER_NUM" ] && \
   [ "$(printf '%s\n' "$TS_VER_NUM" "1.92.5" | sort -V | tail -n1)" = "$TS_VER_NUM" ] && \
   [ "$TS_VER_NUM" != "1.92.4" ]; then
    TS_VER_GE_1_92_5=1
fi

# Какой параметр реально лежит в конфиге, определяет тот, кто его пишет:
# веб-интерфейс, а при его отсутствии — версия службы
if [ -n "$LUCI_VER_NUM" ]; then
    CFG_USE_DNS_MODE="$LUCI_VER_GE_1_2_7"
else
    CFG_USE_DNS_MODE="$TS_VER_GE_1_102"
fi

# С версии 1.92.5 ожидаемое значение accept_dns изменилось на 0
if [ "$TS_VER_GE_1_92_5" = "1" ]; then
    EXPECTED_DNS="0"
fi

if [ "$CFG_USE_DNS_MODE" = "1" ]; then
    # Новая схема: dns_mode = disabled | magicdns | dnsmasq. Валиден только disabled
    DNS_MODE=$(uci -q get tailscale.settings.dns_mode)
    if [ "$DNS_MODE" = "disabled" ]; then
        printf "  ${GREEN}[OK]${CLR_OFF}   %-30s | ${GREEN}%s${CLR_OFF} [%s]\n" "dns_mode" "$DNS_MODE" "настройка \"DNS Mode\""
    elif [ -z "$DNS_MODE" ]; then
        printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | ${RED}НЕ НАЙДЕН${CLR_OFF} (должно быть %s) [%s]\n" "dns_mode" "disabled" "настройка \"DNS Mode\""
    else
        printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | ${RED}%s${CLR_OFF} (должно быть %s) [%s]\n" "dns_mode" "$DNS_MODE" "disabled" "настройка \"DNS Mode\""
    fi
elif [ "$ACCEPT_DNS" = "$EXPECTED_DNS" ]; then
    printf "  ${GREEN}[OK]${CLR_OFF}   %-30s | ${GREEN}%s${CLR_OFF} [%s]\n" "accept_dns" "$ACCEPT_DNS" "галочка \"Принимать DNS\""
elif [ -z "$ACCEPT_DNS" ]; then
    printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | ${RED}НЕ НАЙДЕН${CLR_OFF} (должно быть %s) [%s]\n" "accept_dns" "$EXPECTED_DNS" "галочка \"Принимать DNS\""
else
    printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | ${RED}%s${CLR_OFF} (должно быть %s) [%s]\n" "accept_dns" "$ACCEPT_DNS" "$EXPECTED_DNS" "галочка \"Принимать DNS\""
fi

# 1.3) accept_routes
ACCEPT_ROUTES=$(uci -q get tailscale.settings.accept_routes)
if [ "$ACCEPT_ROUTES" = "1" ]; then
    printf "  ${GREEN}[OK]${CLR_OFF}   %-30s | ${GREEN}%s${CLR_OFF} [%s]\n" "accept_routes" "1" "галочка \"Принимать маршруты\""
elif [ -z "$ACCEPT_ROUTES" ]; then
    printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | ${RED}НЕ НАЙДЕН${CLR_OFF} [%s]\n" "accept_routes" "галочка \"Принимать маршруты\""
else
    printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | ${RED}%s${CLR_OFF} (должно быть 1) [%s]\n" "accept_routes" "$ACCEPT_ROUTES" "галочка \"Принимать маршруты\""
fi

# 1.4) hostname (если указан - проверяем формат)
HOSTNAME=$(uci -q get tailscale.settings.hostname)
if [ -n "$HOSTNAME" ]; then
    if echo "$HOSTNAME" | grep -qE '^[a-zA-Z0-9.-]+$'; then
        printf "  ${GREEN}[OK]${CLR_OFF}   %-30s | ${CYAN}%s${CLR_OFF} [%s]\n" "hostname" "$HOSTNAME" "поле \"Имя устройства\""
    else
        printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | ${RED}%s${CLR_OFF} [%s]\n" "hostname" "$HOSTNAME" "поле \"Имя устройства\""
        printf "         ${YELLOW}Недопустимые символы! Разрешены: a-z, A-Z, 0-9, '-', '.'${CLR_OFF}\n"
    fi
fi

# 1.5) auth-key
AUTHKEY=$(uci -q get tailscale.settings.authkey)
if [ -n "$AUTHKEY" ]; then
    printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | ${RED}%s${CLR_OFF} [%s]\n" "authkey" "Введён ключ!" "поле \"Ключ авторизации\""
        printf "         ${YELLOW}Поле необходимо оставить пустым!${CLR_OFF}\n"
fi

echo ""
echo "2. ОПЦИОНАЛЬНЫЕ ПАРАМЕТРЫ:"

# 2.1) fw_mode
FW_MODE=$(uci -q get tailscale.settings.fw_mode)
if [ "$FW_MODE" = "nftables" ]; then
    printf "  ${GREEN}[ИНФО]${CLR_OFF} %-30s | ${CYAN}nftables${CLR_OFF} [%s]\n" "fw_mode" "настройка \"Режим межсетевого экрана\""
elif [ "$FW_MODE" = "iptables" ]; then
    printf "  ${YELLOW}[ИНФО]${CLR_OFF} %-30s | ${CYAN}iptables${CLR_OFF} [%s]\n" "fw_mode" "настройка \"Режим межсетевого экрана\""
elif [ -z "$FW_MODE" ]; then
    printf "  ${YELLOW}[ИНФО]${CLR_OFF} %-30s | ${YELLOW}не установлен${CLR_OFF} (по умолчанию nftables) [%s]\n" "fw_mode" "настройка \"Режим межсетевого экрана\""
else
    printf "  ${YELLOW}[ИНФО]${CLR_OFF} %-30s | ${CYAN}%s${CLR_OFF} [%s]\n" "fw_mode" "$FW_MODE" "настройка \"Режим межсетевого экрана\""
fi

# 2.2) log_stdout
LOG_STDOUT=$(uci -q get tailscale.settings.log_stdout)
if [ "$LOG_STDOUT" = "1" ]; then
    printf "  ${GREEN}[ИНФО]${CLR_OFF} %-30s | ${GREEN}включен${CLR_OFF} [%s]\n" "log_stdout" "галочка \"Журнал вывода\""
else
    printf "  ${YELLOW}[ИНФО]${CLR_OFF} %-30s | ${YELLOW}выключен${CLR_OFF} [%s]\n" "log_stdout" "галочка \"Журнал вывода\""
fi

# 2.3) log_stderr
LOG_STDERR=$(uci -q get tailscale.settings.log_stderr)
if [ "$LOG_STDERR" = "1" ]; then
    printf "  ${GREEN}[ИНФО]${CLR_OFF} %-30s | ${GREEN}включен${CLR_OFF} [%s]\n" "log_stderr" "галочка \"Журнал ошибок\""
else
    printf "  ${YELLOW}[ИНФО]${CLR_OFF} %-30s | ${YELLOW}выключен${CLR_OFF} [%s]\n" "log_stderr" "галочка \"Журнал ошибок\""
fi

# 2.4) disable_snat_subnet_routes
SNAT=$(uci -q get tailscale.settings.disable_snat_subnet_routes)
# С версии 1.102.0 при включённом exit node значение должно быть 0,
# иначе веб-интерфейс роутера сообщает о неверных настройках
EXIT_NODE=$(uci -q get tailscale.settings.advertise_exit_node)
if [ "$CFG_USE_DNS_MODE" = "1" ] && [ "$EXIT_NODE" = "1" ]; then
    if [ "$SNAT" = "1" ]; then
        printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | ${RED}SNAT выключен${CLR_OFF} (должно быть 0 при включённом узле выхода) [%s]\n" "disable_snat_subnet_routes" "CLI флаг"
    elif [ -z "$SNAT" ]; then
        printf "  ${GREEN}[OK]${CLR_OFF}   %-30s | ${GREEN}не установлен (= 0, SNAT включен)${CLR_OFF} [%s]\n" "disable_snat_subnet_routes" "CLI флаг"
    else
        printf "  ${GREEN}[OK]${CLR_OFF}   %-30s | ${GREEN}SNAT включен${CLR_OFF} [%s]\n" "disable_snat_subnet_routes" "CLI флаг"
    fi
elif [ "$SNAT" = "0" ]; then
    printf "  ${GREEN}[ИНФО]${CLR_OFF} %-30s | ${GREEN}SNAT включен${CLR_OFF} [%s]\n" "disable_snat_subnet_routes" "CLI флаг"
elif [ "$SNAT" = "1" ]; then
    printf "  ${YELLOW}[ИНФО]${CLR_OFF} %-30s | ${YELLOW}SNAT выключен${CLR_OFF} [%s]\n" "disable_snat_subnet_routes" "CLI флаг"
else
    printf "  ${YELLOW}[ИНФО]${CLR_OFF} %-30s | ${YELLOW}не установлен${CLR_OFF} [%s]\n" "disable_snat_subnet_routes" "CLI флаг"
fi

echo ""
echo "3. ПРОВЕРКА EXIT NODE:"

# 3.1) advertise_exit_node
EXIT_NODE=$(uci -q get tailscale.settings.advertise_exit_node)
if [ "$EXIT_NODE" = "1" ]; then
    printf "  ${GREEN}[OK]${CLR_OFF}   %-30s | ${GREEN}включен${CLR_OFF} [%s]\n" "advertise_exit_node" "галочка \"Узел выхода\""
    
    # 3.2) advertise_routes с проверкой подсети
    ADVERTISED_ROUTES=$(uci -q get tailscale.settings.advertise_routes)
    
    if [ -z "$ADVERTISED_ROUTES" ]; then
        printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | ${RED}не указаны${CLR_OFF} [%s]\n" "advertise_routes" "галочка \"Узел выхода\""
    else
        # Получаем подсеть роутера
        ROUTER_SUBNET=$(ip -4 route show dev br-lan 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | head -n1)
        
        if [ -n "$ROUTER_SUBNET" ]; then
            # Сравниваем
            if echo "$ADVERTISED_ROUTES" | grep -qF "$ROUTER_SUBNET"; then
                printf "  ${GREEN}[OK]${CLR_OFF}   %-30s | ${CYAN}%s${CLR_OFF} ${GREEN}= %s (br-lan)${CLR_OFF} [%s]\n" "advertise_routes" "$ADVERTISED_ROUTES" "$ROUTER_SUBNET" "настройка \"Открыть подсети\""
            else
                printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | ${CYAN}%s${CLR_OFF} ${RED}!= %s (br-lan)${CLR_OFF} [%s]\n" "advertise_routes" "$ADVERTISED_ROUTES" "$ROUTER_SUBNET" "настройка \"Открыть подсети\""
            fi
        else
            # Если не удалось определить подсеть роутера - просто выводим advertise_routes
            printf "  ${GREEN}[OK]${CLR_OFF}   %-30s | ${CYAN}%s${CLR_OFF} [%s]\n" "advertise_routes" "$ADVERTISED_ROUTES" "настройка \"Открыть подсети"
            printf "  ${YELLOW}[ИНФО]${CLR_OFF} %-30s | ${YELLOW}не удалось определить${CLR_OFF} [%s]\n" "Подсеть роутера (br-lan)"
        fi
    fi
else
    printf "  ${YELLOW}[ИНФО]${CLR_OFF} %-30s | ${YELLOW}выключен${CLR_OFF} [%s]\n" "advertise_exit_node" "галочка \"Узел выхода\""
fi

# 3.3) Проверка zeroblock и podkop (интерфейсы)
# 3.3.1) zeroblock
if [ -f "/etc/init.d/zeroblock" ]; then
	# Определяем версию zeroblock (новые версии 0.8+ используют секцию engine)
	ZB_USE_ENGINE=0
	ZB_VERSION=$(/etc/init.d/zeroblock --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1)
	if [ -n "$ZB_VERSION" ]; then
		ZB_MAJOR=${ZB_VERSION%%.*}   # всё до первой точки
		ZB_MINOR=${ZB_VERSION#*.}     # всё после первой точки
		# Для версий 0.8+ или 1.x используем engine, для 0.1-0.7 оставляем settings
		if { [ "$ZB_MAJOR" -eq 0 ] && [ "$ZB_MINOR" -ge 8 ]; } || [ "$ZB_MAJOR" -ge 1 ]; then
			ZB_USE_ENGINE=1
		fi
	fi

	# Получаем список интерфейсов из соответствующей секции (с fallback)
	# Если не удалось определить версию, пытаемся engine (как более вероятный для новых)
	# иначе если settings пуст – тоже engine
	if [ "$ZB_USE_ENGINE" -eq 1 ] || ! uci -q get zeroblock.settings.source_network_interfaces >/dev/null; then
		ZB_INT=$(uci -q get zeroblock.engine.source_network_interfaces 2>/dev/null | sed "s/'//g" | tr ' ' ',')
	else
		ZB_INT=$(uci -q get zeroblock.settings.source_network_interfaces | sed "s/'//g" | tr ' ' ',')
	fi

	# --- Проверка статуса и вывод ---
	ZB_STATUS=$(/etc/init.d/zeroblock status 2>&1)
	if [ "$EXIT_NODE" = "1" ]; then
		if echo "$ZB_INT" | grep -q "tailscale0"; then
			printf "  ${GREEN}[OK]${CLR_OFF}   %-30s | интерфейсы ${CYAN}%s${CLR_OFF} [%s]\n" "zeroblock ($ZB_STATUS)" "$ZB_INT" "настройка \"Входящие интерфейсы/устройства\""
		else
			printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | интерфейсы ${RED}%s${CLR_OFF} [%s]\n" "zeroblock ($ZB_STATUS)" "$ZB_INT" "настройка \"Входящие интерфейсы/устройства\""
			printf "         ${YELLOW}Для работы exit node интерфейс tailscale0 должен быть выбран в настройках %s${CLR_OFF}\n" "zeroblock"
		fi
	fi
fi

# 3.3.2) podkop
if [ -f "/etc/init.d/podkop" ]; then
    PK_INT=$(uci -q get podkop.settings.source_network_interfaces | sed "s/'//g" | tr ' ' ',')
    PK_STATUS=$(/etc/init.d/podkop status 2>&1)
	if [ "$EXIT_NODE" = "1" ]; then
		if echo "$PK_INT" | grep -q "tailscale0"; then
			printf "  ${GREEN}[OK]${CLR_OFF}   %-30s | интерфейсы ${CYAN}%s${CLR_OFF} [%s]\n" "podkop ($PK_STATUS)" "$PK_INT" "настройка \"Интерфейс источника\""
		else
			printf "  ${RED}[КРИТ]${CLR_OFF} %-30s | интерфейсы ${RED}%s${CLR_OFF} [%s]\n" "podkop ($PK_STATUS)" "$PK_INT" "настройка \"Интерфейс источника\""
			printf "         ${YELLOW}Для работы exit node интерфейс tailscale0 должен быть выбран в настройках %s${CLR_OFF}\n" "podkop"
		fi
	fi
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
