#!/usr/bin/env bash
# One container, two cooperating processes: the Go gateway and the Python manager.
set -Eeuo pipefail

STATIC_DIR=/opt/workbuddy2api
DATA_ROOT="${WB_UPSTREAM_RUNTIME_DIR:-/var/lib/workbuddy2api}"
CONFIG_FILE="${WB_UPSTREAM_CONFIG:-${DATA_ROOT}/config.json}"
AUTH_DIR="${WB_AUTH_DIR:-${DATA_ROOT}/auths}"
STATE_DIR="${WB_UPSTREAM_DATA_DIR:-${DATA_ROOT}/data}"
PID_FILE="${WB2API_PID_FILE:-/tmp/workbuddy2api.pid}"
LOG_FILE="${WB2API_LOG_FILE:-/app/data/workbuddy2api.log}"
GATEWAY_BIN="${WB2API_BIN:-${STATIC_DIR}/wb2api}"
shutting_down=0
gateway_pid=''
manager_pid=''

if [[ "$(id -u)" == '0' ]]; then
  mkdir -p /app/data "${DATA_ROOT}"
  chown -R 10001:10001 /app/data "${DATA_ROOT}"
  exec gosu app "$0" "$@"
fi

mkdir -p "$(dirname "${CONFIG_FILE}")" "${AUTH_DIR}" "${STATE_DIR}" "$(dirname "${LOG_FILE}")"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  python3 - "${CONFIG_FILE}" "${WB2API_KEY:-}" <<'PY'
import json
import secrets
import sys

target, key = sys.argv[1:]
with open('/usr/local/share/workbuddy2api/config.example.json', encoding='utf-8') as fh:
    config = json.load(fh)
config['api_key'] = key or secrets.token_hex(32)
config['auth_dir'] = '/var/lib/workbuddy2api/auths'
config['state_file'] = '/var/lib/workbuddy2api/data/state.json'
with open(target, 'w', encoding='utf-8') as fh:
    json.dump(config, fh, ensure_ascii=False, indent=2)
    fh.write('\n')
PY
  chmod 600 "${CONFIG_FILE}"
fi

start_gateway() {
  while (( ! shutting_down )); do
    "${GATEWAY_BIN}" -config "${CONFIG_FILE}" > >(tee -a "${LOG_FILE}") 2>&1 &
    gateway_pid=$!
    printf '%s\n' "${gateway_pid}" > "${PID_FILE}"
    wait "${gateway_pid}" || true
    rm -f "${PID_FILE}"
    gateway_pid=''
    (( shutting_down )) || sleep 1
  done
}

shutdown() {
  shutting_down=1
  [[ -n "${manager_pid}" ]] && kill -TERM "${manager_pid}" 2>/dev/null || true
  [[ -n "${gateway_pid}" ]] && kill -TERM "${gateway_pid}" 2>/dev/null || true
}
trap shutdown INT TERM

cd "${STATIC_DIR}"
start_gateway &
gateway_supervisor=$!

python -m uvicorn server.main:app --host "${WB_MANAGER_HOST:-0.0.0.0}" \
  --port "${WB_MANAGER_PORT:-7864}" &
manager_pid=$!
wait "${manager_pid}" || manager_status=$?
manager_status=${manager_status:-0}

shutdown
wait "${gateway_supervisor}" 2>/dev/null || true
exit "${manager_status}"
