#!/usr/bin/env bash
# Builds hosts.ini from the Terraform outputs, so no IP is ever typed by hand.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${TF_DIR:-$SCRIPT_DIR/../terraform}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${1:-${SSH_KEY:-~/.ssh/project.pem}}"
OUT="$SCRIPT_DIR/hosts.ini"

tf_out() {
  local value
  value="$(terraform -chdir="$TF_DIR" output -raw "$1")"
  if [[ -z "$value" ]]; then
    echo "Terraform output '$1' is empty. Did 'terraform apply' finish?" >&2
    exit 1
  fi
  printf '%s' "$value"
}

CP_PUBLIC="$(tf_out control_plane_public_ip)"
CP_PRIVATE="$(tf_out control_plane_private_ip)"
WK_PUBLIC="$(tf_out worker_public_ip)"

cat > "$OUT" <<EOF
[master]
master-node ansible_host=${CP_PUBLIC} private_ip=${CP_PRIVATE}

[workers]
worker-1 ansible_host=${WK_PUBLIC}

[all:vars]
ansible_user=${SSH_USER}
ansible_ssh_private_key_file=${SSH_KEY}
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new'
EOF

echo "Wrote $OUT"
cat "$OUT"
