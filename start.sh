#!/usr/bin/env bash
set -euo pipefail

# Votre volume est monté ici
mkdir -p /app/data

# Si le volume masque le dossier data/ du repo, on restaure les scripts data/ dans le volume
if [ ! -f "/app/data/get_daily_price.py" ] && [ -d "/app/_data_seed" ]; then
  echo "[INIT] Volume détecté sur /app/data : restauration du dossier data/ dans le volume..."
  cp -a /app/_data_seed/. /app/data/
fi

# L'UI lit des fichiers sous docs/data -> on pointe vers /app/data (volume)
ln -sfn /app/data /app/docs/data

# Ports MCP (internes)
export MATH_HTTP_PORT="${MATH_HTTP_PORT:-8000}"
export SEARCH_HTTP_PORT="${SEARCH_HTTP_PORT:-8001}"
export TRADE_HTTP_PORT="${TRADE_HTTP_PORT:-8002}"
export GETPRICE_HTTP_PORT="${GETPRICE_HTTP_PORT:-8003}"
export CRYPTO_HTTP_PORT="${CRYPTO_HTTP_PORT:-8005}"

export RUNTIME_ENV_PATH="${RUNTIME_ENV_PATH:-/app/runtime_env.json}"

# Préparation NASDAQ100 si merged.jsonl absent
# La doc indique bien : cd data ; python get_daily_price.py ; python merge_jsonl.py :contentReference[oaicite:1]{index=1}
if [ ! -f "/app/data/merged.jsonl" ]; then
  echo "[INIT] merged.jsonl introuvable, génération des données US..."
  cd /app/data
  python -u get_daily_price.py
  python -u merge_jsonl.py
fi

# Démarrer MCP
python -u /app/agent_tools/start_mcp_services.py &
sleep 2

# Lancer l'agent principal
python -u /app/main.py "${CONFIG_PATH:-/app/configs/default_config.json}" &

# Démarrer l'UI (Railway fournit PORT automatiquement)
cd /app/docs
python -m http.server "${PORT:-8888}" --bind 0.0.0.0
