#!/bin/bash
# ==============================================================================
# Интерактивный менеджер IP и DNS для Netplan (Версия 8.6)
# Исправлено: работа с существующим файлом Netplan, проверка дубликатов
# ==============================================================================

set -uo pipefail

# ---------- Цвета ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
info_stderr() { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
header(){ echo -e "\n${CYAN}═══════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}═══════════════════════════════════════════════════${NC}\n"; }

# Перехват сигналов
trap 'echo; warn "Прервано пользователем (SIGINT)."; exit 130' INT
trap 'echo; warn "Прервано (SIGTERM)."; exit 143' TERM

# ---------- Спиннер + Таймер ----------
run_cmd() {
    local description="$1"
    local timeout_sec="${2:-60}"
    shift 2
    
    local show_output="no"
    if [[ "${1:-}" == "yes" || "${1:-}" == "no" ]]; then
        show_output="$1"
        shift
    fi
    
    local cmd=("$@")

    echo -ne "${CYAN}[...]${NC} $description "
    local start_ms=$(date +%s%3N 2>/dev/null || echo "$(date +%s)000")
    local spin_chars=('' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '')
    local i=0
    local tmpfile
    tmpfile=$(mktemp)

    timeout --kill-after=2 "$timeout_sec" "${cmd[@]}" > "$tmpfile" 2>&1 &
    local pid=$!

    while kill -0 $pid 2>/dev/null; do
        local current_ms=$(date +%s%3N 2>/dev/null || echo "$(date +%s)000")
        local elapsed=$(( (current_ms - start_ms) / 1000 ))
        echo -ne "\r${CYAN}[${spin_chars[$i]}]${NC} $description (${elapsed}с)"
        i=$(( (i + 1) % ${#spin_chars[@]} ))
        sleep 0.1
    done

    wait $pid
    local exit_code=$?
    local end_ms=$(date +%s%3N 2>/dev/null || echo "$(date +%s)000")
    local duration_ms=$((end_ms - start_ms))
    local duration_sec=$((duration_ms / 1000))
    local duration_frac=$((duration_ms % 1000))
    local time_str
    time_str=$(printf "%d.%03d" "$duration_sec" "$duration_frac")

    if [[ $exit_code -eq 0 ]]; then
        echo -e "\r${GREEN}[✓]${NC} $description ${BLUE}(${time_str} сек)${NC}"
        if [[ "$show_output" == "yes" && -s "$tmpfile" ]]; then
            sed 's/^/  /' "$tmpfile"
        fi
    elif [[ $exit_code -eq 124 ]]; then
        echo -e "\r${RED}[⏱]${NC} $description ${RED}(таймаут ${timeout_sec}с)${NC}"
    else
        echo -e "\r${RED}[✗]${NC} $description ${BLUE}(${time_str} сек)${NC}"
        if [[ -s "$tmpfile" ]]; then
            echo -e "${RED}Детали:${NC}"
            sed 's/^/  /' "$tmpfile"
        fi
    fi
    rm -f "$tmpfile"
    return $exit_code
}

# ---------- Проверка прав и зависимостей ----------
if [[ $EUID -ne 0 ]]; then
    error "Скрипт нужно запускать от root (через sudo)."
    exit 1
fi

if ! command -v netplan &>/dev/null; then
    error "Утилита netplan не найдена. Установите: apt install netplan.io"
    exit 1
fi

# FIX: Ищем существующий файл Netplan, создаём новый только если нет ни одного
find_primary_netplan_file() {
    find /etc/netplan -maxdepth 1 -name '*.yaml' -type f 2>/dev/null | sort | head -n 1
}

NETPLAN_FILE=$(find_primary_netplan_file)
[[ -z "$NETPLAN_FILE" ]] && NETPLAN_FILE="/etc/netplan/99-static-ips.yaml"

check_python() {
    if ! command -v python3 &>/dev/null; then
        error "Python 3 не найден."
        exit 1
    fi
    if ! python3 -c "import yaml" 2>/dev/null; then
        warn "Модуль PyYAML не установлен. Устанавливаю..."
        run_cmd "Обновление списков пакетов" 60 no apt update -qq
        run_cmd "Установка python3-yaml" 60 no apt install -y -qq python3-yaml
        if ! python3 -c "import yaml" 2>/dev/null; then
            error "Не удалось установить PyYAML."
            exit 1
        fi
    fi
}
check_python

# ---------- Python-хелпер ----------
PYTHON_HELPER=$(cat <<'PYEOF'
import sys, yaml, os, re

def load(path):
    if not os.path.exists(path):
        return {}
    try:
        # Проверка на дубликаты ключей
        with open(path, 'r') as f:
            content = f.read()
        
        # Простая проверка дубликатов ключей в YAML
        lines = content.split('\n')
        for i, line in enumerate(lines):
            stripped = line.strip()
            if stripped.startswith('-') or ':' not in stripped:
                continue
            key = stripped.split(':')[0].strip()
            # Проверяем, есть ли этот же ключ на том же уровне вложенности
            indent = len(line) - len(line.lstrip())
            for j in range(i+1, len(lines)):
                next_line = lines[j]
                next_stripped = next_line.strip()
                next_indent = len(next_line) - len(next_line.lstrip())
                if next_indent == indent and next_stripped.startswith(key + ':'):
                    print(f"WARNING: Дублирующийся ключ '{key}' на строке {i+1} и {j+1}", file=sys.stderr)
        
        with open(path) as f:
            return yaml.safe_load(f) or {}
    except yaml.YAMLError as e:
        print(f"ERROR: Ошибка парсинга YAML в {path}: {e}", file=sys.stderr)
        sys.exit(2)

def save(path, cfg):
    with open(path, "w") as f:
        yaml.safe_dump(cfg, f, default_flow_style=False)
    os.chmod(path, 0o600)

if len(sys.argv) < 3:
    print("ERROR: слишком мало аргументов", file=sys.stderr)
    sys.exit(2)

action = sys.argv[1]
path   = sys.argv[2]
cfg    = load(path)

if action == "validate":
    if "network" not in cfg:
        print("ERROR: отсутствует раздел 'network'", file=sys.stderr)
        sys.exit(1)
    print("OK")
    sys.exit(0)

if action == "show_structure":
    net = cfg.get("network", {}) or {}
    renderer = net.get("renderer", "systemd-networkd (по умолчанию)")
    print(f"Renderer: {renderer}")
    for iface, ifcfg in (net.get("ethernets", {}) or {}).items():
        print(f"\nИнтерфейс: {iface}")
        if isinstance(ifcfg, dict):
            for k, v in ifcfg.items():
                print(f"  {k}: {v}")
    sys.exit(0)

if action == "get_dns":
    net = cfg.get("network", {}) or {}
    found = False
    for iface, ifcfg in (net.get("ethernets", {}) or {}).items():
        if isinstance(ifcfg, dict):
            addrs = (ifcfg.get("nameservers", {}) or {}).get("addresses", []) or []
            if addrs:
                print(f"{iface}|{','.join(str(a) for a in addrs)}")
                found = True
    if not found:
        print("EMPTY")
    sys.exit(0)

if action == "set_dns":
    if len(sys.argv) < 5:
        print("ERROR: не указаны аргументы", file=sys.stderr)
        sys.exit(2)
    iface = sys.argv[3]
    mode = sys.argv[4]  # "replace" или "append"
    dns_list = sys.argv[5:]
    
    net = cfg.setdefault("network", {})
    eth = net.setdefault("ethernets", {})
    if_cfg = eth.setdefault(iface, {})
    ns = if_cfg.setdefault("nameservers", {})
    
    current_addrs = ns.get("addresses", []) or []
    
    if mode == "append":
        for d in dns_list:
            if d not in current_addrs:
                current_addrs.append(d)
        ns["addresses"] = current_addrs
        print(f"DNS для {iface} дополнены: {', '.join(dns_list)}")
    else:
        ns["addresses"] = list(dns_list)
        print(f"DNS для {iface} заменены на: {', '.join(dns_list)}")
        
    save(path, cfg)
    sys.exit(0)

if action == "clear_dns":
    if len(sys.argv) < 4:
        print("ERROR: не указан интерфейс", file=sys.stderr)
        sys.exit(2)
    iface = sys.argv[3]
    eth = (cfg.get("network", {}) or {}).get("ethernets", {}) or {}
    if iface in eth and isinstance(eth[iface], dict) and "nameservers" in eth[iface]:
        del eth[iface]["nameservers"]
        save(path, cfg)
        print(f"DNS для {iface} очищен")
    sys.exit(0)

if len(sys.argv) < 4:
    print("ERROR: не указан интерфейс", file=sys.stderr)
    sys.exit(2)

iface = sys.argv[3]

if action == "check_iface":
    eth = (cfg.get("network", {}) or {}).get("ethernets", {}) or {}
    sys.exit(0 if iface in eth else 1)

if action == "add_iface":
    net = cfg.setdefault("network", {})
    eth = net.setdefault("ethernets", {})
    if_cfg = eth.setdefault(iface, {})
    dhcp_mode = sys.argv[4] if len(sys.argv) > 4 else "keep"
    if dhcp_mode == "yes":
        if_cfg["dhcp4"] = True
        if_cfg["dhcp6"] = True
    elif dhcp_mode == "no":
        if_cfg["dhcp4"] = False
        if_cfg["dhcp6"] = False
        if_cfg.setdefault("addresses", [])
    save(path, cfg)
    print(f"Секция {iface} создана (dhcp: {dhcp_mode})")
    sys.exit(0)

if action == "add_ips":
    net = cfg.setdefault("network", {})
    eth = net.setdefault("ethernets", {})
    if_cfg = eth.setdefault(iface, {})
    ips = sys.argv[4:]
    existing = set(if_cfg.get("addresses", []) or [])
    added = 0
    for ip in ips:
        if ip not in existing:
            if_cfg.setdefault("addresses", []).append(ip)
            existing.add(ip)
            print(f"  + {ip}")
            added += 1
        else:
            print(f"  = {ip} (уже есть)")
    if added == 0:
        print("Все адреса уже были в конфигурации.")
        sys.exit(0)
    save(path, cfg)
    sys.exit(0)

if action == "list_ips":
    net = cfg.get("network", {}) or {}
    eth = net.get("ethernets", {}) or {}
    if_cfg = eth.get(iface, {}) or {}
    addrs = if_cfg.get("addresses", []) or []
    if not addrs:
        print("EMPTY")
        sys.exit(0)
    for i, a in enumerate(addrs):
        print(f"{i+1}|{a}")
    sys.exit(0)

if action == "count_ips":
    net = cfg.get("network", {}) or {}
    eth = net.get("ethernets", {}) or {}
    if_cfg = eth.get(iface, {}) or {}
    print(len(if_cfg.get("addresses", []) or []))
    sys.exit(0)

if action == "remove_ip":
    net = cfg.setdefault("network", {})
    eth = net.setdefault("ethernets", {})
    if_cfg = eth.setdefault(iface, {})
    ip_addr = sys.argv[4]
    addrs = if_cfg.get("addresses", []) or []
    if ip_addr in addrs:
        addrs.remove(ip_addr)
        if addrs:
            if_cfg["addresses"] = addrs
        else:
            del if_cfg["addresses"]
        save(path, cfg)
    else:
        print(f"IP {ip_addr} не найден.", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)

if action == "remove_iface":
    eth = (cfg.get("network", {}) or {}).get("ethernets", {}) or {}
    if iface in eth:
        del eth[iface]
        save(path, cfg)
        print(f"Секция {iface} удалена из {path}")
    else:
        print(f"Секция {iface} не найдена", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)
PYEOF
)

# ---------- Предустановленные DNS-провайдеры ----------
declare -A DNS_PROVIDERS=(
    ["cloudflare"]="Cloudflare (1.1.1.1, 1.0.0.1)"
    ["google"]="Google Public DNS (8.8.8.8, 8.8.4.4)"
    ["quad9"]="Quad9 (9.9.9.9, 149.112.112.112)"
    ["opendns"]="OpenDNS (208.67.222.222, 208.67.220.220)"
    ["adguard"]="AdGuard DNS (94.140.14.14, 94.140.15.15)"
)
declare -A DNS_IPV4=(
    ["cloudflare"]="1.1.1.1 1.0.0.1"
    ["google"]="8.8.8.8 8.8.4.4"
    ["quad9"]="9.9.9.9 149.112.112.112"
    ["opendns"]="208.67.222.222 208.67.220.220"
    ["adguard"]="94.140.14.14 94.140.15.15"
)
declare -A DNS_IPV6=(
    ["cloudflare"]="2606:4700:4700::1111 2606:4700:4700::1001"
    ["google"]="2001:4860:4860::8888 2001:4860:4860::8844"
    ["quad9"]="2620:fe::fe 2620:fe::9"
    ["opendns"]="2620:119:35::35 2620:119:53::53"
    ["adguard"]="2a10:50c0::ad1:ff 2a10:50c0::ad2:ff"
)

# ---------- Утилиты ----------

get_interfaces() {
    ip -o link show | awk -F': ' '$2 !~ /^(lo|docker|veth|br-|br[0-9]+|virbr|tun|tap|wg|bond|team)/ {print $2}'
}

find_any_netplan_file() {
    find /etc/netplan -maxdepth 1 -name '*.yaml' -type f 2>/dev/null | sort | head -n 1
}

# FIX: Используем существующий файл или создаём новый
ensure_netplan_file() {
    local existing_file
    existing_file=$(find_primary_netplan_file)
    
    if [[ -n "$existing_file" ]]; then
        # Используем существующий файл
        NETPLAN_FILE="$existing_file"
        info_stderr "Используем существующий файл: $NETPLAN_FILE"
    else
        # Создаём новый файл
        if [[ ! -f "$NETPLAN_FILE" ]]; then
            local renderer="networkd"
            if grep -qE "renderer:[[:space:]]*NetworkManager" /etc/netplan/*.yaml 2>/dev/null; then
                renderer="NetworkManager"
            fi
            
            info_stderr "Создаю $NETPLAN_FILE"
            cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  renderer: $renderer
  ethernets: {}
EOF
            chmod 600 "$NETPLAN_FILE"
        fi
    fi
    printf '%s\n' "$NETPLAN_FILE"
}

create_backup() {
    local src="$1"
    local dst="$2"
    install -m 600 "$src" "$dst"
    find /etc/netplan -maxdepth 1 -name '*.bak.[0-9][0-9][0-9][0-9]*' -type f -mtime +30 -delete 2>/dev/null || true
}

get_active_dns() {
    local dns=""
    if command -v resolvectl &>/dev/null; then
        dns=$(resolvectl dns 2>/dev/null | awk -F': ' 'NF>1 {print $2}' | tr '\n' ' ' | xargs)
    fi
    if [[ -z "$dns" ]] && [[ -f /etc/resolv.conf ]]; then
        dns=$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ' | xargs)
    fi
    echo "$dns"
}

is_valid_ipv4() {
    local ip_addr="$1"
    [[ "$ip_addr" == "0.0.0.0" ]] && return 1
    [[ "$ip_addr" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || return 1
    local IFS='.'
    local -a octets=($ip_addr)
    local o
    for o in "${octets[@]}"; do
        (( 10#$o >= 0 && 10#$o <= 255 )) || return 1
    done
    return 0
}

is_valid_cidr() {
    local cidr="$1"
    [[ "$cidr" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})/([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
    is_valid_ipv4 "${cidr%/*}"
}

is_valid_ipv6() {
    local ip_addr="$1"
    [[ "$ip_addr" == "::" || "$ip_addr" == "0.0.0.0" ]] && return 1
    python3 -c 'import ipaddress,sys
try:
    ipaddress.IPv6Address(sys.argv[1])
    sys.exit(0)
except (ValueError, IndexError):
    sys.exit(1)' "$ip_addr" 2>/dev/null
}

get_ssh_ip() {
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        echo "$SSH_CONNECTION" | awk '{print $3}'
    elif [[ -n "${SSH_CLIENT:-}" ]]; then
        echo "${SSH_CLIENT}" | awk '{print $1}'
    else
        local current_tty=$(tty 2>/dev/null | sed 's|/dev/||')
        ss -tnp 2>/dev/null | grep "ssh" | grep "$current_tty" | awk '{print $5}' | cut -d: -f1 | head -n 1
    fi
}

# ---------- Безопасное применение Netplan ----------
apply_netplan_safely() {
    local netplan_file="$1"
    local backup="$2"
    local mode="${3:-try}"

    if [[ "$mode" == "try" && ! -t 0 ]]; then
        warn "netplan try требует интерактивный stdin, переключаюсь на apply."
        mode="apply"
    fi

    if [[ "$mode" == "try" ]]; then
        info "Проверка синтаксиса..."
        local errfile
        errfile=$(mktemp)
        
        if ! netplan generate 2>"$errfile"; then
            error "netplan generate не прошёл. Проверьте вывод:"
            sed 's/^/  /' "$errfile"
            warn "Восстанавливаю резервную копию и откатываю изменения..."
            install -m 600 "$backup" "$netplan_file"
            netplan apply 2>/dev/null || true
            rm -f "$errfile"
            return 1
        fi
        rm -f "$errfile"

        echo
        echo -e "${YELLOW}>>> Внимание: 'netplan try' применит конфиг на 120 секунд.${NC}"
        echo -e "${YELLOW}>>> Если связь по SSH пропадёт — НЕ подтверждайте, изменения откатятся сами.${NC}"
        echo -e "${YELLOW}>>> Для подтверждения успешного применения нажмите Enter.${NC}"
        echo

        trap - INT
        if netplan try --timeout 120; then
            ok "Конфигурация применена и подтверждена."
            trap 'echo; warn "Прервано пользователем (SIGINT)."; exit 130' INT
            return 0
        else
            error "Конфиг не подтверждён или отменён. Выполняю принудительный откат..."
            trap 'echo; warn "Прервано пользователем (SIGINT)."; exit 130' INT
            if [[ -n "$backup" && -f "$backup" ]]; then
                install -m 600 "$backup" "$netplan_file"
                netplan apply 2>/dev/null || true
                info "Восстановлен бэкап: $backup"
            fi
            return 1
        fi
    else
        if run_cmd "Применение настроек (netplan apply)" 60 no netplan apply; then
            return 0
        else
            warn "netplan apply не сработал. Восстанавливаю резервную копию..."
            install -m 600 "$backup" "$netplan_file"
            netplan apply 2>/dev/null || true
            return 1
        fi
    fi
}

# ---------- Отображение статуса ----------
show_initial_status() {
    header "Текущий статус сетевых интерфейсов"
    local netplan_file="$NETPLAN_FILE"
    [[ ! -f "$netplan_file" ]] && netplan_file=$(find_any_netplan_file)

    while IFS= read -r iface; do
        [[ -z "$iface" ]] && continue
        echo -e "${BLUE}🔹 Интерфейс:${NC} $iface"

        local active_ips
        active_ips=$(ip addr show dev "$iface" 2>/dev/null | awk '/inet[6]? / {print $2}' | tr '\n' ' ')
        if [[ -n "$active_ips" ]]; then
            echo -e "   ${GREEN}Активные IP:${NC} $active_ips"
        else
            echo -e "   ${YELLOW}Активные IP:${NC} (нет)"
        fi

        if [[ -n "$netplan_file" ]] && python3 -c "$PYTHON_HELPER" check_iface "$netplan_file" "$iface" 2>/dev/null; then
            local netplan_ips
            netplan_ips=$(python3 -c "$PYTHON_HELPER" list_ips "$netplan_file" "$iface" 2>/dev/null | grep -v '^EMPTY$' | cut -d'|' -f2 | tr '\n' ' ')
            if [[ -n "$netplan_ips" ]]; then
                echo -e "   ${CYAN}IP в конфиге:${NC} $netplan_ips"
            fi

            local netplan_dns
            netplan_dns=$(python3 -c "$PYTHON_HELPER" get_dns "$netplan_file" 2>/dev/null | grep "^$iface|" | cut -d'|' -f2)
            if [[ -n "$netplan_dns" ]]; then
                echo -e "   ${MAGENTA}DNS в Netplan:${NC} ${netplan_dns//,/ }"
            else
                echo -e "   ${MAGENTA}DNS в Netplan:${NC} (не задан)"
            fi
        else
            echo -e "   ${CYAN}IP в Netplan:${NC} (не описан)"
        fi
        echo
    done < <(get_interfaces)

    local active_dns
    active_dns=$(get_active_dns)
    if [[ -n "$active_dns" ]]; then
        echo -e "${GREEN}🌐 Активные DNS в системе:${NC} $active_dns"
    else
        echo -e "${YELLOW}🌐 Активные DNS в системе:${NC} не определены"
    fi
    echo
}

# ---------- Ввод и выбор ----------

safe_read() {
    if ! read -r "$@"; then
        warn "Обнаружен EOF, завершаю текущую операцию."
        return 1
    fi
    return 0
}

select_interface() {
    header "Выбор сетевого интерфейса"
    local ifaces
    mapfile -t ifaces < <(get_interfaces)

    if [[ ${#ifaces[@]} -eq 0 ]]; then
        error "Не найдено сетевых интерфейсов."
        return 1
    fi

    echo "Доступные интерфейсы:"
    local i
    for i in "${!ifaces[@]}"; do
        local iface=${ifaces[$i]}
        local ip_count
        ip_count=$(ip -4 addr show dev "$iface" 2>/dev/null | grep -c 'inet ' || true)
        echo -e "  ${GREEN}$((i+1))${NC}) $iface ($ip_count IPv4 адресов)"
    done
    echo

    while true; do
        local choice
        safe_read -p "Выберите номер интерфейса [1-${#ifaces[@]}]: " choice || return 1
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ifaces[@]} )); then
            SELECTED_IFACE="${ifaces[$((choice-1))]}"
            info "Выбран интерфейс: $SELECTED_IFACE"
            return 0
        else
            warn "Некорректный выбор."
        fi
    done
}

input_ips() {
    header "Ввод IP-адресов"
    echo -e "${YELLOW}Введите IP с маской (например, 192.168.1.100/24).${NC}"
    echo -e "${YELLOW}Пустая строка — завершение ввода.${NC}\n"

    local ips=()
    local counter=1
    while true; do
        local ip_addr
        safe_read -p "IP #$counter (или Enter): " ip_addr || return 1
        [[ -z "$ip_addr" ]] && break
        if ! is_valid_cidr "$ip_addr"; then
            warn "Некорректный формат. Используйте: 192.168.1.100/24 (маска 0-32, без ведущих нулей)."
            continue
        fi
        ips+=("$ip_addr")
        info "Добавлен в список: $ip_addr"
        ((counter++))
    done

    if [[ ${#ips[@]} -eq 0 ]]; then
        warn "Не введено ни одного IP."
        return 1
    fi
    INPUT_IPS=("${ips[@]}")
    return 0
}

show_netplan_config() {
    header "Текущая конфигурация Netplan"
    local netplan_file
    netplan_file=$(find_any_netplan_file)
    if [[ -z "$netplan_file" ]]; then
        warn "Файлы конфигурации Netplan не найдены."
        return 1
    fi
    echo -e "${BLUE}Найден файл:${NC} $netplan_file\n"
    [[ -f "$netplan_file" ]] && cat "$netplan_file"
    echo
    echo -e "${BLUE}Структура конфига:${NC}"
    python3 -c "$PYTHON_HELPER" show_structure "$netplan_file"
}

# ---------- Операции с IP ----------

add_ips_to_netplan() {
    local iface=$1
    shift
    local ips=("$@")
    local netplan_file
    netplan_file=$(ensure_netplan_file)

    local backup="${netplan_file}.bak.$(date +%Y%m%d-%H%M%S)"
    create_backup "$netplan_file" "$backup"
    info "Бэкап создан: $backup"

    if ! python3 -c "$PYTHON_HELPER" check_iface "$netplan_file" "$iface"; then
        warn "Интерфейс '$iface' не описан в $netplan_file."
        echo "  Как настроить интерфейс?"
        echo -e "    ${GREEN}1${NC}) Только статика (dhcp4: false) — рекомендуется"
        echo -e "    ${GREEN}2${NC}) Статика + DHCP одновременно"
        echo -e "    ${GREEN}3${NC}) Не задавать dhcp4/dhcp6 (наследовать из других файлов)"
        echo -e "    ${RED}0${NC}) Отмена"
        local dhcp_choice
        safe_read -p "Выбор [0-3]: " dhcp_choice || return 1
        
        local iface_ok=0
        case "$dhcp_choice" in
            1) python3 -c "$PYTHON_HELPER" add_iface "$netplan_file" "$iface" no && iface_ok=1 ;;
            2) python3 -c "$PYTHON_HELPER" add_iface "$netplan_file" "$iface" yes && iface_ok=1 ;;
            3) python3 -c "$PYTHON_HELPER" add_iface "$netplan_file" "$iface" keep && iface_ok=1 ;;
            0|*) info "Отменено."; install -m 600 "$backup" "$netplan_file"; return 1 ;;
        esac
        if [[ $iface_ok -ne 1 ]]; then
            error "Ошибка создания секции интерфейса. Откат..."
            install -m 600 "$backup" "$netplan_file"
            netplan apply 2>/dev/null || true
            return 1
        fi
        info "Базовая запись для $iface создана."
    fi

    info "Изменение конфигурации:"
    if ! python3 -c "$PYTHON_HELPER" add_ips "$netplan_file" "$iface" "${ips[@]}"; then
        error "Ошибка при добавлении IP в конфигурацию. Откат..."
        install -m 600 "$backup" "$netplan_file"
        netplan apply 2>/dev/null || true
        return 1
    fi

    if ! python3 -c "$PYTHON_HELPER" validate "$netplan_file"; then
        error "Ошибка в нашем YAML! Откатываю бэкап..."
        install -m 600 "$backup" "$netplan_file"
        netplan apply 2>/dev/null || true
        return 1
    fi
    info "✓ Синтаксис корректен"

    echo
    echo -e "  ${GREEN}1${NC}) Безопасно: 'netplan try' с автооткатом через 120 сек (рекомендуется)"
    echo -e "  ${GREEN}2${NC}) Обычно: 'netplan apply' (без отката, быстрее)"
    echo -e "  ${GREEN}3${NC}) Не применять сейчас (только сохранить в файл)"
    local apply_choice
    safe_read -p "Выбор [1]: " apply_choice || return 1
    apply_choice=${apply_choice:-1}

    local result="failed"
    case "$apply_choice" in
        1) apply_netplan_safely "$netplan_file" "$backup" try && result="applied" ;;
        2) 
            if apply_netplan_safely "$netplan_file" "$backup" apply; then
                result="applied"
            else
                result="failed"
            fi
            ;;
        3) result="saved" ;;
        *) result="bad_choice" ;;
    esac

    case "$result" in
        applied) info "✅ Конфигурация обновлена!" ;;
        saved)   info "💾 Изменения сохранены. Примените: sudo netplan apply" ;;
        bad_choice) warn "⚠ Некорректный выбор. Примените вручную: sudo netplan apply" ;;
        failed)  warn " Изменения не применены (произошёл откат к резервной копии)." ;;
    esac
}

remove_ip_from_netplan() {
    local iface=$1
    local netplan_file
    netplan_file=$(ensure_netplan_file)

    local list
    list=$(python3 -c "$PYTHON_HELPER" list_ips "$netplan_file" "$iface" 2>/dev/null)
    if [[ "$list" == "EMPTY" || -z "$list" ]]; then
        warn "На $iface нет дополнительных IP в $netplan_file."
        return 1
    fi

    local total
    total=$(python3 -c "$PYTHON_HELPER" count_ips "$netplan_file" "$iface" 2>/dev/null) || true
    total=${total:-0}
    [[ "$total" =~ ^[0-9]+$ ]] || total=0

    header "Удаление IP с $iface"
    echo "Доступные адреса в конфиге:"
    local addrs=()
    while IFS='|' read -r num ip_addr; do
        echo -e "  ${GREEN}$num${NC}) $ip_addr"
        addrs+=("$ip_addr")
    done <<< "$list"
    echo -e "  ${RED}0${NC}) Отмена"
    echo

    local choice
    while true; do
        safe_read -p "Выберите номер для удаления [0-${#addrs[@]}]: " choice || return 1
        [[ "$choice" == "0" ]] && { info "Отмена."; return 0; }
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#addrs[@]} )); then
            break
        fi
        warn "Некорректный выбор."
    done

    local ip_to_remove="${addrs[$((choice-1))]}"
    local remove_whole_section="n"

    local ip_only="${ip_to_remove%/*}"
    local ssh_ip
    ssh_ip=$(get_ssh_ip)
    if [[ -n "$ssh_ip" && "$ip_only" == "$ssh_ip" ]]; then
        error "⚠ Вы пытаетесь удалить IP, через который подключены по SSH: $ssh_ip"
        local force
        safe_read -p "Введите YES заглавными буквами для подтверждения: " force || return 1
        [[ "$force" == "YES" ]] || { info "Отменено."; return 0; }
    fi

    if (( total <= 1 )); then
        warn "Это последний IP в конфиге для $iface."
        echo "Удаление последнего IP может:"
        echo "  • оставить пустую секцию (dhcp4/dhcp6 без addresses)"
        echo "  • или удалить секцию целиком (интерфейс вернётся к другим источникам конфигурации)"
        echo
        echo -e "  ${GREEN}1${NC}) Удалить только IP (секция останется)"
        echo -e "  ${GREEN}2${NC}) Удалить всю секцию интерфейса из $netplan_file"
        echo -e "  ${RED}0${NC}) Отмена"
        local section_choice
        safe_read -p "Выбор [0-2]: " section_choice || return 1
        case "$section_choice" in
            1) remove_whole_section="n" ;;
            2) remove_whole_section="y" ;;
            0|*) info "Отменено."; return 0 ;;
        esac
    fi

    warn "Вы собираетесь удалить IP: $ip_to_remove"
    local confirm
    safe_read -p "Продолжить? (y/N): " confirm || return 1
    [[ "${confirm,,}" != "y" ]] && { info "Отменено."; return 0; }

    local backup="${netplan_file}.bak.$(date +%Y%m%d-%H%M%S)"
    create_backup "$netplan_file" "$backup"
    info "Бэкап создан: $backup"

    if [[ "$remove_whole_section" == "y" ]]; then
        if ! python3 -c "$PYTHON_HELPER" remove_iface "$netplan_file" "$iface"; then
            error "Python-хелпер вернул ошибку. Откат."
            install -m 600 "$backup" "$netplan_file"
            netplan apply 2>/dev/null || true
            return 1
        fi
    else
        if ! python3 -c "$PYTHON_HELPER" remove_ip "$netplan_file" "$iface" "$ip_to_remove"; then
            error "Python-хелпер вернул ошибку. Откат."
            install -m 600 "$backup" "$netplan_file"
            netplan apply 2>/dev/null || true
            return 1
        fi
    fi

    if ! python3 -c "$PYTHON_HELPER" validate "$netplan_file"; then
        error "Ошибка синтаксиса! Откатываю бэкап..."
        install -m 600 "$backup" "$netplan_file"
        netplan apply 2>/dev/null || true
        return 1
    fi
    info "✓ Синтаксис корректен"

    echo
    echo -e "  ${GREEN}1${NC}) Безопасно: 'netplan try' с автооткатом"
    echo -e "  ${GREEN}2${NC}) Обычно: 'netplan apply'"
    echo -e "  ${GREEN}3${NC}) Не применять сейчас"
    local apply_choice
    safe_read -p "Выбор [1]: " apply_choice || return 1
    apply_choice=${apply_choice:-1}

    local result="failed"
    case "$apply_choice" in
        1)
            if apply_netplan_safely "$netplan_file" "$backup" try; then
                if [[ "$remove_whole_section" == "n" ]]; then
                    ip addr del "$ip_to_remove" dev "$iface" 2>/dev/null || true
                fi
                result="applied"
            else
                result="failed"
            fi
            ;;
        2)
            if apply_netplan_safely "$netplan_file" "$backup" apply; then
                if [[ "$remove_whole_section" == "n" ]]; then
                    ip addr del "$ip_to_remove" dev "$iface" 2>/dev/null || true
                fi
                result="applied"
            else
                result="failed"
            fi
            ;;
        3) result="saved" ;;
        *) result="bad_choice" ;;
    esac

    case "$result" in
        applied) info "✅ IP $ip_to_remove удалён!" ;;
        saved)   info "💾 Изменения сохранены. Примените: sudo netplan apply" ;;
        bad_choice) warn "⚠ Некорректный выбор. Примените вручную: sudo netplan apply" ;;
        failed)  warn "⚠ Откат. IP остался в конфиге." ;;
    esac
}

# ---------- Управление DNS ----------

show_dns_menu() {
    header "Управление DNS-серверами"
    echo "Выберите DNS-провайдера:"
    echo -e "  ${GREEN}1${NC}) Cloudflare    ${CYAN}(1.1.1.1, 1.0.0.1)${NC} — быстрый, приватный"
    echo -e "  ${GREEN}2${NC}) Google        ${CYAN}(8.8.8.8, 8.8.4.4)${NC} — стандартный"
    echo -e "  ${GREEN}3${NC}) Quad9         ${CYAN}(9.9.9.9, 149.112.112.112)${NC} — безопасность"
    echo -e "  ${GREEN}4${NC}) OpenDNS       ${CYAN}(208.67.222.222, 208.67.220.220)${NC} — Cisco"
    echo -e "  ${GREEN}5${NC}) AdGuard DNS   ${CYAN}(94.140.14.14, 94.140.15.15)${NC} — блокировка рекламы"
    echo -e "  ${GREEN}6${NC}) Ввести свои DNS-серверы"
    echo -e "  ${YELLOW}7${NC}) Показать текущие DNS"
    echo -e "  ${RED}8${NC}) Очистить DNS (использовать системные)"
    echo -e "  ${BLUE}9${NC}) ← Назад в главное меню"
    echo
}

input_custom_dns() {
    header "Ввод пользовательских DNS"
    echo -e "${YELLOW}Введите DNS-серверы (IPv4 и/или IPv6).${NC}"
    echo -e "${YELLOW}Пустая строка — завершение ввода.${NC}\n"

    local dns=()
    local counter=1
    while true; do
        local dns_ip
        safe_read -p "DNS #$counter (или Enter): " dns_ip || return 1
        [[ -z "$dns_ip" ]] && break

        if is_valid_ipv4 "$dns_ip" || is_valid_ipv6 "$dns_ip"; then
            dns+=("$dns_ip")
            info "Добавлен: $dns_ip"
            ((counter++))
        else
            warn "Некорректный формат IP-адреса."
        fi
    done

    if [[ ${#dns[@]} -eq 0 ]]; then
        warn "Не введено ни одного DNS."
        return 1
    fi
    CUSTOM_DNS=("${dns[@]}")
    return 0
}

apply_dns_to_netplan() {
    local iface=$1
    shift
    local dns_list=("$@")
    local netplan_file
    netplan_file=$(ensure_netplan_file)

    # Проверяем, есть ли уже DNS для этого интерфейса
    local existing_dns
    existing_dns=$(python3 -c "$PYTHON_HELPER" get_dns "$netplan_file" 2>/dev/null | grep "^$iface|" | cut -d'|' -f2)

    local mode="replace"
    if [[ -n "$existing_dns" ]]; then
        echo
        warn "Для интерфейса $iface уже настроены DNS: ${existing_dns//,/ }"
        echo -e "  ${GREEN}1${NC}) Заменить старые DNS на новые (рекомендуется)"
        echo -e "  ${GREEN}2${NC}) Добавить новые DNS к существующим"
        echo -e "  ${RED}0${NC}) Отмена"
        local dns_choice
        safe_read -p "Ваш выбор [1]: " dns_choice || return 1
        dns_choice=${dns_choice:-1}

        case "$dns_choice" in
            1) mode="replace" ;;
            2) mode="append" ;;
            0|*) info "Отменено."; return 1 ;;
        esac
    fi

    # Бэкап создаётся ДО любых модификаций
    local backup="${netplan_file}.bak.$(date +%Y%m%d-%H%M%S)"
    create_backup "$netplan_file" "$backup"
    info "Бэкап создан: $backup"

    if ! python3 -c "$PYTHON_HELPER" check_iface "$netplan_file" "$iface"; then
        warn "Интерфейс '$iface' не описан в $netplan_file."
        local ans
        safe_read -p "Создать секцию с dhcp4: false (только статика)? (Y/n): " ans || return 1
        if [[ "${ans,,}" != "n" ]]; then
            if ! python3 -c "$PYTHON_HELPER" add_iface "$netplan_file" "$iface" no; then
                error "Ошибка создания секции интерфейса. Откат..."
                install -m 600 "$backup" "$netplan_file"
                netplan apply 2>/dev/null || true
                return 1
            fi
        else
            install -m 600 "$backup" "$netplan_file"
            return 1
        fi
    fi

    info "Применяю изменения DNS (режим: $mode)..."
    
    if ! python3 -c "$PYTHON_HELPER" set_dns "$netplan_file" "$iface" "$mode" "${dns_list[@]}"; then
        error "Ошибка при установке DNS. Откат..."
        install -m 600 "$backup" "$netplan_file"
        netplan apply 2>/dev/null || true
        return 1
    fi

    if ! python3 -c "$PYTHON_HELPER" validate "$netplan_file"; then
        error "Ошибка в YAML! Откатываю бэкап..."
        install -m 600 "$backup" "$netplan_file"
        netplan apply 2>/dev/null || true
        return 1
    fi
    info "✓ Синтаксис корректен"

    echo
    echo -e "  ${GREEN}1${NC}) Безопасно: 'netplan try'"
    echo -e "  ${GREEN}2${NC}) Обычно: 'netplan apply'"
    echo -e "  ${GREEN}3${NC}) Не применять сейчас"
    local apply_choice
    safe_read -p "Выбор [1]: " apply_choice || return 1
    apply_choice=${apply_choice:-1}

    local result="failed"
    case "$apply_choice" in
        1) apply_netplan_safely "$netplan_file" "$backup" try && result="applied" ;;
        2) apply_netplan_safely "$netplan_file" "$backup" apply && result="applied" ;;
        3) result="saved" ;;
        *) result="bad_choice" ;;
    esac

    case "$result" in
        applied) info "✅ Конфигурация DNS обновлена!" ;;
        saved)   info "💾 Изменения сохранены. Примените: sudo netplan apply" ;;
        bad_choice) warn "⚠ Некорректный выбор. Примените вручную: sudo netplan apply" ;;
        failed)  warn "⚠ Изменения не применены (произошёл откат к резервной копии)." ;;
    esac
}

dns_management() {
    while true; do
        show_dns_menu
        local choice
        safe_read -p "Ваш выбор [1-9]: " choice || return 1

        case $choice in
            [1-5])
                local provider=""
                case $choice in
                    1) provider="cloudflare" ;;
                    2) provider="google" ;;
                    3) provider="quad9" ;;
                    4) provider="opendns" ;;
                    5) provider="adguard" ;;
                esac
                [[ -z "$provider" ]] && { error "Не удалось определить провайдера!"; continue; }

                select_interface || { safe_read -p "Нажмите Enter..."; continue; }

                local use_ipv6
                safe_read -p "Добавить IPv6 DNS? (y/N): " use_ipv6 || continue

                local dns_list=()
                local ip_addr
                for ip_addr in ${DNS_IPV4[$provider]}; do dns_list+=("$ip_addr"); done
                if [[ "${use_ipv6,,}" == "y" ]]; then
                    for ip_addr in ${DNS_IPV6[$provider]}; do dns_list+=("$ip_addr"); done
                fi

                echo
                info "Будут установлены DNS провайдера ${DNS_PROVIDERS[$provider]}:"
                local d
                for d in "${dns_list[@]}"; do echo "  • $d"; done
                echo
                local confirm
                safe_read -p "Применить на $SELECTED_IFACE? (y/N): " confirm || continue
                if [[ "${confirm,,}" == "y" ]]; then
                    apply_dns_to_netplan "$SELECTED_IFACE" "${dns_list[@]}"
                else
                    info "Отменено."
                fi
                ;;
            6)
                select_interface || { safe_read -p "Нажмите Enter..."; continue; }
                if input_custom_dns; then
                    echo
                    info "Будут установлены пользовательские DNS:"
                    local d
                    for d in "${CUSTOM_DNS[@]}"; do echo "  • $d"; done
                    echo
                    local confirm
                    safe_read -p "Применить на $SELECTED_IFACE? (y/N): " confirm || continue
                    if [[ "${confirm,,}" == "y" ]]; then
                        apply_dns_to_netplan "$SELECTED_IFACE" "${CUSTOM_DNS[@]}"
                    else
                        info "Отменено."
                    fi
                fi
                ;;
            7)
                header "Текущие DNS"
                local netplan_file
                netplan_file=$(find_any_netplan_file)
                if [[ -n "$netplan_file" ]]; then
                    echo -e "${BLUE}В $netplan_file:${NC}"
                    local dns_info
                    dns_info=$(python3 -c "$PYTHON_HELPER" get_dns "$netplan_file" 2>/dev/null)
                    if [[ "$dns_info" == "EMPTY" || -z "$dns_info" ]]; then
                        echo "  (не заданы)"
                    else
                        while IFS='|' read -r iface dns; do
                            echo -e "  ${GREEN}$iface${NC}: ${dns//,/ }"
                        done <<< "$dns_info"
                    fi
                else
                    echo -e "${BLUE}Файлы Netplan не найдены.${NC}"
                fi
                echo
                echo -e "${BLUE}Активные в системе:${NC}"
                local active_dns
                active_dns=$(get_active_dns)
                if [[ -n "$active_dns" ]]; then
                    echo "  $active_dns"
                else
                    echo "  (не определены)"
                fi
                echo
                echo -e "${BLUE}Тест резолвинга:${NC}"
                if command -v nslookup &>/dev/null; then
                    run_cmd "Проверка cloudflare.com" 5 yes nslookup cloudflare.com || true
                else
                    run_cmd "Проверка cloudflare.com" 5 yes getent hosts cloudflare.com || true
                fi
                ;;
            8)
                select_interface || { safe_read -p "Нажмите Enter..."; continue; }
                
                local netplan_file
                netplan_file=$(ensure_netplan_file)
                
                warn "Вы собираетесь очистить DNS в $netplan_file для $SELECTED_IFACE."
                local confirm
                safe_read -p "Продолжить? (y/N): " confirm || continue
                if [[ "${confirm,,}" == "y" ]]; then
                    local backup="${netplan_file}.bak.$(date +%Y%m%d-%H%M%S)"
                    create_backup "$netplan_file" "$backup"
                    info "Бэкап создан: $backup"
                    
                    if ! python3 -c "$PYTHON_HELPER" clear_dns "$netplan_file" "$SELECTED_IFACE"; then
                        error "Ошибка при очистке DNS. Откат..."
                        install -m 600 "$backup" "$netplan_file"
                        netplan apply 2>/dev/null || true
                        continue
                    fi

                    if ! python3 -c "$PYTHON_HELPER" validate "$netplan_file"; then
                        error "Ошибка в YAML после очистки! Откатываю бэкап..."
                        install -m 600 "$backup" "$netplan_file"
                        netplan apply 2>/dev/null || true
                        continue
                    fi

                    echo
                    echo -e "  ${GREEN}1${NC}) Безопасно: 'netplan try'"
                    echo -e "  ${GREEN}2${NC}) Обычно: 'netplan apply'"
                    echo -e "  ${GREEN}3${NC}) Не применять сейчас"
                    local apply_choice
                    safe_read -p "Выбор [1]: " apply_choice || continue
                    apply_choice=${apply_choice:-1}
                    
                    local result="failed"
                    case "$apply_choice" in
                        1) apply_netplan_safely "$netplan_file" "$backup" try && result="applied" ;;
                        2) apply_netplan_safely "$netplan_file" "$backup" apply && result="applied" ;;
                        3) result="saved" ;;
                        *) result="bad_choice" ;;
                    esac
                    case "$result" in
                        applied) info "✅ Конфигурация обновлена!" ;;
                        saved)   info " Изменения сохранены. Примените: sudo netplan apply" ;;
                        bad_choice) warn " Некорректный выбор. Примените вручную: sudo netplan apply" ;;
                        failed)  warn "⚠ Изменения не применены (произошёл откат к резервной копии)." ;;
                    esac
                fi
                ;;
            9)
                info "Возврат в главное меню..."
                return 0
                ;;
            *)
                warn "Некорректный выбор. Введите число от 1 до 9."
                ;;
        esac

        echo
        if [[ "$choice" != "9" ]]; then
            safe_read -p "Нажмите Enter для продолжения..." || return 1
        fi
    done
}

# ---------- Главное меню ----------
main_menu() {
    show_initial_status

    while true; do
        header "Главное меню"
        echo "Выберите действие:"
        echo -e "  ${GREEN}1${NC}) Добавить IP-адреса"
        echo -e "  ${GREEN}2${NC}) Удалить IP-адрес из конфига"
        echo -e "  ${GREEN}3${NC}) Показать конфигурацию Netplan"
        echo -e "  ${GREEN}4${NC}) Обновить статус интерфейсов"
        echo -e "  ${GREEN}5${NC}) Диагностика: netplan status"
        echo -e "  ${MAGENTA}6${NC}) Управление DNS-серверами"
        echo -e "  ${RED}0${NC}) Выход"
        echo
        local choice
        safe_read -p "Ваш выбор [0-6]: " choice || { info "До свидания!"; exit 0; }

        case $choice in
            1)
                select_interface || { safe_read -p "Нажмите Enter..."; continue; }
                if input_ips; then
                    echo
                    info "Будут добавлены на $SELECTED_IFACE:"
                    local ip_addr
                    for ip_addr in "${INPUT_IPS[@]}"; do echo "  - $ip_addr"; done
                    echo
                    local confirm
                    safe_read -p "Применить изменения? (y/N): " confirm || continue
                    if [[ "${confirm,,}" == "y" ]]; then
                        add_ips_to_netplan "$SELECTED_IFACE" "${INPUT_IPS[@]}"
                    else
                        info "Отменено."
                    fi
                fi
                ;;
            2)
                select_interface && remove_ip_from_netplan "$SELECTED_IFACE"
                ;;
            3) show_netplan_config ;;
            4) 
                clear 2>/dev/null || printf '\033[2J\033[H'
                show_initial_status
                continue 
                ;;
            5)
                header "Диагностика Netplan"
                run_cmd "netplan status" 10 yes netplan status || run_cmd "netplan get" 10 yes netplan get || true
                echo
                run_cmd "systemctl status systemd-networkd" 5 yes systemctl status systemd-networkd --no-pager -l || true
                ;;
            6)
                dns_management
                clear 2>/dev/null || printf '\033[2J\033[H'
                show_initial_status
                continue
                ;;
            0) info "До свидания!"; exit 0 ;;
            *) warn "Некорректный выбор." ;;
        esac
        echo
        safe_read -p "Нажмите Enter для продолжения..." || { info "До свидания!"; exit 0; }
        clear 2>/dev/null || printf '\033[2J\033[H'
        show_initial_status
    done
}

main_menu