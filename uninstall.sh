#!/bin/bash
#
# SSH 아웃바운드 차단 정책 제거
#
#   sudo bash uninstall.sh
#
set -euo pipefail

ANCHOR=com.kyobo.ssh-egress
LABEL=com.kyobo.pf-ssh-egress
PFCONF=/etc/pf.conf

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "root 권한이 필요합니다: sudo bash uninstall.sh" >&2; exit 1; }

info "LaunchDaemon 해제"
launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/$LABEL.plist"
ok "$LABEL"

info "$PFCONF 에서 앵커 제거"
cp "$PFCONF" "${PFCONF}.bak.$(date +%Y%m%d-%H%M%S)"
sed -i '' "/^# >>> ${ANCHOR} /,/^# <<< ${ANCHOR} </d" "$PFCONF"
ok "앵커 등록 해제"

info "파일 제거"
rm -f "/etc/pf.anchors/$ANCHOR" /usr/local/libexec/pf-ssh-egress-apply /usr/local/sbin/ssh-egress-allow
ok "화이트리스트(/etc/pf.anchors/ssh-egress-allow.table)는 감사 목적으로 보존합니다."

info "룰셋 재적재"
pfctl -f "$PFCONF" 2>&1 | sed 's/^/    /' || true
pfctl -a "$ANCHOR" -F rules 2>/dev/null || true

echo
echo "제거 완료. (pf 자체는 다른 서비스가 참조할 수 있어 비활성화하지 않습니다."
echo " 완전히 끄려면: sudo pfctl -d)"
