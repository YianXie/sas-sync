#!/bin/bash
# Find a Python that has the Google libraries (Hermes venv path changes after updates)
PY=""
for c in $(command -v python 2>/dev/null) $(ls -t "$HOME"/.hermes/installs/*/environments/*/venv/bin/python 2>/dev/null) python3; do
  if "$c" -c "import google_auth_oauthlib, googleapiclient, markdown" 2>/dev/null; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "error: no python with google libs found"; exit 1; }
exec "$PY" "$HOME/.hermes/scripts/sas_bulletin.py" "$@"
