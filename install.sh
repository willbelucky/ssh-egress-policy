#!/bin/bash
#
# SSH 아웃바운드 차단 정책 설치 스크립트 (macOS / pf)
#
#   sudo bash install.sh
#
# 멱등적으로 동작한다. 재실행해도 화이트리스트는 보존된다.
#
set -euo pipefail

ANCHOR=com.kyobo.ssh-egress
LABEL=com.kyobo.pf-ssh-egress
LABEL443=com.kyobo.pf-ssh-egress-deny443
PFCONF=/etc/pf.conf
SRC="$(cd "$(dirname "$0")" && pwd)"
MARK_BEGIN="# >>> ${ANCHOR} (managed — do not edit by hand) >>>"
MARK_END="# <<< ${ANCHOR} <<<"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "root 권한이 필요합니다: sudo bash install.sh" >&2; exit 1; }

# ── 1. 백업 ────────────────────────────────────────────────────────────
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="${PFCONF}.bak.${STAMP}"
info "기존 설정 백업"
cp "$PFCONF" "$BACKUP"
ok "$BACKUP"

# ── 2. 앵커 / 화이트리스트 설치 ────────────────────────────────────────
info "pf 앵커 설치"
install -d -m 755 -o root -g wheel /etc/pf.anchors
install -m 644 -o root -g wheel "$SRC/pf.anchors/$ANCHOR" "/etc/pf.anchors/$ANCHOR"
ok "/etc/pf.anchors/$ANCHOR"

if [ -f /etc/pf.anchors/ssh-egress-allow.table ]; then
    warn "화이트리스트가 이미 존재 — 덮어쓰지 않고 보존합니다."
else
    install -m 644 -o root -g wheel \
        "$SRC/pf.anchors/ssh-egress-allow.table" /etc/pf.anchors/ssh-egress-allow.table
    ok "/etc/pf.anchors/ssh-egress-allow.table (비어 있음 = 전면 차단)"
fi

# SSH-over-443 차단 설정. .hosts / .protect 는 운영자가 편집하는 파일이므로
# 재설치 시 보존한다. .table 은 자동 생성물이라 없을 때만 씨앗을 깔아 둔다
# (앵커의 `table ... file` 지시자가 로드 시점에 파일 존재를 요구한다).
info "SSH-over-443 차단 설정 설치"
for f in ssh-egress-deny443.hosts ssh-egress-deny443.protect; do
    if [ -f "/etc/pf.anchors/$f" ]; then
        warn "$f 이미 존재 — 보존합니다."
    else
        install -m 644 -o root -g wheel "$SRC/pf.anchors/$f" "/etc/pf.anchors/$f"
        ok "/etc/pf.anchors/$f"
    fi
done
if [ -f /etc/pf.anchors/ssh-egress-deny443.table ]; then
    ok "/etc/pf.anchors/ssh-egress-deny443.table (기존 목록 유지 — 아래에서 갱신)"
else
    install -m 644 -o root -g wheel \
        "$SRC/pf.anchors/ssh-egress-deny443.table" /etc/pf.anchors/ssh-egress-deny443.table
    ok "/etc/pf.anchors/ssh-egress-deny443.table (비어 있음 — 아래에서 채움)"
fi

# ── 3. pf.conf 에 앵커 등록 (멱등) ─────────────────────────────────────
info "$PFCONF 에 앵커 등록"
if grep -qF "$MARK_BEGIN" "$PFCONF"; then
    ok "이미 등록되어 있음 — 건너뜀"
else
    # 필터 앵커는 nat/rdr 앵커 뒤에 와야 하므로 파일 끝에 추가한다.
    {
        echo ""
        echo "$MARK_BEGIN"
        echo "anchor \"$ANCHOR\""
        echo "load anchor \"$ANCHOR\" from \"/etc/pf.anchors/$ANCHOR\""
        echo "$MARK_END"
    } >> "$PFCONF"
    ok "앵커 2줄 추가"
fi

# ── 4. 문법 검증 (dry-run) — 실패 시 즉시 롤백 ─────────────────────────
info "룰셋 문법 검증 (pfctl -n)"
if ! pfctl -n -f "$PFCONF" 2>&1 | sed 's/^/    /'; then
    warn "검증 실패 — $PFCONF 를 백업본으로 되돌립니다."
    cp "$BACKUP" "$PFCONF"
    exit 1
fi
ok "문법 정상"

# ── 5. 실행 스크립트 / 데몬 설치 ───────────────────────────────────────
info "관리 스크립트 설치"
install -d -m 755 -o root -g wheel /usr/local/libexec /usr/local/sbin
install -m 755 -o root -g wheel "$SRC/libexec/pf-ssh-egress-apply"   /usr/local/libexec/pf-ssh-egress-apply
install -m 755 -o root -g wheel "$SRC/libexec/pf-ssh-egress-deny443" /usr/local/libexec/pf-ssh-egress-deny443
install -m 755 -o root -g wheel "$SRC/sbin/ssh-egress-allow"         /usr/local/sbin/ssh-egress-allow
ok "/usr/local/libexec/pf-ssh-egress-apply"
ok "/usr/local/libexec/pf-ssh-egress-deny443"
ok "/usr/local/sbin/ssh-egress-allow"

info "LaunchDaemon 설치 (부팅 시 적용 + 5분 주기 자가치유)"
install -m 644 -o root -g wheel "$SRC/LaunchDaemons/$LABEL.plist" "/Library/LaunchDaemons/$LABEL.plist"
launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "/Library/LaunchDaemons/$LABEL.plist"
ok "$LABEL"

info "LaunchDaemon 설치 (SSH-over-443 차단 IP 6시간 주기 갱신)"
install -m 644 -o root -g wheel "$SRC/LaunchDaemons/$LABEL443.plist" "/Library/LaunchDaemons/$LABEL443.plist"
launchctl bootout "system/$LABEL443" 2>/dev/null || true
launchctl bootstrap system "/Library/LaunchDaemons/$LABEL443.plist"
ok "$LABEL443"

# ── 6. 즉시 적용 ───────────────────────────────────────────────────────
info "pflog0 확보 (차단 시도 로깅용)"
if ifconfig pflog0 >/dev/null 2>&1; then
    ok "이미 존재"
else
    ifconfig pflog0 create 2>&1 | sed 's/^/    /' || true
    ifconfig pflog0 up 2>/dev/null || true
    if ifconfig pflog0 >/dev/null 2>&1; then
        ok "pflog0 생성"
    else
        warn "pflog0 생성 실패 — 차단은 동작하지만 감사 로그가 남지 않습니다."
    fi
fi

info "정책 즉시 적용"
pfctl -f "$PFCONF" 2>&1 | sed 's/^/    /' || true
pfctl -E 2>&1 | sed 's/^/    /' || true

# ── 7. 검증 ────────────────────────────────────────────────────────────
echo
info "설치 결과"
if pfctl -a "$ANCHOR" -s rules 2>/dev/null | grep -q '^block return in'; then
    ok "차단 규칙이 커널에 적재됨"
    pfctl -a "$ANCHOR" -s rules 2>/dev/null | sed 's/^/    /'
else
    warn "차단 규칙을 확인하지 못했습니다. 'sudo ssh-egress-allow status' 로 점검하세요."
    exit 1
fi

# ── 8. SSH-over-443 차단 IP 채우기 ─────────────────────────────────────
# 앵커에는 규칙만 있고 대상 IP 는 비어 있는 상태다. DNS 로 해석해 채운다.
# 실패해도 설치를 중단하지 않는다 — 22 번 차단은 이미 동작 중이고, 443 차단은
# 6시간 주기 데몬이 다음 차례에 다시 시도한다.
echo
info "SSH-over-443 차단 IP 갱신"
if VERBOSE=1 /usr/local/libexec/pf-ssh-egress-deny443 2>&1 | sed 's/^/    /'; then
    ok "갱신 완료"
else
    warn "갱신 실패 (DNS 등) — 22번 차단은 정상 동작합니다."
    warn "복구: sudo /usr/local/sbin/ssh-egress-allow deny443 refresh"
fi

# ── 9. 실증 검증 ───────────────────────────────────────────────────────
# 규칙이 적재된 것과 실제로 막히는 것은 다르다. 기본 거부는 route-to 로
# lo0 를 경유시키는데, 이 우회가 동작하지 않는 환경이라면 pass 규칙만 남아
# SSH 가 그대로 나가버릴 수 있다. 그래서 물리 인터페이스로 SYN 이 새는지를
# 패킷 수준에서 확인하고, 새면 즉시 원복한다.
echo
info "실증 검증 (패킷 수준)"
set +e
/usr/local/sbin/ssh-egress-allow verify | sed 's/^/    /'
VERIFY_RC=${PIPESTATUS[0]}
set -e

if [ "$VERIFY_RC" -eq 2 ]; then
    echo
    warn "차단이 동작하지 않습니다 — $PFCONF 를 백업본으로 되돌립니다."
    cp "$BACKUP" "$PFCONF"
    pfctl -f "$PFCONF" 2>&1 | sed 's/^/    /' || true
    pfctl -a "$ANCHOR" -F rules 2>/dev/null || true
    exit 1
elif [ "$VERIFY_RC" -ne 0 ]; then
    echo
    warn "차단은 동작하지만 일부 항목이 기대와 다릅니다 (위 출력 참고)."
fi

echo
cat <<'EOF'
설치 완료.

관리 CLI 는 절대 경로로 실행한다. sudo 의 secure_path 에 /usr/local/sbin 이
없어(macOS 기본값) `sudo ssh-egress-allow` 는 command not found 로 끝난다.

  화이트리스트 추가 : sudo /usr/local/sbin/ssh-egress-allow add <ip|cidr> "사유 (티켓번호)"
  화이트리스트 제거 : sudo /usr/local/sbin/ssh-egress-allow remove <ip|cidr>
  현재 상태 확인    : sudo /usr/local/sbin/ssh-egress-allow status
  실증 검증         : sudo /usr/local/sbin/ssh-egress-allow verify
  443 차단 목록     : sudo /usr/local/sbin/ssh-egress-allow deny443 list
  443 차단 갱신     : sudo /usr/local/sbin/ssh-egress-allow deny443 refresh
  차단 시도 감사    : sudo tcpdump -n -e -ttt -i pflog0
  제거              : sudo bash uninstall.sh
EOF
