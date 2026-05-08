#!/usr/bin/env bash
# preflight.sh — Pre-deployment validation for Sales Order Management → Veza OAA
#
# Usage:
#   bash preflight.sh --all        # Run all checks non-interactively; exit 0=pass, 1=fail
#   bash preflight.sh              # Interactive menu
#
# Flags:
#   --all          Run all checks non-interactively
#   --env-file     Path to .env file (default: .env)
# ──────────────────────────────────────────────────────────────────────────────
set -o pipefail

# ── Config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
LOG_FILE="${SCRIPT_DIR}/preflight_$(date +%Y%m%d_%H%M%S).log"
RUN_ALL=false

# ── Counters ──────────────────────────────────────────────────────────────────
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_WARNING=0

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_pass()  { echo -e "${GREEN}  ✓ PASS${NC}    $*" | tee -a "${LOG_FILE}"; ((TESTS_PASSED++)); }
print_fail()  { echo -e "${RED}  ✗ FAIL${NC}    $*" | tee -a "${LOG_FILE}"; ((TESTS_FAILED++)); }
print_warn()  { echo -e "${YELLOW}  ⚠ WARN${NC}    $*" | tee -a "${LOG_FILE}"; ((TESTS_WARNING++)); }
print_info()  { echo -e "${BLUE}  ℹ INFO${NC}    $*" | tee -a "${LOG_FILE}"; }
print_section() { echo "" | tee -a "${LOG_FILE}"; echo -e "${BLUE}══ $* ══${NC}" | tee -a "${LOG_FILE}"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)       RUN_ALL=true ;;
    --env-file)  ENV_FILE="$2"; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

# ── Python resolver ───────────────────────────────────────────────────────────
if [[ -f "${SCRIPT_DIR}/venv/bin/python3" ]]; then
  PYTHON="${SCRIPT_DIR}/venv/bin/python3"
  PIP="${SCRIPT_DIR}/venv/bin/pip"
else
  PYTHON="$(command -v python3 || true)"
  PIP="$(command -v pip3 || true)"
fi

# ── Check 1: System Requirements ─────────────────────────────────────────────
check_system_requirements() {
  print_section "1 — System Requirements"

  # Python version
  if [[ -z "${PYTHON}" ]]; then
    print_fail "python3 not found"
  else
    PY_VER=$("${PYTHON}" --version 2>&1 | awk '{print $2}')
    PY_MAJOR=$(echo "${PY_VER}" | cut -d. -f1)
    PY_MINOR=$(echo "${PY_VER}" | cut -d. -f2)
    if [[ "${PY_MAJOR}" -ge 3 && "${PY_MINOR}" -ge 9 ]]; then
      print_pass "Python ${PY_VER}"
    else
      print_fail "Python ${PY_VER} — requires 3.9+"
    fi
  fi

  # pip
  if [[ -n "${PIP}" ]] && "${PIP}" --version &>/dev/null; then
    print_pass "pip: $("${PIP}" --version | awk '{print $2}')"
  else
    print_fail "pip3 not found — install python3-pip"
  fi

  # venv detection
  if [[ "${PYTHON}" == *"venv"* ]]; then
    print_pass "Running inside virtual environment: ${PYTHON}"
  else
    print_warn "Not running in a virtual environment — recommend: python3 -m venv venv && source venv/bin/activate"
  fi

  # OS detection
  if [[ -f /etc/os-release ]]; then
    OS_NAME=$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
    print_info "OS: ${OS_NAME}"
  elif [[ "$(uname)" == "Darwin" ]]; then
    print_info "OS: macOS $(sw_vers -productVersion)"
  else
    print_warn "Could not detect OS from /etc/os-release"
  fi

  # curl
  if command -v curl &>/dev/null; then
    print_pass "curl $(curl --version | head -1 | awk '{print $2}')"
  else
    print_warn "curl not found — HTTPS connectivity tests will be skipped"
  fi

  # jq (optional)
  if command -v jq &>/dev/null; then
    print_pass "jq $(jq --version)"
  else
    print_warn "jq not found (optional) — install for JSON payload inspection"
  fi

  # Oracle thin mode note (no Instant Client required)
  print_info "oracledb thin mode does not require Oracle Instant Client"
}

# ── Check 2: Python Dependencies ─────────────────────────────────────────────
check_python_deps() {
  print_section "2 — Python Dependencies"

  REQUIREMENTS="${SCRIPT_DIR}/requirements.txt"
  if [[ ! -f "${REQUIREMENTS}" ]]; then
    print_fail "requirements.txt not found at ${REQUIREMENTS}"
    return
  fi

  while IFS= read -r line || [[ -n "${line}" ]]; do
    # Strip comments, blank lines, version specifiers
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -z "${line}" ]] && continue

    pkg_name="${line%%[>=<!]*}"
    # Map pip package names to importable module names
    case "${pkg_name}" in
      oaaclient)          import_name="oaaclient" ;;
      python-dotenv)      import_name="dotenv" ;;
      oracledb)           import_name="oracledb" ;;
      *)                  import_name="${pkg_name//-/_}" ;;
    esac

    version=$("${PYTHON}" -c "import ${import_name}; v=getattr(${import_name},'__version__',None) or getattr(${import_name},'VERSION',None); print(v or 'installed')" 2>/dev/null || true)
    if [[ -n "${version}" ]]; then
      print_pass "${pkg_name}: ${version}"
    else
      print_fail "${pkg_name} (import: ${import_name}) — not installed. Run: ${PIP:-pip} install -r ${REQUIREMENTS}"
    fi
  done < "${REQUIREMENTS}"
}

# ── Check 3: Configuration File ───────────────────────────────────────────────
check_configuration() {
  print_section "3 — Configuration File"

  if [[ ! -f "${ENV_FILE}" ]]; then
    print_fail ".env not found at ${ENV_FILE}"
    print_info "To generate a template: cp ${SCRIPT_DIR}/.env.example ${ENV_FILE}"
    return
  fi
  print_pass ".env exists at ${ENV_FILE}"

  # Check file permissions
  PERMS=$(stat -c "%a" "${ENV_FILE}" 2>/dev/null || stat -f "%OLp" "${ENV_FILE}" 2>/dev/null || echo "unknown")
  if [[ "${PERMS}" == "600" ]]; then
    print_pass ".env permissions: ${PERMS}"
  else
    print_warn ".env permissions: ${PERMS} — should be 600. Fix: chmod 600 ${ENV_FILE}"
  fi

  # Source .env safely
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}" 2>/dev/null || true
  set +a

  _mask() {
    local val="$1"
    if [[ -z "${val}" ]]; then echo "(empty)"; return; fi
    echo "${val:0:8}..."
  }

  _check_required() {
    local var="$1"
    local val="${!var:-}"
    if [[ -z "${val}" ]]; then
      print_fail "${var}: not set"
    elif [[ "${val}" == your_* ]] || [[ "${val}" == *"your-"* ]]; then
      print_fail "${var}: still set to placeholder value"
    elif [[ "${var}" =~ PASSWORD|KEY|TOKEN|SECRET ]]; then
      print_pass "${var}: $(_mask "${val}")"
    else
      print_pass "${var}: ${val}"
    fi
  }

  _check_required DB_URL
  _check_required DB_USERNAME
  _check_required DB_PASSWORD
  _check_required VEZA_URL
  _check_required VEZA_API_KEY

  # Optional vars
  [[ -n "${DB_DRIVER_CLASS:-}" ]] && print_info "DB_DRIVER_CLASS: ${DB_DRIVER_CLASS} (informational)"
  [[ -n "${DB_EXTRA_PARAMS:-}" ]] && print_info "DB_EXTRA_PARAMS: ${DB_EXTRA_PARAMS}"
  [[ -n "${PROVIDER_NAME:-}" ]]   && print_info "PROVIDER_NAME: ${PROVIDER_NAME}"
  [[ -n "${DATASOURCE_NAME:-}" ]] && print_info "DATASOURCE_NAME: ${DATASOURCE_NAME}"
}

# ── Check 4: Network Connectivity ────────────────────────────────────────────
check_network() {
  print_section "4 — Network Connectivity"

  # Source .env
  if [[ -f "${ENV_FILE}" ]]; then
    set -a; source "${ENV_FILE}" 2>/dev/null || true; set +a
  fi

  # Parse DB_URL to extract host and port
  # Supported: hostname:port/svc  or  jdbc:oracle:thin:@hostname:port/svc
  RAW_URL="${DB_URL:-}"
  RAW_URL="${RAW_URL#jdbc:oracle:*:@}"
  RAW_URL="${RAW_URL#//}"
  DB_HOST="${RAW_URL%%:*}"
  PORT_AND_REST="${RAW_URL#*:}"
  DB_PORT="${PORT_AND_REST%%/*}"
  DB_PORT="${DB_PORT%%:*}"  # handle SID format  host:port:SID
  DB_PORT="${DB_PORT:-1521}"

  if [[ -n "${DB_HOST}" ]]; then
    print_info "Testing TCP → ${DB_HOST}:${DB_PORT}"
    if nc -zw 5 "${DB_HOST}" "${DB_PORT}" &>/dev/null 2>&1; then
      print_pass "TCP ${DB_HOST}:${DB_PORT} — reachable"
    elif bash -c "exec 3<>/dev/tcp/${DB_HOST}/${DB_PORT}" &>/dev/null 2>&1; then
      print_pass "TCP ${DB_HOST}:${DB_PORT} — reachable (via /dev/tcp)"
    else
      print_fail "TCP ${DB_HOST}:${DB_PORT} — unreachable. Check firewall / DB_URL"
    fi
  else
    print_warn "Could not parse DB host from DB_URL='${DB_URL:-}' — skipping TCP test"
  fi

  # Veza HTTPS
  VEZA_HOST="${VEZA_URL:-}"
  VEZA_HOST="${VEZA_HOST#https://}"
  VEZA_HOST="${VEZA_HOST%%/*}"

  if [[ -n "${VEZA_HOST}" ]] && command -v curl &>/dev/null; then
    RESULT=$(curl -s -o /dev/null -w "%{http_code}|%{time_total}" -m 10 "https://${VEZA_HOST}" 2>/dev/null || echo "000|N/A")
    HTTP_CODE="${RESULT%%|*}"
    LATENCY="${RESULT##*|}"
    if [[ "${HTTP_CODE}" =~ ^[23] ]]; then
      print_pass "HTTPS ${VEZA_HOST} — HTTP ${HTTP_CODE} (${LATENCY}s)"
    elif [[ "${HTTP_CODE}" == "000" ]]; then
      print_fail "HTTPS ${VEZA_HOST} — connection failed (timeout or DNS failure)"
    else
      print_warn "HTTPS ${VEZA_HOST} — HTTP ${HTTP_CODE} (${LATENCY}s) — may still work"
    fi
  else
    print_warn "Veza HTTPS test skipped (VEZA_URL not set or curl unavailable)"
  fi
}

# ── Check 5: API / Database Authentication ────────────────────────────────────
check_authentication() {
  print_section "5 — API / Database Authentication"

  if [[ -f "${ENV_FILE}" ]]; then
    set -a; source "${ENV_FILE}" 2>/dev/null || true; set +a
  fi

  # Oracle DB auth test — lightweight query
  if [[ -n "${DB_URL:-}" && -n "${DB_USERNAME:-}" && -n "${DB_PASSWORD:-}" ]]; then
    DB_AUTH_RESULT=$("${PYTHON}" - <<PYEOF 2>&1
import sys
try:
    import oracledb
    import re
    url = "${DB_URL}"
    url = re.sub(r"^jdbc:oracle:[^:]+:@", "", url)
    url = re.sub(r"^//", "", url)
    m = re.match(r"^([^:/]+):(\d+):([^/]+)\$", url)
    if m:
        url = f"{m.group(1)}:{m.group(2)}/{m.group(3)}"
    conn = oracledb.connect(user="${DB_USERNAME}", password="${DB_PASSWORD}", dsn=url)
    cur = conn.cursor()
    cur.execute("SELECT 1 FROM DUAL")
    cur.close()
    conn.close()
    print("OK")
except Exception as e:
    print(f"FAIL: {e}")
    sys.exit(1)
PYEOF
)
    if [[ "${DB_AUTH_RESULT}" == "OK" ]]; then
      print_pass "Oracle DB authentication — SELECT 1 FROM DUAL succeeded"
    else
      print_fail "Oracle DB authentication failed: ${DB_AUTH_RESULT}"
    fi
  else
    print_warn "DB credentials not set — skipping Oracle auth test"
  fi

  # Veza API key test
  if [[ -n "${VEZA_URL:-}" && -n "${VEZA_API_KEY:-}" ]] && command -v curl &>/dev/null; then
    VEZA_RESULT=$(curl -s -o /dev/null -w "%{http_code}" -m 15 \
      -H "Authorization: Bearer ${VEZA_API_KEY}" \
      "${VEZA_URL%/}/api/v1/providers" 2>/dev/null || echo "000")
    if [[ "${VEZA_RESULT}" == "200" ]]; then
      print_pass "Veza API key — GET /api/v1/providers returned HTTP 200"
    elif [[ "${VEZA_RESULT}" == "401" ]]; then
      print_fail "Veza API key invalid — HTTP 401"
    elif [[ "${VEZA_RESULT}" == "403" ]]; then
      print_fail "Veza API key lacks permissions — HTTP 403"
    else
      print_warn "Veza API key test — HTTP ${VEZA_RESULT} (expected 200)"
    fi
  else
    print_warn "Veza API key test skipped (VEZA_URL/VEZA_API_KEY not set or curl unavailable)"
  fi
}

# ── Check 6: Veza Endpoint Access ─────────────────────────────────────────────
check_veza_endpoint() {
  print_section "6 — Veza Endpoint Access"

  if [[ -f "${ENV_FILE}" ]]; then
    set -a; source "${ENV_FILE}" 2>/dev/null || true; set +a
  fi

  if [[ -n "${VEZA_URL:-}" && -n "${VEZA_API_KEY:-}" ]] && command -v curl &>/dev/null; then
    QUERY_RESULT=$(curl -s -w "\n%{http_code}" -m 15 \
      -H "Authorization: Bearer ${VEZA_API_KEY}" \
      -H "Content-Type: application/json" \
      "${VEZA_URL%/}/api/v1/assessment/api/v1/reports/query" \
      -d '{"query":{"node_type":"LocalUser","limit":1}}' 2>/dev/null)
    HTTP_CODE=$(echo "${QUERY_RESULT}" | tail -1)
    if [[ "${HTTP_CODE}" =~ ^2 ]]; then
      print_pass "Veza Query API — HTTP ${HTTP_CODE} (read access confirmed)"
    else
      print_warn "Veza Query API — HTTP ${HTTP_CODE} (key may lack query permissions)"
    fi
  else
    print_warn "Veza endpoint test skipped"
  fi
}

# ── Check 7: Deployment Structure ─────────────────────────────────────────────
check_deployment_structure() {
  print_section "7 — Deployment Structure"

  MAIN_SCRIPT="${SCRIPT_DIR}/sales_order_management.py"
  if [[ -f "${MAIN_SCRIPT}" && -r "${MAIN_SCRIPT}" ]]; then
    print_pass "Main script exists: ${MAIN_SCRIPT}"
  else
    print_fail "Main script not found: ${MAIN_SCRIPT}"
  fi

  # --help test
  if [[ -f "${MAIN_SCRIPT}" ]]; then
    HELP_OUT=$("${PYTHON}" "${MAIN_SCRIPT}" --help 2>&1 | head -5)
    if echo "${HELP_OUT}" | grep -qi "sales order\|veza\|usage"; then
      print_pass "--help runs without errors"
    else
      print_warn "--help output unexpected: ${HELP_OUT}"
    fi
  fi

  # logs directory
  LOGS_DIR="${SCRIPT_DIR}/logs"
  if [[ -d "${LOGS_DIR}" && -w "${LOGS_DIR}" ]]; then
    print_pass "logs/ directory is writable: ${LOGS_DIR}"
  elif [[ -d "${LOGS_DIR}" ]]; then
    print_fail "logs/ directory not writable: ${LOGS_DIR}  — fix: chmod 775 ${LOGS_DIR}"
  else
    print_info "logs/ directory does not exist — it will be created on first run"
  fi

  # Running user
  print_info "Running as user: $(id -un) (uid=$(id -u))"
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
  echo "" | tee -a "${LOG_FILE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
  echo -e "  ${GREEN}PASSED${NC}:  ${TESTS_PASSED}" | tee -a "${LOG_FILE}"
  echo -e "  ${RED}FAILED${NC}:  ${TESTS_FAILED}" | tee -a "${LOG_FILE}"
  echo -e "  ${YELLOW}WARNINGS${NC}: ${TESTS_WARNING}" | tee -a "${LOG_FILE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
  echo "  Log: ${LOG_FILE}" | tee -a "${LOG_FILE}"
}

# ── Interactive menu ──────────────────────────────────────────────────────────
interactive_menu() {
  while true; do
    echo ""
    echo "━━━ Sales Order Management Preflight ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  1)  System Requirements"
    echo "  2)  Python Dependencies"
    echo "  3)  Configuration File"
    echo "  4)  Network Connectivity"
    echo "  5)  API / Database Authentication"
    echo "  6)  Veza Endpoint Access"
    echo "  7)  Deployment Structure"
    echo "  8)  Run ALL checks"
    echo "  9)  Display current config"
    echo "  10) Generate .env template"
    echo "  0)  Exit"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    IFS= read -r -p "Select option: " opt </dev/tty
    case "${opt}" in
      1) check_system_requirements ;;
      2) check_python_deps ;;
      3) check_configuration ;;
      4) check_network ;;
      5) check_authentication ;;
      6) check_veza_endpoint ;;
      7) check_deployment_structure ;;
      8) run_all_checks ;;
      9) if [[ -f "${ENV_FILE}" ]]; then
           echo ""; sed 's/\(PASSWORD\|KEY\|TOKEN\|SECRET\)=.*/\1=<masked>/' "${ENV_FILE}"
         else
           echo "No .env at ${ENV_FILE}"
         fi ;;
      10) cp "${SCRIPT_DIR}/.env.example" "${ENV_FILE}" && chmod 600 "${ENV_FILE}" \
           && echo "Template written to ${ENV_FILE}" || echo ".env.example not found" ;;
      0) break ;;
      *) echo "Invalid option" ;;
    esac
    print_summary
  done
}

run_all_checks() {
  check_system_requirements
  check_python_deps
  check_configuration
  check_network
  check_authentication
  check_veza_endpoint
  check_deployment_structure
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo "Sales Order Management → Veza OAA — Preflight Validation" | tee "${LOG_FILE}"
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" | tee -a "${LOG_FILE}"

if [[ "${RUN_ALL}" == "true" ]]; then
  run_all_checks
  print_summary
  [[ "${TESTS_FAILED}" -eq 0 ]]; exit $?
else
  interactive_menu
  print_summary
fi
