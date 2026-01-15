#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------
DATA_DIR="/app/data"              # Railway volume mount target
SEED_DIR="/app/_data_seed"        # Seed folder baked into the image (copy of repo data/)
DOCS_DIR="/app/docs"              # UI served from docs/
CONFIG_PATH="${CONFIG_PATH:-/app/configs/default_config.json}"

mkdir -p "${DATA_DIR}"

# ------------------------------------------------------------
# ENV: Ports (internal MCP)
# ------------------------------------------------------------
export MATH_HTTP_PORT="${MATH_HTTP_PORT:-8000}"
export SEARCH_HTTP_PORT="${SEARCH_HTTP_PORT:-8001}"
export TRADE_HTTP_PORT="${TRADE_HTTP_PORT:-8002}"
export GETPRICE_HTTP_PORT="${GETPRICE_HTTP_PORT:-8003}"
export CRYPTO_HTTP_PORT="${CRYPTO_HTTP_PORT:-8005}"

export RUNTIME_ENV_PATH="${RUNTIME_ENV_PATH:-/app/runtime_env.json}"

# ------------------------------------------------------------
# ENV: Data API key (AI-Trader expects ALPHAADVANTAGE_API_KEY)
# - Accept both names to avoid confusion in Railway variables
# ------------------------------------------------------------
export ALPHAADVANTAGE_API_KEY="${ALPHAADVANTAGE_API_KEY:-${ALPHAVANTAGE_API_KEY:-}}"

# ------------------------------------------------------------
# Optional switches
# ------------------------------------------------------------
# FORCE_REFRESH_DATA=1 -> delete merged.jsonl and rebuild it (costly, but fixes old datasets)
# RESET_AGENT_DATA=1   -> delete previous agent position files (agent_data*/**/position.jsonl)
export FORCE_REFRESH_DATA="${FORCE_REFRESH_DATA:-0}"
export RESET_AGENT_DATA="${RESET_AGENT_DATA:-0}"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
is_effectively_empty_dir() {
  local dir="$1"
  local count
  count="$(find "$dir" -mindepth 1 -maxdepth 1 ! -name "lost+found" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${count}" == "0" ]]
}

wait_port() {
  local port="$1"
  local retries="${2:-30}"
  for _ in $(seq 1 "$retries"); do
    if (echo >"/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

max_date_in_merged() {
  # Extract the maximum YYYY-MM-DD date found in merged.jsonl
  python - <<'PY'
import json, sys
path = "/app/data/merged.jsonl"
best = None

def take_date(s: str):
    if not s:
        return None
    # handle "YYYY-MM-DD" or "YYYY-MM-DD HH:MM:SS"
    return s[:10]

try:
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            # common keys in datasets
            for key in ("date", "datetime", "time", "timestamp"):
                if key in obj:
                    d = take_date(str(obj.get(key)))
                    if d and (best is None or d > best):
                        best = d
                    break
except FileNotFoundError:
    pass

if best:
    print(best)
PY
}

# ------------------------------------------------------------
# 1) Seed the volume ONLY with scripts, without forcing old merged.jsonl
# ------------------------------------------------------------
# Goal:
# - Ensure /app/data has get_daily_price.py / merge_jsonl.py
# - DO NOT force an outdated merged.jsonl permanently
#
# We copy seed files only if the script is missing (first boot / wiped volume).
if [[ ! -f "${DATA_DIR}/get_daily_price.py" ]]; then
  if [[ -d "${SEED_DIR}" ]]; then
    echo "[INIT] Seeding missing data scripts into volume (${DATA_DIR})..."
    # Copy everything but do not overwrite existing files
    cp -a -n "${SEED_DIR}/." "${DATA_DIR}/" || true
  else
    echo "[INIT] WARNING: SEED_DIR not found: ${SEED_DIR}"
  fi
fi

# If the seed brought an old merged.jsonl AND we have an Alpha Vantage key,
# remove merged.jsonl so we can rebuild fresh.
if [[ -n "${ALPHAADVANTAGE_API_KEY}" && -f "${DATA_DIR}/merged.jsonl" && "${FORCE_REFRESH_DATA}" == "1" ]]; then
  echo "[INIT] FORCE_REFRESH_DATA=1 -> removing merged.jsonl for full rebuild"
  rm -f "${DATA_DIR}/merged.jsonl"
fi

# ------------------------------------------------------------
# 2) Optional: reset agent outputs
# ------------------------------------------------------------
if [[ "${RESET_AGENT_DATA}" == "1" ]]; then
  echo "[INIT] RESET_AGENT_DATA=1 -> removing existing position.jsonl files under ${DATA_DIR}/agent_data*"
  find "${DATA_DIR}" -path "${DATA_DIR}/agent_data*" -type f -name "position.jsonl" -delete || true
fi

# ------------------------------------------------------------
# 3) Make UI read from the volume (docs/data -> /app/data)
# ------------------------------------------------------------
mkdir -p "${DOCS_DIR}"
if [[ -e "${DOCS_DIR}/data" && ! -L "${DOCS_DIR}/data" ]]; then
  echo "[INIT] Removing existing ${DOCS_DIR}/data to relink to volume..."
  rm -rf "${DOCS_DIR}/data"
fi
ln -sfn "${DATA_DIR}" "${DOCS_DIR}/data"
echo "[INIT] Linked ${DOCS_DIR}/data -> ${DATA_DIR}"

# Avoid UI 404 spam if it expects this file
if [[ ! -f "${DATA_DIR}/us_cache.json" ]]; then
  echo "{}" > "${DATA_DIR}/us_cache.json"
fi

# ------------------------------------------------------------
# 4) Build / refresh US dataset if needed
# ------------------------------------------------------------
# AI-Trader official workflow:
#   cd data
#   python get_daily_price.py
#   python merge_jsonl.py
# :contentReference[oaicite:1]{index=1}
#
# We rebuild when:
# - merged.jsonl missing
# - OR END_DATE > max date in merged.jsonl (best effort)
need_build="0"

if [[ ! -f "${DATA_DIR}/merged.jsonl" ]]; then
  need_build="1"
else
  # if END_DATE is beyond the dataset max date, attempt rebuild
  if [[ -n "${END_DATE:-}" ]]; then
    maxd="$(max_date_in_merged || true)"
    if [[ -n "${maxd}" ]]; then
      # Compare as dates (YYYY-MM-DD)
      if [[ "${END_DATE:0:10}" > "${maxd}" ]]; then
        echo "[INIT] Dataset seems behind: merged max date=${maxd}, END_DATE=${END_DATE:0:10}"
        need_build="1"
      fi
    fi
  fi
fi

if [[ "${need_build}" == "1" ]]; then
  if [[ -z "${ALPHAADVANTAGE_API_KEY}" ]]; then
    echo "[INIT] merged.jsonl missing/outdated BUT no ALPHAADVANTAGE_API_KEY provided."
    echo "[INIT] Skipping refresh (will stay limited to the bundled dataset)."
  else
    echo "[INIT] Building/refreshing US dataset with Alpha Vantage..."
    cd "${DATA_DIR}"

    # IMPORTANT:
    # Free tier Alpha Vantage is limited (~25 requests/day, 5/min),
    # so NASDAQ100 refresh may take a long time / require premium.
    # :contentReference[oaicite:2]{index=2}
    python -u get_daily_price.py
    python -u merge_jsonl.py
  fi
fi

# ------------------------------------------------------------
# 5) Start MCP services
# ------------------------------------------------------------
echo "🚀 Starting MCP services..."
python -u /app/agent_tools/start_mcp_services.py &
MCP_PID="$!"

echo "⏳ Waiting for MCP ports..."
wait_port "${MATH_HTTP_PORT}" 30 || true
wait_port "${SEARCH_HTTP_PORT}" 30 || true
wait_port "${TRADE_HTTP_PORT}" 30 || true
wait_port "${GETPRICE_HTTP_PORT}" 30 || true
wait_port "${CRYPTO_HTTP_PORT}" 30 || true
echo "✅ MCP ports check done."

# ------------------------------------------------------------
# 6) Run the main trading experiment once (background)
# ------------------------------------------------------------
echo "🤖 Starting trading run..."
python -u /app/main.py "${CONFIG_PATH}" &

# ------------------------------------------------------------
# 7) Serve UI (foreground)
# Railway sets PORT automatically; default 8080.
# ------------------------------------------------------------
cd "${DOCS_DIR}"
echo "🌐 Serving UI on 0.0.0.0:${PORT:-8080}"
exec python -m http.server "${PORT:-8080}" --bind 0.0.0.0
