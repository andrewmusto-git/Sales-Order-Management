#!/usr/bin/env bash
# install_sales_order_management.sh
# One-command installer for the Sales Order Management → Veza OAA integration.
#
# Usage (interactive):
#   bash install_sales_order_management.sh
#
# Usage (non-interactive / CI):
#   VEZA_URL=https://company.veza.com \
#   VEZA_API_KEY=<key> \
#   DB_URL=hostname:1521/SERVICE_NAME \
#   DB_USERNAME=som_user \
#   DB_PASSWORD=secret \
#   bash install_sales_order_management.sh --non-interactive
#
# Flags:
#   --non-interactive   Read all values from env vars; skip prompts
#   --overwrite-env     Overwrite an existing .env file
#   --install-dir PATH  Override the default install directory
#   --repo-url URL      Override the Git repository URL
#   --branch NAME       Override the branch to clone (default: main)
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
REPO_URL="${REPO_URL:-https://github.com/andrewmusto-git/Sales-Order-Management}"
BRANCH="${BRANCH:-main}"
INTEGRATION_SUBDIR="integrations/sales-order-management"
SLUG="sales-order-management"
INSTALL_DIR="/opt/VEZA/${SLUG}-veza"
SCRIPTS_DIR="${INSTALL_DIR}/scripts"
LOGS_DIR="${INSTALL_DIR}/logs"
NON_INTERACTIVE=false
OVERWRITE_ENV=false

# ── Detect real user when run via sudo ───────────────────────────────────────
REAL_USER="${SUDO_USER:-${USER}}"
REAL_GROUP=$(id -gn "${REAL_USER}" 2>/dev/null || echo "${REAL_USER}")

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Parse flags ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive) NON_INTERACTIVE=true ;;
    --overwrite-env)   OVERWRITE_ENV=true ;;
    --install-dir)     INSTALL_DIR="$2"; SCRIPTS_DIR="${INSTALL_DIR}/scripts"; LOGS_DIR="${INSTALL_DIR}/logs"; shift ;;
    --repo-url)        REPO_URL="$2"; shift ;;
    --branch)          BRANCH="$2"; shift ;;
    *) die "Unknown flag: $1" ;;
  esac
  shift
done

# ── OS detection ──────────────────────────────────────────────────────────────
OS_ID=""
PKG_MGR=""
if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  OS_ID=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
fi

if command -v dnf &>/dev/null; then
  PKG_MGR="dnf"
elif command -v yum &>/dev/null; then
  PKG_MGR="yum"
elif command -v apt-get &>/dev/null; then
  PKG_MGR="apt-get"
else
  die "Unsupported OS — no dnf, yum, or apt-get found."
fi

info "Detected OS: ${OS_ID:-unknown} | Package manager: ${PKG_MGR}"

# ── Package installer (one at a time) ────────────────────────────────────────
_install_pkg() {
  local pkg="$1"
  info "Installing ${pkg}..."
  case "${PKG_MGR}" in
    dnf|yum) "${PKG_MGR}" install -y "${pkg}" >/dev/null 2>&1 || warn "Could not install ${pkg} — continuing" ;;
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkg}" >/dev/null 2>&1 || warn "Could not install ${pkg} — continuing" ;;
  esac
}

# ── System dependencies ───────────────────────────────────────────────────────
info "Checking system dependencies..."

command -v git &>/dev/null     || _install_pkg git
command -v python3 &>/dev/null || _install_pkg python3

python3 -m pip --version &>/dev/null || {
  case "${PKG_MGR}" in
    dnf|yum) _install_pkg python3-pip ;;
    apt-get) _install_pkg python3-pip ;;
  esac
}

# curl — skip on Amazon Linux if curl-minimal is already present
if ! command -v curl &>/dev/null; then
  if [[ "${OS_ID}" == "amzn" ]]; then
    warn "Skipping curl install on Amazon Linux (curl-minimal conflict) — curl not found, some checks may fail"
  else
    _install_pkg curl
  fi
fi

# python3-venv — not a separate package on Amazon Linux 2023 / RHEL 9+
if ! python3 -m venv --help &>/dev/null 2>&1; then
  case "${PKG_MGR}" in
    dnf|yum) _install_pkg python3-virtualenv ;;
    apt-get) _install_pkg python3-venv ;;
  esac
fi

# ── Python version check ──────────────────────────────────────────────────────
PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
PY_MAJOR=$(echo "${PY_VER}" | cut -d. -f1)
PY_MINOR=$(echo "${PY_VER}" | cut -d. -f2)

if [[ "${PY_MAJOR}" -lt 3 ]] || { [[ "${PY_MAJOR}" -eq 3 ]] && [[ "${PY_MINOR}" -lt 9 ]]; }; then
  die "Python 3.9 or higher required (found ${PY_VER})"
fi
ok "Python ${PY_VER} — OK"

# ── Directory layout ──────────────────────────────────────────────────────────
info "Creating install directory: ${INSTALL_DIR}"
mkdir -p "${SCRIPTS_DIR}" "${LOGS_DIR}"
chmod 750 "${INSTALL_DIR}"

# ── Clone and copy integration files ─────────────────────────────────────────
info "Cloning repository: ${REPO_URL} (branch: ${BRANCH})"
tmp_dir=$(mktemp -d)
trap 'rm -rf "${tmp_dir}"' EXIT

GIT_TERMINAL_PROMPT=0 git clone \
  --branch "${BRANCH}" \
  --depth 1 \
  --single-branch \
  "${REPO_URL}" \
  "${tmp_dir}" || die "git clone failed — check REPO_URL and network access"

SRC_DIR="${tmp_dir}/${INTEGRATION_SUBDIR}"
[[ -d "${SRC_DIR}" ]] || die "Integration directory not found in repo: ${INTEGRATION_SUBDIR}"

cp -f "${SRC_DIR}/sales_order_management.py" "${SCRIPTS_DIR}/"
cp -f "${SRC_DIR}/requirements.txt"          "${SCRIPTS_DIR}/"
[[ -f "${SRC_DIR}/preflight.sh" ]] && cp -f "${SRC_DIR}/preflight.sh" "${SCRIPTS_DIR}/"

ok "Integration files copied to ${SCRIPTS_DIR}"

# ── Python virtual environment ────────────────────────────────────────────────
info "Creating Python virtual environment..."
python3 -m venv "${SCRIPTS_DIR}/venv" || die "Failed to create venv"
"${SCRIPTS_DIR}/venv/bin/pip" install --quiet --upgrade pip
"${SCRIPTS_DIR}/venv/bin/pip" install --quiet -r "${SCRIPTS_DIR}/requirements.txt" \
  || die "Failed to install Python dependencies"
ok "Python dependencies installed"

# ── Credential prompts ────────────────────────────────────────────────────────
_prompt() {
  local label="$1" var_name="$2" default="${3:-}"
  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    # In non-interactive mode, value must already be set in the environment
    return
  fi
  local current="${!var_name:-}"
  if [[ -n "${current}" ]]; then
    echo "  ${label}: [using env var]"
    return
  fi
  IFS= read -r -p "  ${label}${default:+ [${default}]}: " "${var_name}" </dev/tty
  if [[ -z "${!var_name}" ]] && [[ -n "${default}" ]]; then
    printf -v "${var_name}" '%s' "${default}"
  fi
}

_prompt_secret() {
  local label="$1" var_name="$2"
  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    return
  fi
  local current="${!var_name:-}"
  if [[ -n "${current}" ]]; then
    echo "  ${label}: [using env var]"
    return
  fi
  IFS= read -r -s -p "  ${label}: " "${var_name}" </dev/tty
  echo >/dev/tty
}

echo ""
echo "━━━ Veza Configuration ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
_prompt        "Veza URL (e.g. https://company.veza.com)" VEZA_URL
_prompt_secret "Veza API Key" VEZA_API_KEY

echo ""
echo "━━━ Oracle Database Configuration ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DB_URL format: hostname:port/SERVICE_NAME"
echo "    or JDBC:     jdbc:oracle:thin:@hostname:port/SERVICE_NAME"
_prompt        "DB URL" DB_URL
_prompt        "DB Username" DB_USERNAME
_prompt_secret "DB Password" DB_PASSWORD
_prompt        "JDBC Driver Class" DB_DRIVER_CLASS "oracle.jdbc.OracleDriver"

echo ""
echo "━━━ OAA Provider Settings (press Enter for defaults) ━━━━━━━━━━━━━━━━━━━"
_prompt "Provider Name" PROVIDER_NAME "Sales Order Management"
_prompt "Datasource Name" DATASOURCE_NAME "SOM"

# ── Validate required values ──────────────────────────────────────────────────
for var in VEZA_URL VEZA_API_KEY DB_URL DB_USERNAME DB_PASSWORD; do
  [[ -n "${!var:-}" ]] || die "Required value not set: ${var}"
done

# ── Write .env ────────────────────────────────────────────────────────────────
ENV_FILE="${SCRIPTS_DIR}/.env"

if [[ -f "${ENV_FILE}" ]] && [[ "${OVERWRITE_ENV}" != "true" ]]; then
  warn ".env already exists at ${ENV_FILE} — skipping. Use --overwrite-env to replace."
else
  cat > "${ENV_FILE}" <<EOF
# Sales Order Management → Veza OAA Integration
# Generated by installer on $(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Oracle Database
DB_URL=${DB_URL}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}
DB_DRIVER_CLASS=${DB_DRIVER_CLASS:-oracle.jdbc.OracleDriver}
# DB_EXTRA_PARAMS=

# Veza
VEZA_URL=${VEZA_URL}
VEZA_API_KEY=${VEZA_API_KEY}

# OAA Provider (optional overrides)
PROVIDER_NAME=${PROVIDER_NAME:-Sales Order Management}
DATASOURCE_NAME=${DATASOURCE_NAME:-SOM}
EOF
  chmod 600 "${ENV_FILE}"
  ok ".env written to ${ENV_FILE} (chmod 600)"
fi

# ── Fix ownership so the real user can access without sudo ──────────────────
if [[ "${REAL_USER}" != "root" ]]; then
  chown -R "${REAL_USER}:${REAL_GROUP}" "${INSTALL_DIR}"
  ok "Ownership of ${INSTALL_DIR} set to ${REAL_USER}:${REAL_GROUP}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok "Installation complete!"
echo ""
echo "  Install directory : ${INSTALL_DIR}"
echo "  Scripts           : ${SCRIPTS_DIR}"
echo "  Logs              : ${LOGS_DIR}"
echo "  Config            : ${ENV_FILE}"
echo ""
echo "  ── Dry run (validate without pushing) ──────────────────────────────"
echo "  cd ${SCRIPTS_DIR}"
echo "  ./venv/bin/python3 sales_order_management.py --dry-run"
echo ""
echo "  ── Live push ───────────────────────────────────────────────────────"
echo "  cd ${SCRIPTS_DIR}"
echo "  ./venv/bin/python3 sales_order_management.py --env-file .env"
echo ""
echo "  ── Preflight check ─────────────────────────────────────────────────"
echo "  cd ${SCRIPTS_DIR}"
echo "  bash preflight.sh --all"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
