#!/bin/bash

# ╔══════════════════════════════════════════════════════════════╗
# ║              VPN Setup Script v2.0                          ║
# ║         VLESS + Reality + xtls-rprx-vision                  ║
# ║  Умный скрипт: установка, бэкап, откат, проверка связи      ║
# ╚══════════════════════════════════════════════════════════════╝

# ─── Цвета ───────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ─── Константы ───────────────────────────────────────────────
DB="/etc/x-ui/x-ui.db"
XUI_BIN="/usr/local/x-ui/x-ui"
GEO_DIR="/usr/local/x-ui/bin"
BACKUP_DIR="/root/backups"
BACKUP_KEEP=5   # сколько бэкапов хранить
SCRIPT_VERSION="2.2"

# ─── Вывод ───────────────────────────────────────────────────
print_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║           VPN Setup Script v$SCRIPT_VERSION                    ║"
    echo "║      VLESS + Reality + xtls-rprx-vision             ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_step()    { echo -e "\n${BLUE}[►]${NC} $1"; }
print_ok()      { echo -e "${GREEN}[✓]${NC} $1"; }
print_error()   { echo -e "${RED}[✗]${NC} $1"; }
print_info()    { echo -e "${YELLOW}[i]${NC} $1"; }
print_warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
print_section() { echo -e "\n${MAGENTA}━━━ $1 ━━━${NC}"; }

# ─── Проверка root ───────────────────────────────────────────
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Запустите скрипт от имени root: sudo su"
        exit 1
    fi
}

# ══════════════════════════════════════════════════════════════
# БЭКАП И ОТКАТ
# ══════════════════════════════════════════════════════════════

# Создаёт бэкап всего что нужно, удаляет старые
do_backup() {
    local reason="${1:-manual}"
    mkdir -p "$BACKUP_DIR"
    local ts
    ts=$(date +%Y-%m-%d_%H-%M)
    local prefix="$BACKUP_DIR/${ts}_${reason}"

    print_step "Создание бэкапа ($reason)..."

    # x-ui база данных
    if [ -f "$DB" ]; then
        cp "$DB" "${prefix}_xui.db"
        print_ok "БД x-ui → ${prefix}_xui.db"
    fi

    # AdGuard конфиг
    if [ -f /opt/AdGuardHome/AdGuardHome.yaml ]; then
        cp /opt/AdGuardHome/AdGuardHome.yaml "${prefix}_adguard.yaml"
        print_ok "AdGuard → ${prefix}_adguard.yaml"
    fi

    # Xray шаблон (если есть отдельный файл)
    if [ -f "$GEO_DIR/config.json" ]; then
        cp "$GEO_DIR/config.json" "${prefix}_xray.json"
    fi

    # Сохраняем путь к последнему бэкапу для отката
    echo "${prefix}" > /tmp/vpn_last_backup

    # Удаляем старые бэкапы — оставляем BACKUP_KEEP последних комплектов
    ls -t "$BACKUP_DIR"/*_xui.db 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | while read -r f; do
        base="${f%_xui.db}"
        rm -f "${base}_xui.db" "${base}_adguard.yaml" "${base}_xray.json"
        print_info "Удалён старый бэкап: $(basename "$base")"
    done

    print_ok "Бэкап создан: $prefix"
}

# Откат к последнему бэкапу
do_rollback() {
    print_section "ОТКАТ К ПРЕДЫДУЩЕМУ СОСТОЯНИЮ"

    # Ищем последний бэкап
    local last_backup
    if [ -f /tmp/vpn_last_backup ]; then
        last_backup=$(cat /tmp/vpn_last_backup)
    else
        last_backup=$(ls -t "$BACKUP_DIR"/*_xui.db 2>/dev/null | head -1)
        last_backup="${last_backup%_xui.db}"
    fi

    if [ -z "$last_backup" ] || [ ! -f "${last_backup}_xui.db" ]; then
        print_error "Бэкапов не найдено в $BACKUP_DIR"
        return 1
    fi

    print_info "Откат к: $(basename "$last_backup")"
    echo -e "${YELLOW}Продолжить? (y/n)${NC}"
    read -r confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { print_info "Откат отменён"; return 0; }

    # Останавливаем x-ui, восстанавливаем БД, затем запускаем — строго по порядку
    systemctl stop x-ui 2>/dev/null; sleep 1

    # Восстанавливаем БД
    cp "${last_backup}_xui.db" "$DB"
    print_ok "БД x-ui восстановлена"

    # Восстанавливаем AdGuard если есть
    if [ -f "${last_backup}_adguard.yaml" ]; then
        cp "${last_backup}_adguard.yaml" /opt/AdGuardHome/AdGuardHome.yaml
        systemctl restart AdGuardHome 2>/dev/null
        print_ok "AdGuard конфиг восстановлен"
    fi

    nohup systemctl start x-ui > /tmp/xui_restart.log 2>&1 &
    sleep 3

    if systemctl is-active --quiet x-ui; then
        print_ok "x-ui запущен успешно после отката"
    else
        print_error "x-ui не запустился даже после отката! Проверьте вручную:"
        echo "  journalctl -u x-ui -n 30"
    fi
}

# Автооткат — вызывается если x-ui не запустился после изменений
auto_rollback_if_failed() {
    local attempts=0
    print_step "Проверка запуска x-ui..."
    while [ $attempts -lt 5 ]; do
        sleep 2
        if systemctl is-active --quiet x-ui; then
            print_ok "x-ui работает"
            return 0
        fi
        attempts=$((attempts + 1))
        print_warn "x-ui не отвечает, ожидание... ($attempts/5)"
    done

    print_error "x-ui не запустился за 10 секунд — запускаем АВТООТКАТ!"

    local last_backup
    last_backup=$(cat /tmp/vpn_last_backup 2>/dev/null)
    if [ -n "$last_backup" ] && [ -f "${last_backup}_xui.db" ]; then
        systemctl stop x-ui 2>/dev/null; sleep 1
        cp "${last_backup}_xui.db" "$DB"
        nohup systemctl start x-ui > /tmp/xui_restart.log 2>&1 &
        sleep 3
        if systemctl is-active --quiet x-ui; then
            print_ok "Автооткат успешен — x-ui восстановлен"
        else
            print_error "Критическая ошибка! x-ui не запустился даже после отката"
            echo -e "${RED}Проверьте вручную: journalctl -u x-ui -n 50${NC}"
        fi
    else
        print_error "Нет бэкапа для отката!"
    fi
    return 1
}

# ══════════════════════════════════════════════════════════════
# УСТАНОВКА КОМПОНЕНТОВ
# ══════════════════════════════════════════════════════════════

check_and_install_3xui() {
    print_step "Проверка 3x-ui..."
    apt-get install -y curl sqlite3 python3 > /dev/null 2>&1

    if systemctl is-active --quiet x-ui; then
        print_ok "3x-ui уже запущен — пропускаем установку"
        XUI_EXISTED=true
        return
    fi

    if [ -f "$XUI_BIN" ]; then
        print_info "3x-ui установлен но не запущен — запускаем"
        systemctl start x-ui; sleep 3
        if systemctl is-active --quiet x-ui; then
            print_ok "3x-ui запущен"
            XUI_EXISTED=true
            return
        fi
        print_warn "Не удалось запустить — переустанавливаем"
    else
        print_info "3x-ui не найден — устанавливаем с нуля"
    fi

    XUI_EXISTED=false
    apt-get update -qq
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) << 'INSTALL_EOF'
y
8080
INSTALL_EOF
    sleep 5

    if systemctl is-active --quiet x-ui; then
        print_ok "3x-ui установлен и запущен"
    else
        print_error "Ошибка установки 3x-ui!"
        exit 1
    fi
}

check_and_install_adguard() {
    print_step "Проверка AdGuard Home..."

    if systemctl is-active --quiet AdGuardHome; then
        print_ok "AdGuard Home уже запущен"
        ADGUARD_EXISTED=true
        return
    fi

    if [ -f /opt/AdGuardHome/AdGuardHome ]; then
        print_info "AdGuard установлен но не запущен — запускаем"
        systemctl start AdGuardHome; sleep 2
        if systemctl is-active --quiet AdGuardHome; then
            print_ok "AdGuard запущен"
            ADGUARD_EXISTED=true
            return
        fi
        print_warn "Не удалось запустить — переустанавливаем"
    else
        print_info "AdGuard Home не найден — устанавливаем"
    fi

    ADGUARD_EXISTED=false

    curl -sL --max-time 60 "https://static.adguard.com/adguardhome/release/AdGuardHome_linux_amd64.tar.gz" -o /tmp/adguard.tar.gz
    tar -xzf /tmp/adguard.tar.gz -C /tmp/
    mkdir -p /opt/AdGuardHome
    cp /tmp/AdGuardHome/AdGuardHome /opt/AdGuardHome/
    chmod +x /opt/AdGuardHome/AdGuardHome
    /opt/AdGuardHome/AdGuardHome -s install > /dev/null 2>&1
    sleep 2

    cat > /opt/AdGuardHome/AdGuardHome.yaml << 'ADGEOF'
http:
  address: 0.0.0.0:80
  session_ttl: 720h
users:
  - name: admin
    password: $2y$10$sMBU7PYyTMnNXFzUQGKxuuLYF3h9Yc4ZPvqLQvtTf2vFpWmSGsHq
auth_attempts: 5
block_auth_min: 15
dns:
  bind_hosts:
    - 0.0.0.0
  port: 5353
  upstream_dns:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
  bootstrap_dns:
    - 1.1.1.1
    - 8.8.8.8
  filtering_enabled: true
  filters_update_interval: 24
filters:
  - enabled: true
    url: https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://blocklistproject.github.io/Lists/ads.txt
    name: BlocklistProject Ads
    id: 2
log_file: ""
verbose: false
ADGEOF

    systemctl restart AdGuardHome; sleep 2
    if systemctl is-active --quiet AdGuardHome; then
        print_ok "AdGuard Home установлен (пароль будет задан через пункт 10)"
    else
        print_error "AdGuard не запустился — настройте вручную"
    fi
    rm -f /tmp/adguard.tar.gz
}

configure_adguard_dns_in_xui() {
    print_step "DNS в 3x-ui → AdGuard (127.0.0.1:5353)..."
    sqlite3 "$DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('dns', '{\"servers\":[\"127.0.0.1:5353\"],\"tag\":\"dns_inbound\"}');" 2>/dev/null || true
    print_ok "DNS настроен"
}

enable_bbr() {
    print_step "Проверка BBR..."
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        print_ok "BBR уже включён"
        return
    fi
    cat > /etc/sysctl.d/99-bbr-vpn.conf << 'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl -p /etc/sysctl.d/99-bbr-vpn.conf > /dev/null 2>&1
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr \
        && print_ok "BBR включён" \
        || print_warn "BBR: проверьте вручную"
}

update_geo() {
    print_step "Обновление Geo файлов..."

    # Способ 1: через встроенную команду x-ui (самый надёжный)
    if [ -f "$XUI_BIN" ]; then
        print_info "Пробуем через x-ui..."
        if "$XUI_BIN" geo update 2>/dev/null; then
            print_ok "Geo файлы обновлены через x-ui"
            return
        fi
        # Некоторые версии x-ui используют другой синтаксис
        if x-ui geo 2>/dev/null | grep -qi "updat"; then
            x-ui geo update 2>/dev/null
            print_ok "Geo файлы обновлены через x-ui"
            return
        fi
    fi

    # Способ 2: прямые ссылки runetfreedom (минуя GitHub редиректы)
    print_info "Пробуем прямую загрузку..."
    local BASE="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download"
    local ok=true
    curl -sL --max-time 60 --retry 3 "$BASE/geoip.dat"   -o "$GEO_DIR/geoip.dat"   || ok=false
    curl -sL --max-time 60 --retry 3 "$BASE/geosite.dat" -o "$GEO_DIR/geosite.dat" || ok=false

    if $ok; then
        print_ok "Geo файлы обновлены через GitHub"
        return
    fi

    # Способ 3: зеркало v2fly (запасной вариант)
    print_info "Пробуем зеркало v2fly..."
    local ok2=true
    curl -sL --max-time 60 "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat"     -o "$GEO_DIR/geoip.dat"   || ok2=false
    curl -sL --max-time 60 "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat" -o "$GEO_DIR/geosite.dat" || ok2=false

    if $ok2; then
        print_ok "Geo файлы обновлены через v2fly (зеркало)"
        return
    fi

    # Ничего не сработало — оставляем старые файлы
    print_warn "Не удалось обновить Geo файлы — используются текущие"
    if [ -f "$GEO_DIR/geoip.dat" ] && [ -f "$GEO_DIR/geosite.dat" ]; then
        print_info "Текущие файлы: geoip=$(du -sh "$GEO_DIR/geoip.dat" | cut -f1), geosite=$(du -sh "$GEO_DIR/geosite.dat" | cut -f1)"
    else
        print_error "Geo файлы отсутствуют! x-ui может работать некорректно"
    fi
}

disable_logs() {
    sqlite3 "$DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('logLevel', 'none');"        2>/dev/null || true
    sqlite3 "$DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('accessLogPath', 'none');"   2>/dev/null || true
    sqlite3 "$DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('errorLogPath', 'none');"    2>/dev/null || true
}

get_server_ip() {
    SERVER_IP=$(curl -s --max-time 10 ifconfig.me 2>/dev/null \
             || curl -s --max-time 10 api.ipify.org 2>/dev/null \
             || hostname -I | awk '{print $1}')
}

# ══════════════════════════════════════════════════════════════
# ГЕНЕРАЦИЯ КЛЮЧЕЙ И ID
# ══════════════════════════════════════════════════════════════

generate_x25519_keys() {
    PRIVATE_KEY=""
    PUBLIC_KEY=""

    if [ -f "$XUI_BIN" ]; then
        local keys
        keys=$("$XUI_BIN" x25519 2>/dev/null)
        PRIVATE_KEY=$(echo "$keys" | grep -i "private" | awk '{print $NF}')
        PUBLIC_KEY=$(echo  "$keys" | grep -i "public"  | awk '{print $NF}')
    fi

    if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
        local raw
        raw=$(openssl genpkey -algorithm X25519 2>/dev/null)
        PRIVATE_KEY=$(echo "$raw" | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')
        PUBLIC_KEY=$(echo  "$raw" | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')
    fi

    if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
        print_error "Не удалось сгенерировать X25519 ключи!"
        exit 1
    fi
}

generate_short_ids() {
    SHORT_IDS_ARR=()
    for i in {1..8}; do
        local len=$(( (RANDOM % 8 + 1) * 2 ))
        local sid
        sid=$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c "$len")
        SHORT_IDS_ARR+=("\"$sid\"")
    done
    SHORT_IDS=$(IFS=,; echo "${SHORT_IDS_ARR[*]}")
    FIRST_SHORT_ID=$(echo "${SHORT_IDS_ARR[0]}" | tr -d '"')
}

generate_client_data() {
    CLIENT_UUID=$(cat /proc/sys/kernel/random/uuid)
    CLIENT_EMAIL=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 8)
    SUB_ID=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 16)
}

# ══════════════════════════════════════════════════════════════
# НАСТРОЙКА INBOUND
# ══════════════════════════════════════════════════════════════

# Спрашивает пересоздавать ли inbound если он уже есть
# Возвращает 0=оставить, 1=пересоздать
check_existing_inbound() {
    if [ "$XUI_EXISTED" = true ]; then
        local existing
        existing=$(sqlite3 "$DB" "SELECT remark FROM inbounds LIMIT 1;" 2>/dev/null)
        if [ -n "$existing" ]; then
            echo -e "\n${YELLOW}Найден inbound: '$existing'${NC}"
            echo -e "${YELLOW}Пересоздать с новыми ключами? (y/n)${NC}"
            read -r choice
            [[ ! "$choice" =~ ^[Yy]$ ]] && return 0
        fi
    fi
    return 1
}

read_existing_inbound_data() {
    CLIENT_UUID=$(sqlite3    "$DB" "SELECT json_extract(settings,       '$.clients[0].id')                        FROM inbounds LIMIT 1;" 2>/dev/null || echo "см.панель")
    PUBLIC_KEY=$(sqlite3     "$DB" "SELECT json_extract(stream_settings,'$.realitySettings.settings.publicKey')   FROM inbounds LIMIT 1;" 2>/dev/null || echo "см.панель")
    FIRST_SHORT_ID=$(sqlite3 "$DB" "SELECT json_extract(stream_settings,'$.realitySettings.shortIds[0]')          FROM inbounds LIMIT 1;" 2>/dev/null || echo "см.панель")
    CLIENT_EMAIL=$(sqlite3   "$DB" "SELECT json_extract(settings,       '$.clients[0].email')                     FROM inbounds LIMIT 1;" 2>/dev/null || echo "см.панель")
}

write_inbound_to_db() {
    local sni="$1"
    local port="$2"
    local name="$3"

    local cs ss sn
    cs=$(cat <<ENDJSON | sed "s/'/''/g"
{"clients":[{"id":"$CLIENT_UUID","email":"$CLIENT_EMAIL","enable":true,"expiryTime":0,"flow":"xtls-rprx-vision","limitIp":0,"totalGB":0,"reset":0,"subId":"$SUB_ID","comment":"","tgId":0}],"decryption":"none","encryption":"none"}
ENDJSON
)
    ss=$(cat <<ENDJSON | sed "s/'/''/g"
{"network":"tcp","security":"reality","realitySettings":{"show":false,"xver":0,"dest":"$sni:443","serverNames":["$sni"],"privateKey":"$PRIVATE_KEY","minClientVer":"","maxClientVer":"","maxTimeDiff":0,"shortIds":[$SHORT_IDS]},"tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}
ENDJSON
)
    sn='{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'
    sn=$(echo "$sn" | sed "s/'/''/g")

    # Останавливаем x-ui чтобы освободить БД
    nohup systemctl restart x-ui > /tmp/xui_restart.log 2>&1 &
    sleep 1

    # Удаляем по тегу И по порту — чтобы не было UNIQUE constraint
    sqlite3 "$DB" "DELETE FROM inbounds WHERE tag='inbound-$port' OR port=$port;"
    sqlite3 "$DB" "INSERT INTO inbounds (user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing) VALUES (1,0,0,0,'$name',1,0,'',$port,'vless','$cs','$ss','inbound-$port','$sn');"
    print_ok "Inbound создан"
}

# ══════════════════════════════════════════════════════════════
# ПУНКТ 1: УСТАНОВКА ЗАРУБЕЖНОГО СЕРВЕРА
# ══════════════════════════════════════════════════════════════

setup_foreign() {
    print_section "НАСТРОЙКА ЗАРУБЕЖНОГО СЕРВЕРА"

    # Имя сервера
    echo -e "\n${YELLOW}Выберите страну:${NC}"
    echo "1) Нидерланды  2) Финляндия  3) Германия  4) Франция"
    echo "5) Швеция      6) Польша     7) Чехия      8) Своё имя"
    read -r choice
    case $choice in
        1) SERVER_NAME="Netherlands_1" ;;
        2) SERVER_NAME="Finland_1" ;;
        3) SERVER_NAME="Germany_1" ;;
        4) SERVER_NAME="France_1" ;;
        5) SERVER_NAME="Sweden_1" ;;
        6) SERVER_NAME="Poland_1" ;;
        7) SERVER_NAME="Czech_1" ;;
        8) read -r -p "Имя сервера: " SERVER_NAME; [ -z "$SERVER_NAME" ] && SERVER_NAME="Foreign_1" ;;
        *) SERVER_NAME="Foreign_1" ;;
    esac

    # Порт
    read -r -p "Порт (Enter=22106): " PORT
    [ -z "$PORT" ] && PORT=22106

    # Подтверждение
    echo -e "\n${CYAN}━━━ Параметры ━━━${NC}"
    echo -e "  Имя:  ${GREEN}$SERVER_NAME${NC}"
    echo -e "  Порт: ${GREEN}$PORT${NC}"
    echo -e "  SNI:  ${GREEN}www.microsoft.com${NC}"
    echo -e "${YELLOW}Начать установку? (y/n)${NC}"
    read -r go_confirm
    [[ ! "$go_confirm" =~ ^[Yy]$ ]] && { print_info "Отменено"; return 0; }

    print_ok "Сервер: $SERVER_NAME, порт: $PORT"

    get_server_ip
    do_backup "before_foreign_setup"
    check_and_install_3xui
    enable_bbr
    update_geo

    # Inbound
    print_step "Настройка inbound..."
    if check_existing_inbound; then
        print_info "Читаем существующий inbound"
        read_existing_inbound_data
    else
        generate_client_data
        generate_x25519_keys
        generate_short_ids
        write_inbound_to_db "www.microsoft.com" "$PORT" "$SERVER_NAME"
    fi

    # Маршрутизация
    print_step "Маршрутизация..."
    local rc
    rc=$(cat <<'ROUTING' | sed "s/'/''/g"
{"domainStrategy":"AsIs","rules":[{"type":"field","inboundTag":["api"],"outboundTag":"api"},{"type":"field","ip":["::1/128","fc00::/7","fe80::/10","2000::/3","::/0"],"outboundTag":"blocked"},{"type":"field","port":"443","network":"udp","outboundTag":"blocked"},{"type":"field","protocol":["bittorrent"],"outboundTag":"blocked"},{"type":"field","ip":["geoip:private"],"outboundTag":"blocked"},{"type":"field","domain":["geosite:category-porn","geosite:category-ads-all"],"outboundTag":"blocked"},{"type":"field","domain":["regexp:\\.ru$","regexp:\\.su$","regexp:\\.рф$"],"outboundTag":"direct"},{"type":"field","ip":["geoip:ru"],"outboundTag":"direct"}]}
ROUTING
)
    # Останавливаем x-ui перед записью (если ещё не остановлен после write_inbound)
    sqlite3 "$DB" "PRAGMA journal_mode=WAL;"
    sqlite3 "$DB" "INSERT OR REPLACE INTO settings (key,value) VALUES ('routingConfig','$rc');" 2>/dev/null || true
    disable_logs
    print_ok "Маршрутизация настроена"

    print_step "Перезапуск x-ui..."
    systemctl restart x-ui
    auto_rollback_if_failed || return 1

    # Результат
    echo -e "\n${GREEN}"
    echo "╔══════════════════════════════════════════╗"
    echo "║     ЗАРУБЕЖНЫЙ СЕРВЕР НАСТРОЕН!          ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "${CYAN}━━━ Данные для российского сервера ━━━${NC}"
    echo -e "IP:             ${GREEN}$SERVER_IP${NC}"
    echo -e "Порт:           ${GREEN}$PORT${NC}"
    echo -e "ID клиента:     ${GREEN}$CLIENT_UUID${NC}"
    echo -e "Публичный ключ: ${GREEN}$PUBLIC_KEY${NC}"
    echo -e "Short ID:       ${GREEN}$FIRST_SHORT_ID${NC}"
    echo -e "SNI:            ${GREEN}www.microsoft.com${NC}"
    echo -e "3x-ui панель:   ${GREEN}http://$SERVER_IP:8080${NC}"
    echo -e "${YELLOW}💡 AdGuard можно установить через пункт 10 меню${NC}"

    cat > /root/vpn_foreign_data.txt << EOF
=== Зарубежный VPN сервер ($SERVER_NAME) ===
Дата настройки: $(date '+%Y-%m-%d %H:%M')
IP:             $SERVER_IP
Порт:           $PORT
ID клиента:     $CLIENT_UUID
Публичный ключ: $PUBLIC_KEY
Short ID:       $FIRST_SHORT_ID
SNI:            www.microsoft.com
Email клиента:  $CLIENT_EMAIL

Панель 3x-ui:   http://$SERVER_IP:8080
AdGuard:        установить через пункт 10 меню

Бэкапы: ls $BACKUP_DIR/
Скачать бэкап: scp root@$SERVER_IP:$BACKUP_DIR/<файл> ./
EOF
    print_ok "Данные сохранены в /root/vpn_foreign_data.txt"
    chmod 600 /root/vpn_foreign_data.txt
    print_info "Теперь запустите скрипт на российском сервере (пункт 2)"
}

# ══════════════════════════════════════════════════════════════
# ПУНКТ 2: УСТАНОВКА РОССИЙСКОГО СЕРВЕРА
# ══════════════════════════════════════════════════════════════

setup_russia() {
    print_section "НАСТРОЙКА РОССИЙСКОГО СЕРВЕРА"

    # Имя
    read -r -p "Имя сервера (Enter=Russia_1): " SERVER_NAME
    [ -z "$SERVER_NAME" ] && SERVER_NAME="Russia_1"

    # Порт
    read -r -p "Порт (Enter=22105): " PORT
    [ -z "$PORT" ] && PORT=22105

    # SNI
    echo -e "\n${YELLOW}SNI для маскировки:${NC}"
    echo "1) ads.x5.ru  2) stats.vk-portal.net  3) www.wildberries.ru  4) www.ozon.ru  5) Свой"
    read -r sni_choice
    case $sni_choice in
        1) SNI="ads.x5.ru" ;;
        2) SNI="stats.vk-portal.net" ;;
        3) SNI="www.wildberries.ru" ;;
        4) SNI="www.ozon.ru" ;;
        5) read -r -p "SNI: " SNI ;;
        *) SNI="ads.x5.ru" ;;
    esac

    # Данные зарубежного сервера
    print_section "Данные зарубежного сервера"
    print_info "Из /root/vpn_foreign_data.txt на зарубежном сервере"
    read -r -p "IP: "              FOREIGN_IP
    read -r -p "Порт (Enter=22106): " FOREIGN_PORT;  [ -z "$FOREIGN_PORT" ]  && FOREIGN_PORT=22106
    read -r -p "ID клиента: "      FOREIGN_CLIENT_ID
    read -r -p "Публичный ключ: "  FOREIGN_PUBLIC_KEY
    read -r -p "Short ID: "        FOREIGN_SHORT_ID
    read -r -p "SNI (Enter=www.microsoft.com): " FOREIGN_SNI
    [ -z "$FOREIGN_SNI" ] && FOREIGN_SNI="www.microsoft.com"

    # Подтверждение перед запуском
    echo -e "\n${CYAN}━━━ Параметры установки ━━━${NC}"
    echo -e "  Имя сервера:    ${GREEN}$SERVER_NAME${NC}"
    echo -e "  Локальный порт: ${GREEN}$PORT${NC}"
    echo -e "  SNI (маскировка): ${GREEN}$SNI${NC}"
    echo -e "  Зарубежный IP:  ${GREEN}$FOREIGN_IP:$FOREIGN_PORT${NC}"
    echo -e "  Зарубежный SNI: ${GREEN}$FOREIGN_SNI${NC}"
    echo -e "${YELLOW}Начать установку? (y/n)${NC}"
    read -r go_confirm
    [[ ! "$go_confirm" =~ ^[Yy]$ ]] && { print_info "Отменено"; return 0; }

    get_server_ip
    do_backup "before_russia_setup"
    check_and_install_3xui
    enable_bbr
    update_geo

    # Inbound
    print_step "Настройка inbound..."
    if check_existing_inbound; then
        print_info "Читаем существующий inbound"
        read_existing_inbound_data
        PUBLIC_KEY_RU="$PUBLIC_KEY"
        FIRST_SHORT_ID_RU="$FIRST_SHORT_ID"
    else
        generate_client_data
        generate_x25519_keys
        generate_short_ids
        PUBLIC_KEY_RU="$PUBLIC_KEY"
        FIRST_SHORT_ID_RU="$FIRST_SHORT_ID"
        write_inbound_to_db "$SNI" "$PORT" "$SERVER_NAME"
    fi

    # Полный xray шаблон с outbound + маршрутизация
    print_step "Настройка outbound и маршрутизации..."
    local xt
    xt=$(cat <<ENDJSON | sed "s/'/''/g"
{"log":{"access":"none","dnsLog":false,"error":"none","loglevel":"none","maskAddress":""},"api":{"tag":"api","services":["HandlerService","LoggerService","StatsService"]},"inbounds":[{"tag":"api","listen":"127.0.0.1","port":62789,"protocol":"tunnel","settings":{"address":"127.0.0.1"}}],"outbounds":[{"tag":"direct","protocol":"freedom","settings":{"domainStrategy":"AsIs","redirect":"","noises":[]}},{"tag":"blocked","protocol":"blackhole","settings":{}},{"tag":"netherlands","protocol":"vless","settings":{"vnext":[{"address":"$FOREIGN_IP","port":$FOREIGN_PORT,"users":[{"id":"$FOREIGN_CLIENT_ID","encryption":"none","flow":"xtls-rprx-vision"}]}]},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"serverName":"$FOREIGN_SNI","fingerprint":"chrome","show":false,"publicKey":"$FOREIGN_PUBLIC_KEY","shortId":"$FOREIGN_SHORT_ID","spiderX":"/"},"tcpSettings":{"header":{"type":"none"}}}}],"policy":{"levels":{"0":{"statsUserDownlink":true,"statsUserUplink":true}},"system":{"statsInboundDownlink":true,"statsInboundUplink":true,"statsOutboundDownlink":false,"statsOutboundUplink":false}},"routing":{"domainStrategy":"AsIs","rules":[{"type":"field","inboundTag":["api"],"outboundTag":"api"},{"type":"field","ip":["::1/128","fc00::/7","fe80::/10","2000::/3","::/0"],"outboundTag":"blocked"},{"type":"field","port":"443","network":"udp","outboundTag":"blocked"},{"type":"field","ip":["geoip:private"],"outboundTag":"blocked"},{"type":"field","protocol":["bittorrent"],"outboundTag":"blocked"},{"type":"field","domain":["geosite:category-porn","geosite:category-ads-all"],"outboundTag":"blocked"},{"type":"field","domain":["geosite:twitter","geosite:facebook","geosite:tiktok","geosite:netflix","geosite:spotify"],"outboundTag":"netherlands"},{"type":"field","domain":["geosite:youtube","geosite:google","geosite:instagram","geosite:meta","geosite:telegram","geosite:whatsapp"],"outboundTag":"netherlands"},{"type":"field","domain":["regexp:\\.ru\$","regexp:\\.su\$","regexp:\\.рф\$"],"outboundTag":"direct"},{"type":"field","ip":["geoip:ru"],"outboundTag":"direct"},{"type":"field","inboundTag":["inbound-$PORT"],"outboundTag":"netherlands"}]},"stats":{},"metrics":{"tag":"metrics_out","listen":"127.0.0.1:11111"}}
ENDJSON
)
    # Останавливаем x-ui перед записью
    sqlite3 "$DB" "PRAGMA journal_mode=WAL;"
    sqlite3 "$DB" "INSERT OR REPLACE INTO settings (key,value) VALUES ('xrayTemplateConfig','$xt');"
    disable_logs
    print_ok "Outbound и маршрутизация настроены"

    print_step "Перезапуск x-ui..."
    systemctl restart x-ui
    auto_rollback_if_failed || return 1

    # Генерируем ссылку
    local vless_link="vless://$CLIENT_UUID@$SERVER_IP:$PORT?type=tcp&security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC_KEY_RU&sid=$FIRST_SHORT_ID_RU&flow=xtls-rprx-vision#$SERVER_NAME-$CLIENT_EMAIL"

    echo -e "\n${GREEN}"
    echo "╔══════════════════════════════════════════╗"
    echo "║      РОССИЙСКИЙ СЕРВЕР НАСТРОЕН!         ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "${CYAN}━━━ Ссылка для v2rayNG ━━━${NC}"
    echo -e "${GREEN}$vless_link${NC}"
    echo -e "\n${CYAN}━━━ Панель ━━━${NC}"
    echo -e "URL: ${GREEN}http://$SERVER_IP:8080${NC}"
    echo -e "${YELLOW}В v2rayNG → поле 'Поток': xtls-rprx-vision${NC}"

    cat > /root/vpn_russia_data.txt << EOF
=== Российский VPN сервер ($SERVER_NAME) ===
Дата настройки: $(date '+%Y-%m-%d %H:%M')
IP:     $SERVER_IP
Порт:   $PORT
SNI:    $SNI

Ссылка для v2rayNG:
$vless_link

Панель: http://$SERVER_IP:8080

Зарубежный сервер:
IP: $FOREIGN_IP  Порт: $FOREIGN_PORT
ID: $FOREIGN_CLIENT_ID
Ключ: $FOREIGN_PUBLIC_KEY
ShortID: $FOREIGN_SHORT_ID  SNI: $FOREIGN_SNI

Бэкапы: ls $BACKUP_DIR/
EOF
    print_ok "Данные сохранены в /root/vpn_russia_data.txt"
    chmod 600 /root/vpn_russia_data.txt

    # Предлагаем проверить связь
    echo -e "\n${YELLOW}Проверить связь с зарубежным сервером прямо сейчас? (y/n)${NC}"
    read -r check_now
    [[ "$check_now" =~ ^[Yy]$ ]] && check_connection
}

# ══════════════════════════════════════════════════════════════
# ПУНКТ 3: ВОССТАНОВЛЕНИЕ ИЗ БЭКАПА
# ══════════════════════════════════════════════════════════════

restore_from_backup() {
    print_section "ВОССТАНОВЛЕНИЕ ИЗ БЭКАПА"

    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls "$BACKUP_DIR"/*_xui.db 2>/dev/null)" ]; then
        print_error "Бэкапов не найдено в $BACKUP_DIR"
        return 1
    fi

    echo -e "\n${CYAN}Доступные бэкапы:${NC}"
    local i=1
    declare -a BACKUP_LIST
    while IFS= read -r f; do
        local base="${f%_xui.db}"
        local name
        name=$(basename "$base")
        local adg=""
        [ -f "${base}_adguard.yaml" ] && adg=" + AdGuard"
        echo "  $i) $name$adg"
        BACKUP_LIST+=("$base")
        i=$((i + 1))
    done < <(ls -t "$BACKUP_DIR"/*_xui.db 2>/dev/null)

    echo ""
    read -r -p "Выберите номер бэкапа: " num
    local selected="${BACKUP_LIST[$((num - 1))]}"

    if [ -z "$selected" ] || [ ! -f "${selected}_xui.db" ]; then
        print_error "Неверный выбор"
        return 1
    fi

    print_info "Выбран: $(basename "$selected")"
    echo -e "${YELLOW}Восстановить? (y/n)${NC}"
    read -r confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { print_info "Отменено"; return 0; }

    # Бэкапим текущее состояние перед восстановлением
    do_backup "before_restore"

    systemctl stop x-ui 2>/dev/null; sleep 1
    cp "${selected}_xui.db" "$DB"
    print_ok "БД x-ui восстановлена"

    if [ -f "${selected}_adguard.yaml" ]; then
        cp "${selected}_adguard.yaml" /opt/AdGuardHome/AdGuardHome.yaml
        systemctl restart AdGuardHome 2>/dev/null
        print_ok "AdGuard конфиг восстановлен"
    fi

    nohup systemctl start x-ui > /tmp/xui_restart.log 2>&1 &
    sleep 3

    if systemctl is-active --quiet x-ui; then
        print_ok "x-ui запущен — восстановление успешно!"
    else
        print_error "x-ui не запустился после восстановления"
        echo "  journalctl -u x-ui -n 30"
    fi
}

# ══════════════════════════════════════════════════════════════
# ПУНКТ 4: ОБНОВЛЕНИЕ x-ui
# ══════════════════════════════════════════════════════════════

update_xui() {
    print_section "ОБНОВЛЕНИЕ x-ui"

    # Текущая версия
    local current_ver=""
    [ -f "$XUI_BIN" ] && current_ver=$("$XUI_BIN" version 2>/dev/null | head -1 || echo "неизвестна")
    print_info "Текущая версия: ${current_ver:-не установлен}"

    echo -e "${YELLOW}Создать бэкап и обновить x-ui? (y/n)${NC}"
    read -r confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0

    do_backup "before_xui_update"

    print_step "Обновление x-ui..."
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) << 'INSTALL_EOF'
y
8080
INSTALL_EOF
    sleep 5

    if auto_rollback_if_failed; then
        local new_ver=""
        [ -f "$XUI_BIN" ] && new_ver=$("$XUI_BIN" version 2>/dev/null | head -1)
        print_ok "x-ui обновлён: ${new_ver:-версия неизвестна}"
        # Обновляем geo файлы после обновления
        update_geo
    fi
}

# ══════════════════════════════════════════════════════════════
# ПУНКТ 5: ДОБАВЛЕНИЕ КЛИЕНТА
# ══════════════════════════════════════════════════════════════

add_client() {
    print_section "ДОБАВЛЕНИЕ НОВОГО КЛИЕНТА"

    if ! systemctl is-active --quiet x-ui; then
        print_error "x-ui не запущен!"
        return 1
    fi

    # Получаем список inbound'ов
    local inbound_count
    inbound_count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM inbounds;" 2>/dev/null)

    local inbound_id port remark
    if [ "$inbound_count" -gt 1 ]; then
        echo -e "\n${CYAN}Доступные inbound'ы:${NC}"
        local i=1
        declare -a IB_IDS IB_PORTS IB_REMARKS
        while IFS='|' read -r ib_id ib_port ib_remark; do
            echo "  $i) $ib_remark (порт $ib_port)"
            IB_IDS+=("$ib_id"); IB_PORTS+=("$ib_port"); IB_REMARKS+=("$ib_remark")
            i=$((i + 1))
        done < <(sqlite3 "$DB" "SELECT id,port,remark FROM inbounds ORDER BY id;")
        read -r -p "Выберите inbound (Enter=1): " ib_choice
        [ -z "$ib_choice" ] && ib_choice=1
        inbound_id="${IB_IDS[$((ib_choice - 1))]}"
        port="${IB_PORTS[$((ib_choice - 1))]}"
        remark="${IB_REMARKS[$((ib_choice - 1))]}"
    else
        inbound_id=$(sqlite3 "$DB" "SELECT id FROM inbounds LIMIT 1;" 2>/dev/null)
        port=$(sqlite3       "$DB" "SELECT port FROM inbounds LIMIT 1;" 2>/dev/null)
        remark=$(sqlite3     "$DB" "SELECT remark FROM inbounds LIMIT 1;" 2>/dev/null)
    fi

    if [ -z "$inbound_id" ]; then
        print_error "Inbound не найден — сначала настройте сервер (пункт 1 или 2)"
        return 1
    fi

    print_info "Inbound: $remark (порт $port)"

    # ── Имя клиента ──────────────────────────────────────────
    read -r -p "Имя клиента (Enter=авто): " new_email
    [ -z "$new_email" ] && new_email=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 8)

    # ── Лимит трафика ────────────────────────────────────────
    echo -e "\n${YELLOW}Лимит трафика (GB):${NC}"
    echo "  0 = безлимит"
    echo "  Примеры: 1, 5, 10, 50"
    read -r -p "Лимит GB (Enter=безлимит): " traffic_limit
    [ -z "$traffic_limit" ] && traffic_limit=0
    # Переводим GB в байты для x-ui (0 = безлимит)
    local total_gb_bytes=0
    if [ "$traffic_limit" -gt 0 ] 2>/dev/null; then
        total_gb_bytes=$((traffic_limit * 1024 * 1024 * 1024))
    fi

    # ── Срок действия ────────────────────────────────────────
    echo -e "\n${YELLOW}Срок действия:${NC}"
    echo "  0 = бессрочно"
    echo "  Примеры: 1 (день), 7 (неделя), 30 (месяц)"
    read -r -p "Дней (Enter=бессрочно): " expire_days
    [ -z "$expire_days" ] && expire_days=0
    local expiry_time=0
    if [ "$expire_days" -gt 0 ] 2>/dev/null; then
        # Unix timestamp в миллисекундах
        expiry_time=$(( ($(date +%s) + expire_days * 86400) * 1000 ))
    fi

    # ── Лимит устройств ──────────────────────────────────────
    echo -e "\n${YELLOW}Лимит устройств одновременно:${NC}"
    echo "  0 = без лимита"
    read -r -p "Устройств (Enter=без лимита): " ip_limit
    [ -z "$ip_limit" ] && ip_limit=0

    # ── Итог перед созданием ─────────────────────────────────
    echo -e "\n${CYAN}━━━ Параметры клиента ━━━${NC}"
    echo -e "  Имя:       ${GREEN}$new_email${NC}"
    [ "$traffic_limit" -gt 0 ] \
        && echo -e "  Трафик:    ${YELLOW}${traffic_limit} GB${NC}" \
        || echo -e "  Трафик:    ${GREEN}безлимит${NC}"
    [ "$expire_days" -gt 0 ] \
        && echo -e "  Срок:      ${YELLOW}${expire_days} дн. (до $(date -d "+${expire_days} days" '+%d.%m.%Y'))${NC}" \
        || echo -e "  Срок:      ${GREEN}бессрочно${NC}"
    [ "$ip_limit" -gt 0 ] \
        && echo -e "  Устройств: ${YELLOW}${ip_limit}${NC}" \
        || echo -e "  Устройств: ${GREEN}без лимита${NC}"

    echo -e "\n${YELLOW}Создать? (y/n)${NC}"
    read -r confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { print_info "Отменено"; return 0; }

    local new_uuid new_sub_id
    new_uuid=$(cat /proc/sys/kernel/random/uuid)
    new_sub_id=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 16)

    do_backup "before_add_client"

    # Читаем текущие настройки
    local current_settings
    current_settings=$(sqlite3 "$DB" "SELECT settings FROM inbounds WHERE id=$inbound_id;")

    # Добавляем клиента через python3 — используем tmpfile чтобы избежать проблем с кавычками
    local py_input py_script new_settings
    py_input=$(mktemp)
    py_script=$(mktemp)
    echo "$current_settings" > "$py_input"

    cat > "$py_script" << PYEOF
import json, sys
with open('$py_input') as f:
    s = json.load(f)
s['clients'].append({
    "id": "$new_uuid",
    "email": "$new_email",
    "enable": True,
    "expiryTime": $expiry_time,
    "flow": "xtls-rprx-vision",
    "limitIp": $ip_limit,
    "totalGB": $total_gb_bytes,
    "reset": 0,
    "subId": "$new_sub_id",
    "comment": "",
    "tgId": 0
})
print(json.dumps(s))
PYEOF
    new_settings=$(python3 "$py_script")
    rm -f "$py_input" "$py_script"

    if [ -z "$new_settings" ]; then
        print_error "Ошибка при создании клиента"
        return 1
    fi

    # Пишем в БД через python — экранируем для SQLite
    local ns_escaped
    ns_escaped=$(echo "$new_settings" | python3 -c "import sys; print(sys.stdin.read().replace(\"'\", \"''\"))" )

    # Пишем в БД — WAL режим позволяет писать без полной блокировки
    sqlite3 "$DB" "PRAGMA journal_mode=WAL;"
    sqlite3 "$DB" "UPDATE inbounds SET settings='$ns_escaped' WHERE id=$inbound_id;"

    # Перезапускаем через nohup чтобы не рвать SSH сессию
    nohup systemctl restart x-ui > /tmp/xui_restart.log 2>&1 &
    sleep 4
    auto_rollback_if_failed || return 1

    # Получаем данные для ссылки
    get_server_ip
    local stream
    stream=$(sqlite3 "$DB" "SELECT stream_settings FROM inbounds WHERE id=$inbound_id;")
    local pub_key short_id sni_val
    pub_key=$(echo  "$stream" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['realitySettings']['settings']['publicKey'])" 2>/dev/null)
    short_id=$(echo "$stream" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['realitySettings']['shortIds'][0])" 2>/dev/null)
    sni_val=$(echo  "$stream" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['realitySettings']['serverNames'][0])" 2>/dev/null)

    local vless_link="vless://$new_uuid@$SERVER_IP:$port?type=tcp&security=reality&sni=$sni_val&fp=chrome&pbk=$pub_key&sid=$short_id&flow=xtls-rprx-vision#$remark-$new_email"

    echo -e "\n${GREEN}"
    echo "╔══════════════════════════════════════════╗"
    echo "║         КЛИЕНТ СОЗДАН!                   ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"

    echo -e "${CYAN}━━━ Параметры ━━━${NC}"
    echo -e "Имя:    ${GREEN}$new_email${NC}"
    [ "$traffic_limit" -gt 0 ] && echo -e "Трафик: ${YELLOW}${traffic_limit} GB${NC}" || echo -e "Трафик: ${GREEN}безлимит${NC}"
    [ "$expire_days"   -gt 0 ] && echo -e "Срок:   ${YELLOW}до $(date -d "+${expire_days} days" '+%d.%m.%Y')${NC}" || echo -e "Срок:   ${GREEN}бессрочно${NC}"
    [ "$ip_limit"      -gt 0 ] && echo -e "Устр.:  ${YELLOW}${ip_limit} шт.${NC}" || echo -e "Устр.:  ${GREEN}без лимита${NC}"

    echo -e "\n${CYAN}━━━ Ссылка для v2rayNG ━━━${NC}"
    echo -e "${GREEN}$vless_link${NC}"
    echo -e "${YELLOW}Поток: xtls-rprx-vision${NC}"

    # QR-код в терминале
    echo -e "\n${CYAN}━━━ QR-код (сканируй в v2rayNG) ━━━${NC}"
    if command -v qrencode &>/dev/null; then
        qrencode -t ANSIUTF8 "$vless_link"
    else
        print_info "Устанавливаем qrencode..."
        apt-get install -y qrencode > /dev/null 2>&1
        if command -v qrencode &>/dev/null; then
            qrencode -t ANSIUTF8 "$vless_link"
        else
            print_warn "qrencode не установился — скопируй ссылку вручную"
        fi
    fi

    # Сохраняем данные клиента в файл
    cat >> /root/vpn_clients.txt << EOF

=== Клиент: $new_email ($(date '+%d.%m.%Y %H:%M')) ===
Трафик: ${traffic_limit:-безлимит} GB
Срок:   ${expire_days:-бессрочно} дн.
Устр.:  ${ip_limit:-без лимита}
Ссылка: $vless_link
EOF
    print_ok "Данные сохранены в /root/vpn_clients.txt"
    chmod 600 /root/vpn_clients.txt
}

# ══════════════════════════════════════════════════════════════
# ПУНКТ 6: ПРОВЕРКА СВЯЗИ
# ══════════════════════════════════════════════════════════════

check_connection() {
    print_section "ПРОВЕРКА СВЯЗИ"

    if ! systemctl is-active --quiet x-ui; then
        print_error "x-ui не запущен!"
        return 1
    fi

    get_server_ip
    local port
    port=$(sqlite3 "$DB" "SELECT port FROM inbounds LIMIT 1;" 2>/dev/null)

    echo -e "\n${CYAN}1. Проверка внешнего IP сервера...${NC}"
    echo -e "   IP сервера: ${GREEN}$SERVER_IP${NC}"

    echo -e "\n${CYAN}2. Проверка доступности порта $port...${NC}"
    if timeout 5 bash -c "echo >/dev/tcp/$SERVER_IP/$port" 2>/dev/null; then
        print_ok "Порт $port открыт"
    else
        print_warn "Порт $port не отвечает на прямое подключение (это нормально для Reality)"
    fi

    echo -e "\n${CYAN}3. Проверка x-ui API...${NC}"
    local api_resp
    api_resp=$(curl -s --max-time 5 "http://127.0.0.1:2053/login" 2>/dev/null | head -c 100)
    if [ -n "$api_resp" ]; then
        print_ok "x-ui API отвечает"
    else
        # Пробуем другой порт
        api_resp=$(curl -s --max-time 5 "http://127.0.0.1:8080/login" 2>/dev/null | head -c 100)
        [ -n "$api_resp" ] && print_ok "x-ui панель отвечает" || print_warn "x-ui API недоступен на стандартных портах"
    fi

    echo -e "\n${CYAN}4. Проверка AdGuard (если установлен)...${NC}"
    if systemctl is-active --quiet AdGuardHome; then
        local dns_check
        dns_check=$(dig +short @127.0.0.1 -p 5353 google.com 2>/dev/null | head -1)
        if [ -n "$dns_check" ]; then
            print_ok "AdGuard DNS работает (google.com → $dns_check)"
        else
            print_warn "AdGuard не отвечает на DNS запросы"
        fi
    else
        print_info "AdGuard не установлен на этом сервере"
    fi

    echo -e "\n${CYAN}5. Проверка исходящего интернета...${NC}"
    local ext_ip
    ext_ip=$(curl -s --max-time 10 ifconfig.me 2>/dev/null)
    if [ -n "$ext_ip" ]; then
        print_ok "Интернет работает (внешний IP: $ext_ip)"
    else
        print_error "Нет исходящего интернета!"
    fi

    echo -e "\n${CYAN}6. Проверка Geo файлов...${NC}"
    [ -f "$GEO_DIR/geoip.dat" ]   && print_ok "geoip.dat существует  ($(du -sh "$GEO_DIR/geoip.dat" | cut -f1))" || print_error "geoip.dat отсутствует!"
    [ -f "$GEO_DIR/geosite.dat" ] && print_ok "geosite.dat существует ($(du -sh "$GEO_DIR/geosite.dat" | cut -f1))" || print_error "geosite.dat отсутствует!"

    echo -e "\n${CYAN}7. Статус сервисов...${NC}"
    systemctl is-active --quiet x-ui          && print_ok "x-ui: активен"           || print_error "x-ui: не работает"
    systemctl is-active --quiet AdGuardHome   && print_ok "AdGuardHome: активен"    || print_info  "AdGuardHome: не установлен"

    echo -e "\n${CYAN}8. Проверка BBR...${NC}"
    local bbr
    bbr=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    [ "$bbr" = "bbr" ] && print_ok "BBR включён" || print_warn "BBR не активен (текущий: $bbr)"

    echo ""
    print_info "Для полной проверки туннеля подключитесь через v2rayNG и проверьте ip через браузер"
}

# ══════════════════════════════════════════════════════════════
# ПУНКТ 7: НАСТРОЙКА CRON
# ══════════════════════════════════════════════════════════════

setup_cron() {
    print_section "НАСТРОЙКА АВТОМАТИЧЕСКИХ ЗАДАЧ (CRON)"

    echo -e "\n${CYAN}Текущие vpn-задачи в cron:${NC}"
    crontab -l 2>/dev/null | grep -E "(vpn|geo|x-ui|backup)" || echo "  (нет задач)"

    echo -e "\n${YELLOW}Выберите действие:${NC}"
    echo "1) Добавить все задачи (Geo еженедельно + бэкап ежедневно)"
    echo "2) Только обновление Geo файлов (еженедельно, пн 3:00)"
    echo "3) Только автобэкап БД (ежедневно, 3:00)"
    echo "4) Удалить все vpn-задачи из cron"
    echo "0) Назад"
    read -r choice

    case $choice in
        1|2|3)
            local script_path
            script_path=$(realpath "$0")
            local tmp_cron
            tmp_cron=$(mktemp)
            crontab -l 2>/dev/null | grep -v -E "(vpn_setup|vpn_geo|vpn_backup)" > "$tmp_cron"

            if [ "$choice" = "1" ] || [ "$choice" = "2" ]; then
                echo "0 3 * * 1 $script_path --cron-geo >> /var/log/vpn_geo.log 2>&1" >> "$tmp_cron"
                print_ok "Добавлено: обновление Geo (пн 3:00)"
            fi
            if [ "$choice" = "1" ] || [ "$choice" = "3" ]; then
                echo "0 3 * * * $script_path --cron-backup >> /var/log/vpn_backup.log 2>&1" >> "$tmp_cron"
                print_ok "Добавлено: автобэкап (ежедневно 3:00)"
            fi

            crontab "$tmp_cron"
            rm -f "$tmp_cron"
            print_ok "Cron обновлён"
            ;;
        4)
            local tmp_cron
            tmp_cron=$(mktemp)
            crontab -l 2>/dev/null | grep -v -E "(vpn_setup|vpn_geo|vpn_backup)" > "$tmp_cron"
            crontab "$tmp_cron"
            rm -f "$tmp_cron"
            print_ok "VPN задачи удалены из cron"
            ;;
        0) return ;;
        *) print_error "Неверный выбор" ;;
    esac

    echo -e "\n${CYAN}Актуальный cron:${NC}"
    crontab -l 2>/dev/null | grep -E "(vpn|geo|backup)" || echo "  (нет задач)"
}

# ──── Cron режимы (вызываются автоматически) ─────────────────
cron_geo() {
    echo "=== Geo update $(date) ==="
    update_geo
    systemctl restart x-ui
}

cron_backup() {
    echo "=== Auto backup $(date) ==="
    do_backup "cron_daily"
}

# ══════════════════════════════════════════════════════════════
# ПУНКТ 8: ПРОСМОТР БЭКАПОВ
# ══════════════════════════════════════════════════════════════

list_backups() {
    print_section "БЭКАПЫ"
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls "$BACKUP_DIR" 2>/dev/null)" ]; then
        print_info "Бэкапов пока нет"
        return
    fi

    echo -e "\n${CYAN}Файлы в $BACKUP_DIR:${NC}"
    ls -lh "$BACKUP_DIR" | grep -v "^total"

    echo -e "\n${CYAN}Итого:${NC}"
    du -sh "$BACKUP_DIR" 2>/dev/null

    echo -e "\n${YELLOW}Чтобы скачать бэкап на телефон (в Termux):${NC}"
    get_server_ip
    echo -e "  ${GREEN}scp root@$SERVER_IP:$BACKUP_DIR/<имя_файла> ~/storage/downloads/${NC}"
}

# ══════════════════════════════════════════════════════════════
# ПУНКТ 10: УСТАНОВКА ADGUARD HOME (опционально)
# ══════════════════════════════════════════════════════════════

install_adguard_menu() {
    print_section "УСТАНОВКА ADGUARD HOME"

    if systemctl is-active --quiet AdGuardHome; then
        print_ok "AdGuard Home уже запущен"
        echo -e "Панель: ${GREEN}http://$(curl -s ifconfig.me 2>/dev/null):80${NC}  (admin / AdG@2027!NL)"
        echo -e "\n${YELLOW}Переустановить? (y/n)${NC}"
        read -r reinstall
        [[ ! "$reinstall" =~ ^[Yy]$ ]] && return
    fi

    echo -e "\n${CYAN}AdGuard Home — DNS фильтр для блокировки рекламы${NC}"
    echo -e "${YELLOW}Будет установлен на порт 80 (панель) и 5353 (DNS)${NC}"
    echo -e "${YELLOW}Продолжить? (y/n)${NC}"
    read -r confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return

    # Пароль для AdGuard
    local adg_password adg_password2 adg_hash
    while true; do
        read -r -s -p "Придумайте пароль для AdGuard (мин. 8 символов): " adg_password; echo
        read -r -s -p "Повторите пароль: " adg_password2; echo
        if [ "$adg_password" != "$adg_password2" ]; then
            print_error "Пароли не совпадают, попробуйте снова"
        elif [ ${#adg_password} -lt 8 ]; then
            print_error "Пароль слишком короткий (мин. 8 символов)"
        else
            break
        fi
    done
    # Хешируем bcrypt через python3
    adg_hash=$(python3 -c "import bcrypt; print(bcrypt.hashpw('$adg_password'.encode(), bcrypt.gensalt(10)).decode())" 2>/dev/null)
    if [ -z "$adg_hash" ]; then
        # Fallback — устанавливаем bcrypt и пробуем снова
        pip install bcrypt -q 2>/dev/null || apt-get install -y python3-bcrypt -qq 2>/dev/null
        adg_hash=$(python3 -c "import bcrypt; print(bcrypt.hashpw('$adg_password'.encode(), bcrypt.gensalt(10)).decode())" 2>/dev/null)
    fi
    if [ -z "$adg_hash" ]; then
        print_warn "Не удалось сгенерировать bcrypt-хеш — используется пароль по умолчанию 'AdGuard2024!'"
        adg_password="AdGuard2024!"
        adg_hash='$2y$10$sMBU7PYyTMnNXFzUQGKxuuLYF3h9Yc4ZPvqLQvtTf2vFpWmSGsHq'
    fi

    do_backup "before_adguard_install"

    # Устанавливаем
    print_step "Загрузка AdGuard Home..."
    if ! curl -sL --max-time 60 "https://static.adguard.com/adguardhome/release/AdGuardHome_linux_amd64.tar.gz" -o /tmp/adguard.tar.gz; then
        print_error "Не удалось скачать AdGuard Home — проверьте интернет"
        return 1
    fi

    tar -xzf /tmp/adguard.tar.gz -C /tmp/
    mkdir -p /opt/AdGuardHome
    cp /tmp/AdGuardHome/AdGuardHome /opt/AdGuardHome/
    chmod +x /opt/AdGuardHome/AdGuardHome
    /opt/AdGuardHome/AdGuardHome -s install > /dev/null 2>&1
    sleep 2

    cat > /opt/AdGuardHome/AdGuardHome.yaml << 'ADGEOF'
http:
  address: 0.0.0.0:80
  session_ttl: 720h
users:
  - name: admin
    password: $2y$10$sMBU7PYyTMnNXFzUQGKxuuLYF3h9Yc4ZPvqLQvtTf2vFpWmSGsHq
auth_attempts: 5
block_auth_min: 15
dns:
  bind_hosts:
    - 0.0.0.0
  port: 5353
  upstream_dns:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
  bootstrap_dns:
    - 1.1.1.1
    - 8.8.8.8
  filtering_enabled: true
  filters_update_interval: 24
filters:
  - enabled: true
    url: https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://blocklistproject.github.io/Lists/ads.txt
    name: BlocklistProject Ads
    id: 2
log_file: ""
verbose: false
ADGEOF

    systemctl restart AdGuardHome; sleep 2

    if systemctl is-active --quiet AdGuardHome; then
        print_ok "AdGuard Home установлен!"

        # Привязываем DNS в x-ui
        if [ -f "$DB" ]; then
            print_step "Привязка DNS → AdGuard (127.0.0.1:5353)..."
            sqlite3 "$DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('dns', '{\"servers\":[\"127.0.0.1:5353\"],\"tag\":\"dns_inbound\"}');" 2>/dev/null || true
            systemctl restart x-ui 2>/dev/null
            print_ok "DNS в 3x-ui → 127.0.0.1:5353"
        fi

        get_server_ip
        echo -e "\n${GREEN}AdGuard готов!${NC}"
        echo -e "Панель: ${GREEN}http://$SERVER_IP:80${NC}"
        echo -e "Логин:  ${GREEN}admin${NC}"
        echo -e "Пароль: ${GREEN}$adg_password${NC}"
        # Сохраняем пароль в файл (закрытый)
        echo "AdGuard пароль: $adg_password" > /root/adguard_creds.txt
        chmod 600 /root/adguard_creds.txt
        print_info "Пароль сохранён в /root/adguard_creds.txt (chmod 600)"
    else
        print_error "AdGuard не запустился — проверьте логи: journalctl -u AdGuardHome -n 20"
    fi

    rm -f /tmp/adguard.tar.gz
}

# ══════════════════════════════════════════════════════════════
# ПУНКТ 11: УПРАВЛЕНИЕ КЛИЕНТАМИ
# ══════════════════════════════════════════════════════════════

manage_clients() {
    print_section "УПРАВЛЕНИЕ КЛИЕНТАМИ"

    if ! systemctl is-active --quiet x-ui; then
        print_error "x-ui не запущен!"
        return 1
    fi

    while true; do
        echo -e "\n${CYAN}Inbound'ы и клиенты:${NC}"
        # Показываем всех клиентов по всем inbound'ам
        local idx=1
        declare -A CLIENT_MAP  # idx -> "inbound_id|client_idx|email|uuid"
        while IFS='|' read -r ib_id ib_port ib_remark ib_settings; do
            echo -e "\n  ${MAGENTA}▸ $ib_remark (порт $ib_port)${NC}"
            local ci=0
            while IFS= read -r line; do
                local cl_email cl_uuid cl_total cl_expiry cl_limit_ip cl_enabled
                cl_email=$(echo "$line" | python3 -c "import sys,json; c=json.loads(sys.stdin.read()); print(c.get('email','?'))" 2>/dev/null)
                cl_uuid=$(echo  "$line" | python3 -c "import sys,json; c=json.loads(sys.stdin.read()); print(c.get('id','?'))" 2>/dev/null)
                cl_total=$(echo "$line" | python3 -c "import sys,json; c=json.loads(sys.stdin.read()); t=c.get('totalGB',0); print(str(t//1073741824)+'GB' if t>0 else 'безлимит')" 2>/dev/null)
                cl_expiry=$(echo "$line" | python3 -c "
import sys,json,datetime
c=json.loads(sys.stdin.read())
e=c.get('expiryTime',0)
if e and e>0:
    print(datetime.datetime.fromtimestamp(e/1000).strftime('%d.%m.%Y'))
else:
    print('бессрочно')
" 2>/dev/null)
                cl_limit_ip=$(echo "$line" | python3 -c "import sys,json; c=json.loads(sys.stdin.read()); l=c.get('limitIp',0); print(str(l)+' уст.' if l>0 else 'без лимита')" 2>/dev/null)
                cl_enabled=$(echo "$line" | python3 -c "import sys,json; c=json.loads(sys.stdin.read()); print('вкл' if c.get('enable',True) else 'откл')" 2>/dev/null)
                echo -e "    ${GREEN}[$idx]${NC} ${cl_email}  uuid:${cl_uuid:0:8}…  трафик:${cl_total}  срок:${cl_expiry}  устр.:${cl_limit_ip}  ${cl_enabled}"
                CLIENT_MAP[$idx]="${ib_id}|${ci}|${cl_email}|${cl_uuid}"
                idx=$((idx + 1))
                ci=$((ci + 1))
            done < <(sqlite3 "$DB" "SELECT settings FROM inbounds WHERE id=$ib_id;" 2>/dev/null \
                | python3 -c "import sys,json; [print(json.dumps(c)) for c in json.load(sys.stdin).get('clients',[])]" 2>/dev/null)
        done < <(sqlite3 "$DB" "SELECT id,port,remark,settings FROM inbounds ORDER BY id;" 2>/dev/null)

        echo -e "\n${YELLOW}Действие:${NC}"
        echo "  d <N>) Удалить клиента"
        echo "  e <N>) Продлить срок клиента"
        echo "  s <N>) Статистика (трафик)"
        echo "  0)     Назад"
        read -r -p "> " action num

        case "$action" in
            0|"0") return ;;
            d)
                local entry="${CLIENT_MAP[$num]}"
                [ -z "$entry" ] && { print_error "Неверный номер"; continue; }
                IFS='|' read -r ib_id ci cl_email cl_uuid <<< "$entry"
                echo -e "${YELLOW}Удалить клиента '$cl_email'? (y/n)${NC}"
                read -r confirm
                [[ ! "$confirm" =~ ^[Yy]$ ]] && continue
                do_backup "before_delete_${cl_email}"
                local cur_settings new_settings_del py_in py_sc
                cur_settings=$(sqlite3 "$DB" "SELECT settings FROM inbounds WHERE id=$ib_id;")
                py_in=$(mktemp); py_sc=$(mktemp)
                echo "$cur_settings" > "$py_in"
                cat > "$py_sc" << PYEOF
import json, sys
with open('$py_in') as f:
    s = json.load(f)
s['clients'] = [c for c in s['clients'] if c.get('id') != '$cl_uuid']
print(json.dumps(s))
PYEOF
                new_settings_del=$(python3 "$py_sc")
                rm -f "$py_in" "$py_sc"
                local ns_esc
                ns_esc=$(echo "$new_settings_del" | python3 -c "import sys; print(sys.stdin.read().replace(\"'\", \"''\"))")
                sqlite3 "$DB" "PRAGMA journal_mode=WAL;"
                sqlite3 "$DB" "UPDATE inbounds SET settings='$ns_esc' WHERE id=$ib_id;"
                nohup systemctl restart x-ui > /tmp/xui_restart.log 2>&1 &
                sleep 3
                print_ok "Клиент '$cl_email' удалён"
                ;;
            e)
                local entry="${CLIENT_MAP[$num]}"
                [ -z "$entry" ] && { print_error "Неверный номер"; continue; }
                IFS='|' read -r ib_id ci cl_email cl_uuid <<< "$entry"
                read -r -p "Добавить дней (например 30): " add_days
                [[ ! "$add_days" =~ ^[0-9]+$ ]] && { print_error "Введите число"; continue; }
                do_backup "before_extend_${cl_email}"
                local cur_settings new_settings_ext py_in py_sc
                cur_settings=$(sqlite3 "$DB" "SELECT settings FROM inbounds WHERE id=$ib_id;")
                py_in=$(mktemp); py_sc=$(mktemp)
                echo "$cur_settings" > "$py_in"
                cat > "$py_sc" << PYEOF
import json, sys, time
with open('$py_in') as f:
    s = json.load(f)
for c in s['clients']:
    if c.get('id') == '$cl_uuid':
        cur = c.get('expiryTime', 0)
        base = cur if cur and cur > int(time.time()*1000) else int(time.time()*1000)
        c['expiryTime'] = base + $add_days * 86400 * 1000
print(json.dumps(s))
PYEOF
                new_settings_ext=$(python3 "$py_sc")
                rm -f "$py_in" "$py_sc"
                local ns_esc
                ns_esc=$(echo "$new_settings_ext" | python3 -c "import sys; print(sys.stdin.read().replace(\"'\", \"''\"))")
                sqlite3 "$DB" "PRAGMA journal_mode=WAL;"
                sqlite3 "$DB" "UPDATE inbounds SET settings='$ns_esc' WHERE id=$ib_id;"
                nohup systemctl restart x-ui > /tmp/xui_restart.log 2>&1 &
                sleep 3
                print_ok "Срок клиента '$cl_email' продлён на $add_days дней"
                ;;
            s)
                local entry="${CLIENT_MAP[$num]}"
                [ -z "$entry" ] && { print_error "Неверный номер"; continue; }
                IFS='|' read -r ib_id ci cl_email cl_uuid <<< "$entry"
                print_section "Статистика: $cl_email"
                local up down
                up=$(sqlite3   "$DB" "SELECT up   FROM client_traffics WHERE email='$cl_email';" 2>/dev/null || echo 0)
                down=$(sqlite3 "$DB" "SELECT down FROM client_traffics WHERE email='$cl_email';" 2>/dev/null || echo 0)
                [ -z "$up"   ] && up=0
                [ -z "$down" ] && down=0
                local up_mb down_mb total_mb
                up_mb=$(echo "$up"   | awk '{printf "%.2f", $1/1048576}')
                down_mb=$(echo "$down" | awk '{printf "%.2f", $1/1048576}')
                total_mb=$(echo "$up $down" | awk '{printf "%.2f", ($1+$2)/1048576}')
                echo -e "  Загружено:  ${GREEN}${down_mb} MB${NC}"
                echo -e "  Отправлено: ${GREEN}${up_mb} MB${NC}"
                echo -e "  Всего:      ${YELLOW}${total_mb} MB${NC}"
                ;;
            *) print_error "Неизвестная команда (d/e/s/0)" ;;
        esac
        unset CLIENT_MAP
        declare -A CLIENT_MAP
    done
}

# ══════════════════════════════════════════════════════════════
# ПУНКТ 12: ДОБАВИТЬ ПРЯМОЙ INBOUND (для прямого NL→Клиент)
# ══════════════════════════════════════════════════════════════

add_direct_inbound() {
    print_section "ДОБАВИТЬ ПРЯМОЙ INBOUND"

    if ! systemctl is-active --quiet x-ui; then
        print_error "x-ui не запущен!"
        return 1
    fi

    echo -e "${CYAN}Создаёт дополнительный inbound для прямого подключения"
    echo -e "телефона к этому серверу без промежуточного сервера.${NC}"
    echo -e "\n${YELLOW}Текущие inbound'ы:${NC}"
    sqlite3 "$DB" "SELECT port,remark FROM inbounds ORDER BY id;" 2>/dev/null \
        | while IFS='|' read -r p r; do echo "  порт $p → $r"; done

    # Порт
    read -r -p $'\nПорт для нового inbound (Enter=22107): ' NEW_PORT
    [ -z "$NEW_PORT" ] && NEW_PORT=22107

    # Имя
    read -r -p "Имя inbound (Enter=Direct_NL): " NEW_NAME
    [ -z "$NEW_NAME" ] && NEW_NAME="Direct_NL"

    # SNI
    echo -e "\n${YELLOW}SNI для маскировки:${NC}"
    echo "1) www.microsoft.com  2) www.google.com  3) ads.x5.ru  4) Свой"
    read -r sni_choice
    case $sni_choice in
        1) NEW_SNI="www.microsoft.com" ;;
        2) NEW_SNI="www.google.com" ;;
        3) NEW_SNI="ads.x5.ru" ;;
        4) read -r -p "SNI: " NEW_SNI ;;
        *) NEW_SNI="www.microsoft.com" ;;
    esac

    # Проверяем что порт не занят
    local port_used
    port_used=$(sqlite3 "$DB" "SELECT COUNT(*) FROM inbounds WHERE port=$NEW_PORT;" 2>/dev/null)
    if [ "$port_used" -gt 0 ]; then
        print_error "Порт $NEW_PORT уже используется другим inbound!"
        return 1
    fi

    echo -e "\n${CYAN}Параметры нового inbound:${NC}"
    echo -e "  Порт: ${GREEN}$NEW_PORT${NC}"
    echo -e "  Имя:  ${GREEN}$NEW_NAME${NC}"
    echo -e "  SNI:  ${GREEN}$NEW_SNI${NC}"
    echo -e "${YELLOW}Создать? (y/n)${NC}"
    read -r confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { print_info "Отменено"; return 0; }

    do_backup "before_add_inbound_${NEW_PORT}"

    # Генерируем новые ключи и клиента
    generate_x25519_keys
    generate_short_ids
    generate_client_data

    # Открываем порт в UFW
    if command -v ufw &>/dev/null; then
        ufw allow "$NEW_PORT"/tcp > /dev/null 2>&1
        print_ok "UFW: порт $NEW_PORT открыт"
    fi

    # Пишем inbound в БД
    write_inbound_to_db "$NEW_SNI" "$NEW_PORT" "$NEW_NAME"

    print_step "Перезапуск x-ui..."
    systemctl restart x-ui
    auto_rollback_if_failed || return 1

    # Генерируем ссылку
    get_server_ip
    local vless_link="vless://$CLIENT_UUID@$SERVER_IP:$NEW_PORT?type=tcp&security=reality&sni=$NEW_SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$FIRST_SHORT_ID&flow=xtls-rprx-vision#${NEW_NAME}-${CLIENT_EMAIL}"

    echo -e "\n${GREEN}"
    echo "╔══════════════════════════════════════════╗"
    echo "║       ПРЯМОЙ INBOUND СОЗДАН!             ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "Порт:           ${GREEN}$NEW_PORT${NC}"
    echo -e "SNI:            ${GREEN}$NEW_SNI${NC}"
    echo -e "Публичный ключ: ${GREEN}$PUBLIC_KEY${NC}"
    echo -e "Short ID:       ${GREEN}$FIRST_SHORT_ID${NC}"

    echo -e "\n${CYAN}━━━ Ссылка для прямого подключения ━━━${NC}"
    echo -e "${GREEN}$vless_link${NC}"

    # QR-код
    echo -e "\n${CYAN}━━━ QR-код ━━━${NC}"
    if command -v qrencode &>/dev/null; then
        qrencode -t ANSIUTF8 "$vless_link"
    else
        apt-get install -y qrencode > /dev/null 2>&1 && qrencode -t ANSIUTF8 "$vless_link" || print_warn "Скопируй ссылку вручную"
    fi

    # Сохраняем
    cat >> /root/vpn_clients.txt << EOF

=== Прямой inbound: $NEW_NAME ($(date '+%d.%m.%Y %H:%M')) ===
Порт:  $NEW_PORT
SNI:   $NEW_SNI
Ключ:  $PUBLIC_KEY
Ссылка: $vless_link
EOF
    chmod 600 /root/vpn_clients.txt
    print_ok "Данные сохранены в /root/vpn_clients.txt"
    print_info "Теперь добавь клиентов через пункт 5, выбрав inbound '$NEW_NAME'"
}



main_menu() {
    while true; do
        print_banner

        # Статус сервисов в шапке
        echo -e "${CYAN}Статус:${NC}"
        systemctl is-active --quiet x-ui        && echo -e "  x-ui:       ${GREEN}● работает${NC}"        || echo -e "  x-ui:       ${RED}● остановлен${NC}"
        systemctl is-active --quiet AdGuardHome && echo -e "  AdGuard:    ${GREEN}● работает${NC}"        || echo -e "  AdGuard:    ${YELLOW}● не установлен${NC}"
        [ -f "$DB" ]                            && echo -e "  БД x-ui:    ${GREEN}● найдена${NC}"         || echo -e "  БД x-ui:    ${RED}● отсутствует${NC}"
        echo ""

        echo -e "${CYAN}┌─────────────────────────────────────────┐${NC}"
        echo -e "${CYAN}│              Выберите действие          │${NC}"
        echo -e "${CYAN}├─────────────────────────────────────────┤${NC}"
        echo -e "${CYAN}│${NC}  1) Установить зарубежный сервер        ${CYAN}│${NC}"
        echo -e "${CYAN}│${NC}  2) Установить российский сервер        ${CYAN}│${NC}"
        echo -e "${CYAN}│${NC}  3) Восстановить из бэкапа              ${CYAN}│${NC}"
        echo -e "${CYAN}│${NC}  4) Обновить x-ui                       ${CYAN}│${NC}"
        echo -e "${CYAN}│${NC}  5) Добавить клиента                    ${CYAN}│${NC}"
        echo -e "${CYAN}│${NC}  6) Проверить связь                     ${CYAN}│${NC}"
        echo -e "${CYAN}│${NC}  7) Настроить cron                      ${CYAN}│${NC}"
        echo -e "${CYAN}│${NC}  8) Просмотр бэкапов                    ${CYAN}│${NC}"
        echo -e "${CYAN}│${NC}  9) Откат вручную                       ${CYAN}│${NC}"
        echo -e "${CYAN}│${NC} 10) Установить AdGuard Home (опц.)      ${CYAN}│${NC}"
        echo -e "${CYAN}│${NC} 11) Управление клиентами                ${CYAN}│${NC}"
        echo -e "${CYAN}│${NC} 12) Добавить прямой inbound (NL→клиент) ${CYAN}│${NC}"
        echo -e "${CYAN}│${NC}  0) Выход                               ${CYAN}│${NC}"
        echo -e "${CYAN}└─────────────────────────────────────────┘${NC}"
        echo ""
        read -r -p "Ваш выбор: " choice

        case $choice in
            1)  setup_foreign ;;
            2)  setup_russia ;;
            3)  restore_from_backup ;;
            4)  update_xui ;;
            5)  add_client ;;
            6)  check_connection ;;
            7)  setup_cron ;;
            8)  list_backups ;;
            9)  do_rollback ;;
            10) install_adguard_menu ;;
            11) manage_clients ;;
            12) add_direct_inbound ;;
            0)  echo -e "\n${GREEN}До свидания!${NC}\n"; exit 0 ;;
            *)  print_error "Неверный выбор" ;;
        esac

        echo -e "\n${YELLOW}Нажмите Enter для возврата в меню...${NC}"
        read -r
    done
}

# ══════════════════════════════════════════════════════════════
# ТОЧКА ВХОДА
# ══════════════════════════════════════════════════════════════

# Cron режимы — запускаются без меню
case "${1:-}" in
    --cron-geo)    cron_geo;    exit 0 ;;
    --cron-backup) cron_backup; exit 0 ;;
esac

check_root
main_menu
