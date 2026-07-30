#!/usr/bin/env bash
# start-ai.sh — Start / stop / status NimoOS AI services (Ollama + nimoos-agent)
# Usage:
#   sudo bash start-ai.sh [start|stop|restart|status]   (default: start)

set -e

((EUID)) && sudo_cmd="sudo"

AGENT_DIR="/var/lib/nimoos/ai/agent"
AGENT_SRC_DIR="/usr/share/nimoos/agent"
OLLAMA_PORT=11434
AGENT_PORT=8282

CMD="${1:-start}"

log_info()  { echo -e "\e[32m[ INFO ]\e[0m $*"; }
log_ok()    { echo -e "\e[32m[  OK  ]\e[0m $*"; }
log_warn()  { echo -e "\e[33m[ WARN ]\e[0m $*"; }
log_fail()  { echo -e "\e[31m[FAILED]\e[0m $*"; }

###############################################################################
# Service helpers
###############################################################################

service_running() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

wait_port() {
    local port="$1" name="$2" timeout=15
    for i in $(seq 1 $timeout); do
        if curl -sf "http://127.0.0.1:${port}" > /dev/null 2>&1 || \
           curl -sf "http://127.0.0.1:${port}/agent/health" > /dev/null 2>&1 || \
           curl -sf "http://127.0.0.1:${port}/api/tags" > /dev/null 2>&1; then
            log_ok "${name} is ready on :${port}"
            return 0
        fi
        sleep 1
    done
    log_warn "${name} not responding on :${port} after ${timeout}s"
    return 1
}

###############################################################################
# Start
###############################################################################

do_start() {
    log_info "Starting NimoOS AI services..."

    # Ollama
    if ! service_running ollama; then
        if systemctl list-unit-files ollama.service &>/dev/null; then
            log_info "Starting ollama..."
            ${sudo_cmd} systemctl start ollama
            wait_port ${OLLAMA_PORT} "Ollama" || true
        else
            log_warn "ollama.service not found — run install-ai.sh first."
        fi
    else
        log_ok "Ollama already running."
    fi

    # nimoos-agent
    if ! service_running nimoos-agent; then
        if systemctl list-unit-files nimoos-agent.service &>/dev/null; then
            log_info "Starting nimoos-agent..."
            ${sudo_cmd} systemctl start nimoos-agent
            wait_port ${AGENT_PORT} "nimoos-agent" || true
        else
            # Dev fallback: run directly from source
            if [ -f "${AGENT_SRC_DIR}/main.py" ] && [ -f "${AGENT_DIR}/venv/bin/python" ]; then
                log_warn "nimoos-agent.service not registered — starting in dev mode..."
                AGENT_DB_PATH="${AGENT_DIR}/agent.db" \
                    "${AGENT_DIR}/venv/bin/python" "${AGENT_SRC_DIR}/main.py" &
                AGENT_PID=$!
                echo ${AGENT_PID} > /tmp/nimoos-agent.pid
                wait_port ${AGENT_PORT} "nimoos-agent" || true
                log_ok "nimoos-agent started (pid=${AGENT_PID}, pidfile=/tmp/nimoos-agent.pid)"
            else
                log_warn "nimoos-agent not found — run install-ai.sh first."
            fi
        fi
    else
        log_ok "nimoos-agent already running."
    fi
}

###############################################################################
# Stop
###############################################################################

do_stop() {
    log_info "Stopping NimoOS AI services..."

    if service_running nimoos-agent; then
        ${sudo_cmd} systemctl stop nimoos-agent && log_ok "nimoos-agent stopped."
    elif [ -f /tmp/nimoos-agent.pid ]; then
        PID=$(cat /tmp/nimoos-agent.pid)
        kill "${PID}" 2>/dev/null && log_ok "nimoos-agent (pid=${PID}) stopped."
        rm -f /tmp/nimoos-agent.pid
    else
        log_info "nimoos-agent not running."
    fi

    if service_running ollama; then
        ${sudo_cmd} systemctl stop ollama && log_ok "Ollama stopped."
    else
        log_info "Ollama not running."
    fi
}

###############################################################################
# Status
###############################################################################

do_status() {
    echo ""
    echo "  NimoOS AI Services Status"
    echo "  ─────────────────────────────────────"

    # Ollama
    if service_running ollama; then
        STATUS=$(curl -sf "http://127.0.0.1:${OLLAMA_PORT}/api/tags" 2>/dev/null && echo "responding" || echo "started (port not ready)")
        echo -e "  Ollama          : \e[32m● running\e[0m  (${STATUS})"
        # List loaded models if available
        MODELS=$(curl -sf "http://127.0.0.1:${OLLAMA_PORT}/api/tags" 2>/dev/null | \
            python3 -c "import sys,json; d=json.load(sys.stdin); [print('    - '+m['name']) for m in d.get('models',[])]" 2>/dev/null || true)
        [ -n "${MODELS}" ] && echo -e "  Models:\n${MODELS}"
    else
        echo -e "  Ollama          : \e[90m○ stopped\e[0m"
    fi

    # nimoos-agent
    if service_running nimoos-agent || \
       ([ -f /tmp/nimoos-agent.pid ] && kill -0 "$(cat /tmp/nimoos-agent.pid)" 2>/dev/null); then
        HEALTH=$(curl -sf "http://127.0.0.1:${AGENT_PORT}/agent/health" 2>/dev/null | \
            python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','unknown'))" 2>/dev/null || echo "starting")
        echo -e "  nimoos-agent    : \e[32m● running\e[0m  (${HEALTH})"
    else
        echo -e "  nimoos-agent    : \e[90m○ stopped\e[0m"
    fi

    echo "  ─────────────────────────────────────"
    echo ""
}

###############################################################################
# Main
###############################################################################

case "${CMD}" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; sleep 1; do_start ;;
    status)  do_status ;;
    *)
        echo "Usage: $0 [start|stop|restart|status]"
        exit 1
        ;;
esac
