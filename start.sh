#!/usr/bin/env bash
set -euo pipefail

# Dossier persisté (vous avez monté le volume sur /app/data)
mkdir -p /app/data

# Pour que l'UI puisse lire les données (agent_data, etc.)
# On crée un lien dans docs/ vers le dossier data/
ln -sfn ../data /app/docs/data

# Ports MCP (internes au container, pas besoin d'exposer)
export MATH_HTTP_PORT="${MATH_HTTP_PORT:-8000}"
export SEARCH_HTTP_PORT="${SEARCH_HTTP_PORT:-8001}"
export TRADE_HTTP_PORT="${TRADE_HTTP_PORT:-8002}"
export GETPRICE_HTTP_PORT="${GETPRICE_HTTP_PORT:-8003}"
export CRYPTO_HTTP_PORT="${CRYPTO_HTTP_PORT:-8005}"

# Chemin runtime env (recommandé en absolu dans la doc)
export RUNTIME_ENV_PATH="${RUNTIME_ENV_PATH:-/app/runtime_env.json}"

# (Optionnel) Préparer les données si absentes (US / NASDAQ100)
# IMPORTANT : sur Railway, le volume est monté au démarrage, pas au build. :contentReference[oaicite:4]{index=4}
if [ ! -f "/app/data/merged.jsonl" ]; then
  echo "[INIT] merged.jsonl introuvable, génération des données US..."
  (cd /app/data && python /app/data/get_daily_price.py)
  (cd /app/data && python /app/data/merge_jsonl.py)
fi

# 1) Démarrer les services MCP
python -u /app/agent_tools/start_mcp_services.py &
sleep 2

# 2) Lancer la simulation
python -u /app/main.py "${CONFIG_PATH:-/app/configs/default_config.json}" &

# 3) Démarrer l'UI sur le port Railway
cd /app/docs
python -m http.server "${PORT:-8888}"
