#!/bin/bash
# =============================================================================
#  ____   ___    _            _    ____  _   _     __  __             _ _
# |  _ \ / _ \  / \          / \  / ___|| \ | |   |  \/  | ___  _ __ (_) |_ ___  _ __
# | |_) | | | |/ _ \  _____ / _ \ \___ \|  \| |   | |\/| |/ _ \| '_ \| | __/ _ \| '__|
# |  _ <| |_| / ___ \|_____/ ___ \ ___) | |\  |   | |  | | (_) | | | | | || (_) | |
# |_| \_\\___/_/   \_\   /_/   \_\____/|_| \_|   |_|  |_|\___/|_| |_|_|\__\___/|_|
#
# =============================================================================
# ROA-ASN-Monitor — Daemon interativo de monitoramento RPKI
# Roda como um serviço próprio com console, log e comandos internos.
# Sem necessidade de cron ou ferramentas externas.
# =============================================================================

set -uo pipefail

# ======================== VARIÁVEIS GLOBAIS ==================================
VERSION="2.2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/config.env}"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/monitor.log"
PID_FILE="$SCRIPT_DIR/.monitor.pid"
STATE_FILE="$SCRIPT_DIR/.last_state"
TG_OFFSET_FILE="$SCRIPT_DIR/.tg_offset"

# Contadores globais
UPTIME_START=$(date +%s)
CHECKS_TOTAL=0
CHECKS_OK=0
CHECKS_FAIL=0
ALERTS_SENT=0
RUNNING=true
NEXT_CHECK=0
PAUSED=false
LAST_TG_POLL=0
TG_POLL_INTERVAL=1

# ======================== CORES ==============================================
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    WHITE='\033[1;37m'
    GRAY='\033[0;90m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' MAGENTA='' WHITE='' GRAY='' BOLD='' DIM='' NC=''
fi

# ======================== FUNÇÕES DE LOG =====================================

timestamp() {
    date '+%H:%M:%S'
}

datestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log_raw() {
    local msg="$1"
    echo -e "$msg"
    # Salva no arquivo de log com data completa (sem códigos de cor)
    # O log NUNCA é apagado — mantém histórico completo
    echo -e "[$(date '+%Y-%m-%d')] $msg" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE" 2>/dev/null
}

log_info() {
    log_raw "${GRAY}[$(timestamp)]${NC} ${BLUE}INFO${NC}  │ $1"
}

log_ok() {
    log_raw "${GRAY}[$(timestamp)]${NC} ${GREEN} OK ${NC}  │ $1"
}

log_warn() {
    log_raw "${GRAY}[$(timestamp)]${NC} ${YELLOW}WARN${NC}  │ $1"
}

log_error() {
    log_raw "${GRAY}[$(timestamp)]${NC} ${RED}ERRO${NC}  │ $1"
}

log_alert() {
    log_raw "${GRAY}[$(timestamp)]${NC} ${RED}${BOLD}ALRT${NC}  │ $1"
}

log_cmd() {
    log_raw "${GRAY}[$(timestamp)]${NC} ${CYAN}CMD ${NC}  │ $1"
}

log_line() {
    log_raw "${GRAY}      │${NC}         │ $1"
}

log_separator() {
    log_raw "${GRAY}──────┼─────────┼────────────────────────────────────────────────${NC}"
}

# ======================== BANNER =============================================

show_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║                                                              ║"
    echo "  ║     ██████   ██████   █████       █████  ███████ ██   ██     ║"
    echo "  ║     ██   ██ ██    ██ ██   ██     ██   ██ ██      ████ ██     ║"
    echo "  ║     ██████  ██    ██ ███████     ███████ ███████  ██ ████    ║"
    echo "  ║     ██   ██ ██    ██ ██   ██     ██   ██      ██ ██  ███     ║"
    echo "  ║     ██   ██  ██████  ██   ██     ██   ██ ███████ ██   ██     ║"
    echo "  ║                                                              ║"
    echo "  ║             M O N I T O R   v${VERSION}                      ║"
    echo "  ║          RPKI Validation · Telegram Alerts                   ║"
    echo "  ║                                                              ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

show_motd() {
    log_info "Servidor iniciado em ${WHITE}$(datestamp)${NC}"
    log_info "Versão: ${WHITE}v${VERSION}${NC}"
    log_info "Config: ${WHITE}${CONFIG_FILE}${NC}"
    log_info "Logs:   ${WHITE}${LOG_FILE}${NC}"
    log_info "PID:    ${WHITE}$$${NC}"
    log_separator
}

# ======================== CONFIGURAÇÃO =======================================

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Arquivo de configuração não encontrado: ${WHITE}$CONFIG_FILE${NC}"
        log_error "Copie ${WHITE}config.env.example${NC} para ${WHITE}config.env${NC} e preencha."
        return 1
    fi

    # shellcheck source=/dev/null
    # Remove \r (Windows CRLF) antes de carregar
    source <(sed 's/\r$//' "$CONFIG_FILE")

    # Defaults
    CHECK_INTERVAL="${CHECK_INTERVAL:-600}"
    # Garante que CHECK_INTERVAL é um número válido
    if ! [[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]]; then
        CHECK_INTERVAL=600
    fi
    RPKI_API_MODE="${RPKI_API_MODE:-ripestat}"
    ROUTINATOR_URL="${ROUTINATOR_URL:-}"
    MONITORAR_KRILL_LOCAL="${MONITORAR_KRILL_LOCAL:-false}"
    ENVIAR_OK="${ENVIAR_OK:-false}"
    ENVIAR_OK_INTERVALO="${ENVIAR_OK_INTERVALO:-6}"
    TELEGRAM_BOT_COMMANDS="${TELEGRAM_BOT_COMMANDS:-true}"

    # Validações
    local erros=0
    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
        log_error "Variável ${WHITE}TELEGRAM_BOT_TOKEN${NC} não definida."
        erros=$((erros + 1))
    fi
    if [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
        log_error "Variável ${WHITE}TELEGRAM_CHAT_ID${NC} não definida."
        erros=$((erros + 1))
    fi
    if [ -z "${PREFIXOS:-}" ]; then
        log_error "Variável ${WHITE}PREFIXOS${NC} não definida."
        erros=$((erros + 1))
    fi
    if [ "$RPKI_API_MODE" = "routinator" ] && [ -z "$ROUTINATOR_URL" ]; then
        log_error "Modo ${WHITE}routinator${NC} requer ${WHITE}ROUTINATOR_URL${NC} configurado."
        erros=$((erros + 1))
    fi

    if [ $erros -gt 0 ]; then
        return 1
    fi

    return 0
}

check_dependencies() {
    local missing=0
    for cmd in curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "'${WHITE}$cmd${NC}' não está instalado."
            missing=$((missing + 1))
        fi
    done
    if [ $missing -gt 0 ]; then
        log_error "Instale as dependências: ${WHITE}sudo apt install curl jq -y${NC}"
        return 1
    fi
    return 0
}

# ======================== TELEGRAM ===========================================

enviar_telegram() {
    local mensagem="$1"
    local response
    response=$(curl -s --connect-timeout 5 --max-time 10 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="${mensagem}" \
        -d parse_mode="Markdown" 2>&1)

    local ok
    ok=$(echo "$response" | jq -r '.ok // "false"' 2>/dev/null)
    if [ "$ok" != "true" ]; then
        log_error "Falha ao enviar Telegram: $(echo "$response" | jq -r '.description // "sem detalhes"' 2>/dev/null)"
        return 1
    fi
    ALERTS_SENT=$((ALERTS_SENT + 1))
    return 0
}

enviar_telegram_doc() {
    # Envia um documento (arquivo) ao Telegram
    local filepath="$1"
    local caption="${2:-}"
    local response
    response=$(curl -s --connect-timeout 5 --max-time 20 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
        -F chat_id="${TELEGRAM_CHAT_ID}" \
        -F document=@"${filepath}" \
        -F caption="${caption}" \
        -F parse_mode="Markdown" 2>&1)

    local ok
    ok=$(echo "$response" | jq -r '.ok // "false"' 2>/dev/null)
    if [ "$ok" != "true" ]; then
        log_error "Falha ao enviar documento Telegram: $(echo "$response" | jq -r '.description // "sem detalhes"' 2>/dev/null)"
        return 1
    fi
    return 0
}

enviar_telegram_reply() {
    # Envia mensagem respondendo a um chat_id específico (pode ser diferente do padrão)
    local chat_id="$1"
    local mensagem="$2"
    curl -s --connect-timeout 5 --max-time 10 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${chat_id}" \
        -d text="${mensagem}" \
        -d parse_mode="Markdown" > /dev/null 2>&1
}

enviar_telegram_doc_to() {
    # Envia um documento a um chat_id específico
    local chat_id="$1"
    local filepath="$2"
    local caption="${3:-}"
    curl -s --connect-timeout 5 --max-time 20 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
        -F chat_id="${chat_id}" \
        -F document=@"${filepath}" \
        -F caption="${caption}" \
        -F parse_mode="Markdown" > /dev/null 2>&1
}

test_telegram() {
    log_info "Enviando mensagem de teste ao Telegram..."
    local msg="🧪 *ROA-ASN-Monitor — Teste*%0A%0A"
    msg+="Mensagem de teste enviada com sucesso!%0A"
    msg+="🕐 $(datestamp)%0A"
    msg+="🖥️ $(hostname)"
    if enviar_telegram "$msg"; then
        log_ok "Mensagem de teste enviada com sucesso!"
    else
        log_error "Falha ao enviar mensagem de teste."
    fi
}

# ======================== TELEGRAM BOT COMMANDS ==============================

get_log_7_days() {
    # Extrai as últimas 7 dias do log e salva em arquivo temporário
    local temp_file="/tmp/rpki_log_7d_$$.txt"
    local cutoff_date
    cutoff_date=$(date -d '7 days ago' '+%Y-%m-%d' 2>/dev/null || date -v-7d '+%Y-%m-%d' 2>/dev/null)

    if [ -z "$cutoff_date" ]; then
        # Fallback: envia as últimas 500 linhas
        tail -n 500 "$LOG_FILE" > "$temp_file" 2>/dev/null
    else
        # Filtra linhas com data >= cutoff (formato [YYYY-MM-DD] no início)
        awk -v cutoff="$cutoff_date" '
            /^\[20[0-9]{2}-[0-9]{2}-[0-9]{2}\]/ {
                date = substr($0, 2, 10)
                if (date >= cutoff) print
                next
            }
            { print }
        ' "$LOG_FILE" > "$temp_file" 2>/dev/null
    fi

    # Se o arquivo ficou vazio
    if [ ! -s "$temp_file" ]; then
        echo "Nenhum log encontrado nos últimos 7 dias." > "$temp_file"
    fi

    echo "$temp_file"
}

get_status_text() {
    local agora
    agora=$(date +%s)
    local uptime_seg=$((agora - UPTIME_START))
    local dias=$((uptime_seg / 86400))
    local horas=$(( (uptime_seg % 86400) / 3600 ))
    local mins=$(( (uptime_seg % 3600) / 60 ))

    local estado="RODANDO"
    [ "$PAUSED" = "true" ] && estado="PAUSADO"

    local prox_em="agora"
    if [ $NEXT_CHECK -gt 0 ] && [ $NEXT_CHECK -gt $agora ]; then
        local restante=$((NEXT_CHECK - agora))
        prox_em="${restante}s"
    fi

    local api_label="RIPEstat (público)"
    [ "$RPKI_API_MODE" = "routinator" ] && api_label="Routinator (local)"

    local txt="📊 *ROA-ASN-Monitor — Status*%0A%0A"
    txt+="▸ Estado: *${estado}*%0A"
    txt+="▸ Uptime: *${dias}d ${horas}h ${mins}m*%0A"
    txt+="▸ Intervalo: *${CHECK_INTERVAL}s* ($((CHECK_INTERVAL / 60))min)%0A"
    txt+="▸ API: *${api_label}*%0A"
    txt+="▸ Próxima check: *${prox_em}*%0A%0A"
    txt+="▸ Total de checks: *${CHECKS_TOTAL}*%0A"
    txt+="▸ Sucesso (OK): *${CHECKS_OK}*%0A"
    txt+="▸ Com problemas: *${CHECKS_FAIL}*%0A"
    txt+="▸ Alertas enviados: *${ALERTS_SENT}*%0A%0A"
    txt+="🖥️ $(hostname) | 🕐 $(datestamp)"
    echo "$txt"
}

process_telegram_command() {
    local chat_id="$1"
    local text="$2"
    local user="${3:-desconhecido}"

    # Normaliza o comando (lowercase, remove @botname)
    local cmd
    cmd=$(echo "$text" | awk '{print $1}' | tr '[:upper:]' '[:lower:]' | sed 's/@.*//')

    case "$cmd" in
        /log)
            log_cmd "Telegram [@${user}]: solicitou /log"
            local log_file
            log_file=$(get_log_7_days)
            enviar_telegram_reply "$chat_id" "📋 Enviando log dos últimos 7 dias..."
            enviar_telegram_doc_to "$chat_id" "$log_file" "📋 Log dos últimos 7 dias — $(datestamp)"
            rm -f "$log_file" 2>/dev/null
            ;;
        /logall)
            log_cmd "Telegram [@${user}]: solicitou /logall"
            if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
                enviar_telegram_reply "$chat_id" "📚 Enviando log completo..."
                enviar_telegram_doc_to "$chat_id" "$LOG_FILE" "📚 Log completo — $(datestamp)"
            else
                enviar_telegram_reply "$chat_id" "ℹ️ Nenhum log disponível ainda."
            fi
            ;;
        /status)
            log_cmd "Telegram [@${user}]: solicitou /status"
            local status_msg
            status_msg=$(get_status_text)
            enviar_telegram_reply "$chat_id" "$status_msg"
            ;;
        /check)
            log_cmd "Telegram [@${user}]: solicitou /check"
            enviar_telegram_reply "$chat_id" "🔄 Verificação RPKI iniciada..."
            run_check
            # Envia resultado de volta
            local check_result="✅ Verificação concluída."
            if [ $CHECKS_FAIL -gt 0 ] && [ $CHECKS_TOTAL -gt 0 ]; then
                check_result="⚠️ Verificação concluída com problemas. Veja o alerta acima."
            fi
            enviar_telegram_reply "$chat_id" "$check_result Checks: ${CHECKS_OK} OK / ${CHECKS_FAIL} falhas de ${CHECKS_TOTAL} total."
            ;;
        /pause)
            log_cmd "Telegram [@${user}]: solicitou /pause"
            PAUSED=true
            enviar_telegram_reply "$chat_id" "⏸ Verificações automáticas *PAUSADAS*."
            ;;
        /resume)
            log_cmd "Telegram [@${user}]: solicitou /resume"
            PAUSED=false
            NEXT_CHECK=$(($(date +%s) + CHECK_INTERVAL))
            enviar_telegram_reply "$chat_id" "▶️ Verificações automáticas *RETOMADAS*."
            ;;
        /help|/start)
            log_cmd "Telegram [@${user}]: solicitou /help"
            local help_msg="🤖 *ROA-ASN-Monitor — Comandos*%0A%0A"
            help_msg+="/log — Log dos últimos 7 dias%0A"
            help_msg+="/logall — Log completo (todo o histórico)%0A"
            help_msg+="/status — Ver status atual do monitor%0A"
            help_msg+="/check — Forçar verificação RPKI agora%0A"
            help_msg+="/pause — Pausar verificações automáticas%0A"
            help_msg+="/resume — Retomar verificações automáticas%0A"
            help_msg+="/help — Mostrar este menu%0A%0A"
            help_msg+="☕ _Feito com amor e café por_ [davicjc](https://davicjc.com)"
            enviar_telegram_reply "$chat_id" "$help_msg"
            ;;
        /*)  # Comando desconhecido que começa com /
            enviar_telegram_reply "$chat_id" "❓ Comando desconhecido. Use /help para ver os comandos."
            ;;
    esac
}

poll_telegram_updates() {
    # Só processa se estiver habilitado
    [ "${TELEGRAM_BOT_COMMANDS:-true}" != "true" ] && return

    # Controlar frequência do polling (a cada TG_POLL_INTERVAL segundos)
    local agora
    agora=$(date +%s)
    if [ $((agora - LAST_TG_POLL)) -lt $TG_POLL_INTERVAL ]; then
        return
    fi
    LAST_TG_POLL=$agora

    # Ler offset salvo
    local offset=0
    if [ -f "$TG_OFFSET_FILE" ]; then
        offset=$(cat "$TG_OFFSET_FILE" 2>/dev/null)
    fi

    # Buscar updates
    local response
    response=$(curl -s --connect-timeout 3 --max-time 5 \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=${offset}&limit=10&timeout=0" 2>/dev/null)

    [ -z "$response" ] && return

    local ok
    ok=$(echo "$response" | jq -r '.ok // "false"' 2>/dev/null)
    [ "$ok" != "true" ] && return

    # Processar cada update
    local updates
    updates=$(echo "$response" | jq -r '.result | length' 2>/dev/null)
    [ "${updates:-0}" -eq 0 ] && return

    local i=0
    while [ $i -lt "$updates" ]; do
        local update_id chat_id text username
        update_id=$(echo "$response" | jq -r ".result[$i].update_id" 2>/dev/null)
        chat_id=$(echo "$response" | jq -r ".result[$i].message.chat.id // empty" 2>/dev/null)
        text=$(echo "$response" | jq -r ".result[$i].message.text // empty" 2>/dev/null)
        username=$(echo "$response" | jq -r ".result[$i].message.from.username // .result[$i].message.from.first_name // \"user\"" 2>/dev/null)

        # Salvar offset para não reprocessar
        echo $((update_id + 1)) > "$TG_OFFSET_FILE"

        # Processar se tiver texto e comecar com /
        if [ -n "$chat_id" ] && [ -n "$text" ] && [[ "$text" == /* ]]; then
            process_telegram_command "$chat_id" "$text" "$username"
        fi

        i=$((i + 1))
    done
}

# ======================== RPKI CHECK =========================================

# ---- Routinator (API local) ----
consultar_routinator() {
    local asn="$1"
    local prefixo="$2"
    local api_url="${ROUTINATOR_URL}/api/v1/validity/${asn}/${prefixo}"

    local response
    response=$(curl -s --connect-timeout 10 --max-time 20 \
        --retry 2 --retry-delay 3 --retry-all-errors \
        "$api_url" 2>/dev/null)

    if [ -z "$response" ]; then
        echo "ERRO_CONEXAO"
        return
    fi

    if ! echo "$response" | jq empty 2>/dev/null; then
        echo "ERRO_CONEXAO"
        return
    fi

    local status
    status=$(echo "$response" | jq -r '.validated_route.validity.state // "ERRO_PARSE"' 2>/dev/null)
    echo "$status"
}

# ---- RIPEstat (API pública) ----
consultar_ripestat() {
    local asn="$1"
    local prefixo="$2"

    local response=""

    # Tenta HTTPS primeiro
    response=$(curl -s --connect-timeout 10 --max-time 20 \
        --retry 2 --retry-delay 5 --retry-all-errors \
        "https://stat.ripe.net/data/rpki-validation/data.json?resource=${asn}&prefix=${prefixo}" 2>/dev/null)

    # Validar resposta HTTPS
    if [ -n "$response" ] && echo "$response" | jq empty 2>/dev/null; then
        local status
        status=$(echo "$response" | jq -r '.data.status // "ERRO_PARSE"' 2>/dev/null)
        if [ "$status" != "ERRO_PARSE" ]; then
            echo "$status"
            return
        fi
    fi

    # Fallback HTTP se HTTPS falhar
    log_warn "HTTPS falhou, tentando HTTP..."
    response=$(curl -s --connect-timeout 10 --max-time 20 \
        --retry 2 --retry-delay 5 --retry-all-errors \
        "http://stat.ripe.net/data/rpki-validation/data.json?resource=${asn}&prefix=${prefixo}" 2>/dev/null)

    if [ -z "$response" ]; then
        echo "ERRO_CONEXAO"
        return
    fi

    if ! echo "$response" | jq empty 2>/dev/null; then
        echo "ERRO_CONEXAO"
        return
    fi

    local status
    status=$(echo "$response" | jq -r '.data.status // "ERRO_PARSE"' 2>/dev/null)
    echo "$status"
}

# ---- Função principal de consulta (despacha para o modo configurado) ----
consultar_rpki() {
    local asn="$1"
    local prefixo="$2"

    case "$RPKI_API_MODE" in
        routinator)
            consultar_routinator "$asn" "$prefixo"
            ;;
        ripestat|*)
            consultar_ripestat "$asn" "$prefixo"
            ;;
    esac
}

verificar_krill_local() {
    if [ "${MONITORAR_KRILL_LOCAL}" != "true" ]; then
        return 0
    fi

    log_info "Verificando serviço Krill local..."

    if command -v systemctl &>/dev/null; then
        if ! systemctl is-active --quiet krill 2>/dev/null; then
            log_alert "Serviço Krill local está ${RED}PARADO${NC}!"
            local msg="⚠️ *ALERTA KRILL* ⚠️%0A%0A"
            msg+="O serviço *Krill* no servidor está *PARADO*!%0A"
            msg+="🖥️ $(hostname)%0A"
            msg+="🕐 $(datestamp)%0A%0A"
            msg+="Verifique: \`systemctl status krill\`"
            enviar_telegram "$msg"
            return 1
        else
            log_ok "Serviço Krill local: ${GREEN}ativo${NC}"
        fi
    fi

    if [ -n "${KRILL_API_URL:-}" ] && [ -n "${KRILL_API_TOKEN:-}" ]; then
        local health
        health=$(curl -s --max-time 10 \
            -H "Authorization: Bearer ${KRILL_API_TOKEN}" \
            "${KRILL_API_URL}/api/v1/authorized" 2>&1)

        if [ -z "$health" ] || echo "$health" | grep -qi "error\|refused\|timeout"; then
            log_alert "API do Krill ${RED}não respondeu${NC}!"
            local msg="⚠️ *ALERTA KRILL API* ⚠️%0A%0A"
            msg+="A API do Krill em *${KRILL_API_URL}* não respondeu.%0A"
            msg+="🕐 $(datestamp)"
            enviar_telegram "$msg"
            return 1
        else
            log_ok "API do Krill: ${GREEN}respondendo${NC}"
        fi
    fi
    return 0
}

run_check() {
    log_separator
    log_info "${WHITE}${BOLD}Iniciando verificação RPKI...${NC}"
    log_separator

    local erros=0
    local total=0
    local alertas=""

    # Krill local
    verificar_krill_local

    # Iterar prefixos
    IFS=';' read -ra LISTA <<< "$PREFIXOS"

    for entrada in "${LISTA[@]}"; do
        entrada=$(echo "$entrada" | xargs)
        [ -z "$entrada" ] && continue

        IFS=',' read -r asn prefixo <<< "$entrada"
        asn=$(echo "$asn" | xargs)
        prefixo=$(echo "$prefixo" | xargs)

        if [ -z "$asn" ] || [ -z "$prefixo" ]; then
            log_warn "Entrada inválida ignorada: '${YELLOW}$entrada${NC}'"
            continue
        fi

        total=$((total + 1))
        log_info "Consultando ${WHITE}AS${asn}${NC} / ${WHITE}${prefixo}${NC}..."

        local status
        status=$(consultar_rpki "$asn" "$prefixo")

        case "$status" in
            valid)
                log_ok "${GREEN}✔${NC} AS${asn} / ${prefixo} → ${GREEN}${BOLD}Valid${NC}"
                ;;
            invalid)
                log_alert "${RED}✘${NC} AS${asn} / ${prefixo} → ${RED}${BOLD}INVALID${NC}"
                erros=$((erros + 1))
                alertas+="❌ AS${asn} / ${prefixo} → *INVALID*%0A"
                ;;
            unknown|not_found)
                log_warn "${YELLOW}?${NC} AS${asn} / ${prefixo} → ${YELLOW}${BOLD}${status}${NC}"
                erros=$((erros + 1))
                alertas+="⚠️ AS${asn} / ${prefixo} → *${status}*%0A"
                ;;
            ERRO_CONEXAO)
                log_error "${RED}⚡${NC} AS${asn} / ${prefixo} → ${RED}ERRO DE CONEXÃO${NC}"
                erros=$((erros + 1))
                alertas+="🔌 AS${asn} / ${prefixo} → *ERRO CONEXÃO*%0A"
                ;;
            *)
                log_warn "${YELLOW}?${NC} AS${asn} / ${prefixo} → ${YELLOW}${status}${NC}"
                erros=$((erros + 1))
                alertas+="❓ AS${asn} / ${prefixo} → *${status}*%0A"
                ;;
        esac

        sleep 1
    done

    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))

    log_separator

    if [ $erros -gt 0 ]; then
        CHECKS_FAIL=$((CHECKS_FAIL + 1))
        log_alert "${RED}${BOLD}$erros problema(s) de $total prefixo(s)!${NC}"

        local msg="🚨 *ALERTA RPKI CRÍTICO* 🚨%0A%0A"
        msg+="*${erros}* problema(s) de *${total}* prefixo(s):%0A%0A"
        msg+="${alertas}%0A"
        msg+="🕐 $(datestamp)%0A"
        msg+="🖥️ $(hostname)%0A%0A"
        msg+="Verifique seu Krill imediatamente!"
        enviar_telegram "$msg"
        log_alert "Alerta Telegram enviado!"

        # Salvar estado
        echo "FAIL:$(date +%s):$erros:$total" > "$STATE_FILE"
    else
        CHECKS_OK=$((CHECKS_OK + 1))
        log_ok "${GREEN}${BOLD}Tudo OK! $total prefixo(s) com status Valid.${NC}"

        if [ "${ENVIAR_OK}" = "true" ]; then
            # Enviar OK somente a cada N horas
            local agora
            agora=$(date +%s)
            local ultimo_ok=0
            if [ -f "$STATE_FILE" ] && grep -q "^OK:" "$STATE_FILE"; then
                ultimo_ok=$(grep "^OK:" "$STATE_FILE" | cut -d: -f2)
            fi
            local intervalo_seg=$((ENVIAR_OK_INTERVALO * 3600))
            if [ $((agora - ultimo_ok)) -ge $intervalo_seg ]; then
                local prox_check_ts=$((agora + CHECK_INTERVAL))
                local prox_check_fmt
                prox_check_fmt=$(date -d "@$prox_check_ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$prox_check_ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "em ${CHECK_INTERVAL}s")
                local msg="✅ *RPKI OK* — Todos os *${total}* prefixo(s) estão *Valid*.%0A"
                msg+="🕐 $(datestamp) | 🖥️ $(hostname)%0A"
                msg+="🔄 Próxima verificação: *${prox_check_fmt}*"
                enviar_telegram "$msg"
                echo "OK:${agora}" > "$STATE_FILE"
                log_info "Confirmação de OK enviada ao Telegram."
            fi
        fi

        echo "OK:$(date +%s)" > "$STATE_FILE"
    fi

    # Próxima verificação
    NEXT_CHECK=$(($(date +%s) + CHECK_INTERVAL))
    local prox
    prox=$(date -d "@$NEXT_CHECK" '+%H:%M:%S' 2>/dev/null || date -r "$NEXT_CHECK" '+%H:%M:%S' 2>/dev/null || echo "em ${CHECK_INTERVAL}s")
    log_info "Próxima verificação: ${WHITE}${prox}${NC} (intervalo: ${CHECK_INTERVAL}s)"
    log_separator
}

# ======================== LOG (PERSISTENTE) ==================================
# O log NUNCA é apagado. Salva tudo permanentemente.
# O comando /log no Telegram filtra apenas os últimos 7 dias para exibição.

# ======================== COMANDOS DO CONSOLE ================================

show_help() {
    echo ""
    echo -e "  ${CYAN}${BOLD}═══ Comandos Disponíveis ══════════════════════════════════${NC}"
    echo ""
    echo -e "  ${WHITE}check${NC}          Forçar verificação agora"
    echo -e "  ${WHITE}status${NC}         Exibir status do monitor"
    echo -e "  ${WHITE}pause${NC}          Pausar verificações automáticas"
    echo -e "  ${WHITE}resume${NC}         Retomar verificações automáticas"
    echo -e "  ${WHITE}interval${NC} ${DIM}<seg>${NC}  Alterar intervalo (ex: ${DIM}interval 300${NC})"
    echo -e "  ${WHITE}test${NC}           Enviar mensagem de teste ao Telegram"
    echo -e "  ${WHITE}reload${NC}         Recarregar arquivo de configuração"
    echo -e "  ${WHITE}prefixes${NC}       Listar prefixos monitorados"
    echo -e "  ${WHITE}clear${NC}          Limpar tela do console"
    echo -e "  ${WHITE}help${NC}           Mostrar este menu"
    echo -e "  ${WHITE}stop${NC}           Parar o monitor"
    echo ""
    echo -e "  ${DIM}☕ Feito com amor e café por davicjc — davicjc.com${NC}"
    echo ""
    echo -e "  ${CYAN}${BOLD}══════════════════════════════════════════════════════════${NC}"
    echo ""
}

show_status() {
    local agora
    agora=$(date +%s)
    local uptime_seg=$((agora - UPTIME_START))
    local dias=$((uptime_seg / 86400))
    local horas=$(( (uptime_seg % 86400) / 3600 ))
    local mins=$(( (uptime_seg % 3600) / 60 ))
    local segs=$((uptime_seg % 60))

    local prox_em=""
    if [ $NEXT_CHECK -gt 0 ] && [ $NEXT_CHECK -gt $agora ]; then
        local restante=$((NEXT_CHECK - agora))
        local r_min=$((restante / 60))
        local r_seg=$((restante % 60))
        prox_em="${r_min}m ${r_seg}s"
    else
        prox_em="agora"
    fi

    local estado_str
    if [ "$PAUSED" = "true" ]; then
        estado_str="${YELLOW}⏸  PAUSADO${NC}"
    else
        estado_str="${GREEN}▶  RODANDO${NC}"
    fi

    local api_label="RIPEstat (público)"
    [ "$RPKI_API_MODE" = "routinator" ] && api_label="Routinator (local: $ROUTINATOR_URL)"

    echo ""
    echo -e "  ${CYAN}${BOLD}═══ Status do Monitor ═════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${WHITE}Estado:${NC}           $estado_str"
    echo -e "  ${WHITE}Uptime:${NC}           ${dias}d ${horas}h ${mins}m ${segs}s"
    echo -e "  ${WHITE}PID:${NC}              $$"
    echo -e "  ${WHITE}Intervalo:${NC}        ${CHECK_INTERVAL}s ($((CHECK_INTERVAL / 60))min)"
    echo -e "  ${WHITE}API:${NC}              ${api_label}"
    echo -e "  ${WHITE}Próxima check:${NC}    ${prox_em}"
    echo ""
    echo -e "  ${WHITE}Total de checks:${NC}  ${CHECKS_TOTAL}"
    echo -e "  ${WHITE}Sucesso (OK):${NC}     ${GREEN}${CHECKS_OK}${NC}"
    echo -e "  ${WHITE}Com problemas:${NC}    ${RED}${CHECKS_FAIL}${NC}"
    echo -e "  ${WHITE}Alertas enviados:${NC} ${ALERTS_SENT}"
    echo ""
    echo -e "  ${WHITE}Config:${NC}           ${CONFIG_FILE}"
    echo -e "  ${WHITE}Log:${NC}              ${LOG_FILE}"
    echo ""
    echo -e "  ${CYAN}${BOLD}══════════════════════════════════════════════════════════${NC}"
    echo ""
}

show_prefixes() {
    echo ""
    echo -e "  ${CYAN}${BOLD}═══ Prefixos Monitorados ══════════════════════════════════${NC}"
    echo ""

    IFS=';' read -ra LISTA <<< "$PREFIXOS"
    local i=1
    for entrada in "${LISTA[@]}"; do
        entrada=$(echo "$entrada" | xargs)
        [ -z "$entrada" ] && continue
        IFS=',' read -r asn prefixo <<< "$entrada"
        asn=$(echo "$asn" | xargs)
        prefixo=$(echo "$prefixo" | xargs)
        echo -e "  ${WHITE}${i}.${NC} AS${CYAN}${asn}${NC}  →  ${WHITE}${prefixo}${NC}"
        i=$((i + 1))
    done

    echo ""
    echo -e "  ${CYAN}${BOLD}══════════════════════════════════════════════════════════${NC}"
    echo ""
}

process_command() {
    local input="$1"
    local cmd
    cmd=$(echo "$input" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
    local arg
    arg=$(echo "$input" | awk '{print $2}')

    case "$cmd" in
        check|c)
            log_cmd "Verificação manual solicitada."
            run_check
            ;;
        status|s)
            show_status
            ;;
        pause|p)
            if [ "$PAUSED" = "true" ]; then
                log_warn "O monitor já está pausado."
            else
                PAUSED=true
                log_info "Verificações automáticas ${YELLOW}PAUSADAS${NC}. Use '${WHITE}resume${NC}' para retomar."
            fi
            ;;
        resume|r)
            if [ "$PAUSED" = "false" ]; then
                log_warn "O monitor já está rodando."
            else
                PAUSED=false
                NEXT_CHECK=$(($(date +%s) + CHECK_INTERVAL))
                log_info "Verificações automáticas ${GREEN}RETOMADAS${NC}."
            fi
            ;;
        interval|i)
            if [ -z "$arg" ]; then
                log_info "Intervalo atual: ${WHITE}${CHECK_INTERVAL}s${NC} ($((CHECK_INTERVAL / 60))min)"
                log_info "Uso: ${WHITE}interval <segundos>${NC} (ex: interval 300)"
            else
                if [[ "$arg" =~ ^[0-9]+$ ]] && [ "$arg" -ge 10 ]; then
                    CHECK_INTERVAL="$arg"
                    NEXT_CHECK=$(($(date +%s) + CHECK_INTERVAL))
                    log_ok "Intervalo alterado para ${WHITE}${CHECK_INTERVAL}s${NC} ($((CHECK_INTERVAL / 60))min)"
                else
                    log_error "Intervalo inválido. Mínimo: ${WHITE}10${NC} segundos."
                fi
            fi
            ;;
        test|t)
            log_cmd "Teste de Telegram solicitado."
            test_telegram
            ;;
        reload)
            log_cmd "Recarregando configuração..."
            if load_config; then
                log_ok "Configuração recarregada com sucesso!"
                show_prefixes
            else
                log_error "Falha ao recarregar configuração."
            fi
            ;;
        prefixes|prefix|prefixos)
            show_prefixes
            ;;
        clear|cls)
            clear
            show_banner
            ;;
        help|h|"?")
            show_help
            ;;
        stop|quit|exit|q)
            log_info "${YELLOW}Parando o monitor...${NC}"
            RUNNING=false
            ;;
        "")
            # Entrada vazia, ignorar
            ;;
        *)
            log_warn "Comando desconhecido: '${WHITE}$cmd${NC}'. Digite '${WHITE}help${NC}' para ver os comandos."
            ;;
    esac
}

# ======================== PROMPT =============================================

show_prompt() {
    if [ "$PAUSED" = "true" ]; then
        echo -ne "${YELLOW}⏸ monitor${NC} ${GRAY}>${NC} "
    else
        echo -ne "${GREEN}▶ monitor${NC} ${GRAY}>${NC} "
    fi
}

# ======================== CLEANUP ============================================

cleanup() {
    echo ""
    log_info "${YELLOW}Sinal de interrupção recebido.${NC}"
    RUNNING=false
    rm -f "$PID_FILE" 2>/dev/null
    rm -f "$TG_OFFSET_FILE" 2>/dev/null
    log_info "Monitor encerrado. Até mais!"
    echo ""
    exit 0
}

trap cleanup SIGINT SIGTERM

# ======================== MAIN LOOP ==========================================

main() {
    # Criar diretório de logs
    mkdir -p "$LOG_DIR"

    # Banner
    show_banner

    # Verificar dependências
    if ! check_dependencies; then
        exit 1
    fi

    # Carregar configuração
    if ! load_config; then
        exit 1
    fi

    # Salvar PID
    echo $$ > "$PID_FILE"

    # MOTD
    show_motd

    # Mostrar prefixos
    show_prefixes

    # Info do intervalo e API
    log_info "Intervalo de verificação: ${WHITE}${CHECK_INTERVAL}s${NC} ($((CHECK_INTERVAL / 60))min)"
    if [ "$RPKI_API_MODE" = "routinator" ]; then
        log_info "API RPKI: ${GREEN}Routinator local${NC} — ${WHITE}${ROUTINATOR_URL}${NC}"
    else
        log_info "API RPKI: ${CYAN}RIPEstat público${NC} — HTTPS com fallback HTTP"
    fi
    if [ "${TELEGRAM_BOT_COMMANDS}" = "true" ]; then
        log_info "Bot Telegram: ${GREEN}ATIVO${NC} — Comandos: /log /status /check /help"
    else
        log_info "Bot Telegram: ${YELLOW}DESATIVADO${NC}"
    fi
    log_info "Digite '${WHITE}help${NC}' para ver os comandos disponíveis."
    log_separator

    # Primeira verificação
    run_check

    # Detecta se stdin está disponível (false quando via nohup)
    HAS_STDIN=false
    if [ -t 0 ]; then
        HAS_STDIN=true
    fi

    # Loop principal
    while $RUNNING; do
        if $HAS_STDIN; then
            # Modo interativo: mostrar prompt e ler comandos
            show_prompt
            if read -t 1 -r user_input; then
                process_command "$user_input"
            fi
        else
            # Modo background (nohup): apenas aguardar
            sleep 1
        fi

        # Verificar se é hora de rodar o check automático
        if [ "$PAUSED" = "false" ] && [ "$(date +%s)" -ge "$NEXT_CHECK" ] && [ "$NEXT_CHECK" -gt 0 ]; then
            echo "" # Nova linha para não sobrepor o prompt
            run_check
        fi

        # Poll de comandos do bot Telegram
        poll_telegram_updates
    done

    # Limpeza
    rm -f "$PID_FILE" 2>/dev/null
    log_info "Monitor encerrado. Até mais!"
    echo ""
}

# ======================== START ==============================================
main
