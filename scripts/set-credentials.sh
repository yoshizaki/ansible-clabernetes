#!/usr/bin/env bash
# =============================================================================
# inventory の認証情報（ユーザー名 / パスワード）とホストアドレスを一括変換する。
#
# 公開リポジトリにはマスク値（user=admin / password="****"）を残し、ローカルで
# 実行する直前にだけ実値を流し込む運用を想定。push 前は `mask` で必ず戻すこと。
#
#   apply : 実値を流し込む（ansible_user / ansible_become_pass / ansible_ssh_pass）
#   mask  : パスワードを **** に戻し ansible_ssh_pass を再コメント化（push 前用）
#   show  : 現在の設定値を表示
#
# 使い方:
#   scripts/set-credentials.sh apply -u <user> -p <password> \
#       [--controller <IP>] [--worker1 <IP>] [--worker2 <IP>]
#   scripts/set-credentials.sh mask
#   scripts/set-credentials.sh show
#
# 例:
#   scripts/set-credentials.sh apply -u tomo -p password
# =============================================================================
set -euo pipefail

# リポジトリルート（このスクリプトの 1 つ上）に移動
cd "$(dirname "$0")/.."

ALL="inventory/group_vars/all.yml"
HOSTS="inventory/hosts.yml"
MASK='****'

die() { echo "ERROR: $*" >&2; exit 1; }

# all.yml の ansible_user を置換
set_user() {
  sed -i -E "s|^ansible_user:.*|ansible_user: ${1}|" "$ALL"
}

# all.yml の become_pass / ssh_pass を置換（password に sed 区切り文字 | が無い前提）
set_pass() {
  local pass="$1"
  [[ "$pass" == *"|"* ]] && die "パスワードに '|' は使えません（スクリプト改修要）"
  sed -i -E "s|^ansible_become_pass:.*|ansible_become_pass: \"${pass}\"|" "$ALL"
  # コメント有無どちらの状態からでも有効化して値を入れる
  sed -i -E "s|^#? *ansible_ssh_pass:.*|ansible_ssh_pass: \"${pass}\"|" "$ALL"
}

# all.yml のパスワードをマスクに戻し ssh_pass を再コメント化
mask_pass() {
  sed -i -E "s|^ansible_become_pass:.*|ansible_become_pass: \"${MASK}\"|" "$ALL"
  sed -i -E "s|^#? *ansible_ssh_pass:.*|# ansible_ssh_pass: \"${MASK}\"|" "$ALL"
}

# hosts.yml の特定ホストの ansible_host を置換
set_host() {
  local host="$1" ip="$2"
  awk -v h="$host" -v ip="$ip" '
    $0 ~ "^[[:space:]]*"h":[[:space:]]*$" { print; inblk=1; next }
    inblk && /ansible_host:/ { sub(/ansible_host:.*/, "ansible_host: " ip); inblk=0 }
    { print }
  ' "$HOSTS" > "${HOSTS}.tmp" && mv "${HOSTS}.tmp" "$HOSTS"
}

show() {
  echo "== ${ALL} =="
  grep -E '^(ansible_user|ansible_become_pass)|ansible_ssh_pass:' "$ALL" || true
  echo "== ${HOSTS} =="
  grep -E 'ansible_host:' "$HOSTS" || true
}

cmd="${1:-}"; shift || true
case "$cmd" in
  apply)
    R_USER="" R_PASS="" C_IP="" W1_IP="" W2_IP=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -u|--user)       R_USER="$2"; shift 2 ;;
        -p|--password)   R_PASS="$2"; shift 2 ;;
        --controller)    C_IP="$2";  shift 2 ;;
        --worker1)       W1_IP="$2"; shift 2 ;;
        --worker2)       W2_IP="$2"; shift 2 ;;
        *) die "不明な引数: $1" ;;
      esac
    done
    [[ -n "$R_USER" ]] || die "apply には -u <user> が必要"
    [[ -n "$R_PASS" ]] || die "apply には -p <password> が必要"
    set_user "$R_USER"
    set_pass "$R_PASS"
    [[ -n "$C_IP"  ]] && set_host controller "$C_IP"
    [[ -n "$W1_IP" ]] && set_host worker1    "$W1_IP"
    [[ -n "$W2_IP" ]] && set_host worker2    "$W2_IP"
    echo "適用しました（push 前に 'mask' で戻すこと）:"
    show
    ;;
  mask)
    mask_pass
    echo "パスワードをマスクしました:"
    show
    ;;
  show)
    show
    ;;
  *)
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
