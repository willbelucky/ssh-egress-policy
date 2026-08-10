# SSH 아웃바운드 차단 정책 (macOS / pf)

네트워크 계층(pf, macOS 내장 패킷 필터)에서 **TCP/22 아웃바운드를 기본 차단**하고,
화이트리스트에 등록된 목적지만 예외적으로 허용한다.

## 설계

```
                    ┌──────────────────────────────┐
  outbound TCP/22 → │  anchor com.kyobo.ssh-egress │
                    ├──────────────────────────────┤
                    │ 1. 127.0.0.0/8, ::1  → pass  │  로컬은 항상 허용
                    │ 2. <ssh_egress_allow> → pass │  화이트리스트
                    │ 3. any        → route-to lo0 │  기본 거부
                    └──────────────┬───────────────┘
                                   │
                    ┌──────────────▼───────────────┐
                    │  block return in on lo0      │  RST 반환 + pflog0 기록
                    └──────────────────────────────┘
```

핵심은 **전용 앵커(anchor)** 로 분리했다는 점이다. `/etc/pf.conf` 본문에는
앵커를 불러오는 2줄만 추가되므로, Apple 기본 룰셋이나 다른 보안 제품의
pf 규칙과 충돌하지 않고, 제거도 그 2줄만 지우면 된다.

화이트리스트는 pf **테이블**이라 규칙 재작성 없이 런타임에 추가/삭제된다.
`persist file` 지시자를 써서 파일이 곧 원본(single source of truth)이고,
재부팅·룰셋 리로드 후에도 자동 복원된다.

### 왜 lo0 를 경유시키는가

차단은 드롭이 아니라 **RST 즉시 반환**이어야 한다. 타임아웃까지 매달리면
사용자는 정책 위반이 아니라 네트워크 장애로 오해한다.

그런데 macOS 의 pf 는 `block return out` 이 만든 RST 를 로컬 소켓까지
되돌려주지 못한다(RST 가 물리 인터페이스로 나가버린다). 결과적으로 동작은
조용한 드롭이 되고, `nc -z <host> 22` 는 연결 타임아웃까지 대기한다.

그래서 차단 대상 SYN 을 `route-to (lo0 127.0.0.1)` 로 루프백에 밀어 넣고
lo0 의 **in 방향**에서 `block return` 한다. 이 방향에서 생성된 RST 는 lo0 를
거쳐 로컬 TCP 스택까지 정상 전달되므로 `connect()` 가 즉시 `ECONNREFUSED`
로 실패한다.

이 구조의 대가는 기본 거부가 `block` 이 아니라 `pass ... route-to` 라는
점이다. 만약 route-to 가 무시되는 환경이라면 SSH 가 그대로 나가버릴 수
있으므로, `install.sh` 는 설치 직후 물리 인터페이스에 TCP/22 SYN 이 실제로
새어 나가는지를 tcpdump 로 확인하고 새면 `/etc/pf.conf` 를 즉시 원복한다
(→ `ssh-egress-allow verify`).

### pflog0

`log` 규칙의 기록은 `pflog0` 인터페이스로 나가는데, macOS 는 이 인터페이스를
자동으로 만들어 주지 않는다. `install.sh` 와 `pf-ssh-egress-apply` 가 없으면
`ifconfig pflog0 create` 로 생성한다(부팅 후에도 자가치유 주기에 복원됨).
pflog0 가 없어도 차단 자체는 동작하지만 감사 로그가 남지 않는다.

### 파일 배치

| 원본 | 설치 위치 | 역할 |
|---|---|---|
| `pf.anchors/com.kyobo.ssh-egress` | `/etc/pf.anchors/com.kyobo.ssh-egress` | 차단 규칙 |
| `pf.anchors/ssh-egress-allow.table` | `/etc/pf.anchors/ssh-egress-allow.table` | 화이트리스트 (편집 대상) |
| `sbin/ssh-egress-allow` | `/usr/local/sbin/ssh-egress-allow` | 화이트리스트 관리 CLI |
| `libexec/pf-ssh-egress-apply` | `/usr/local/libexec/pf-ssh-egress-apply` | 적용/자가치유 스크립트 |
| `LaunchDaemons/com.kyobo.pf-ssh-egress.plist` | `/Library/LaunchDaemons/` | 부팅 적용 + 5분 주기 점검 |

## 설치

```sh
sudo bash install.sh
```

설치 스크립트는 `pfctl -n` 으로 **문법을 먼저 검증**하고, 적용 후에는
**패킷 수준에서 실제 차단 여부를 검증**한다. 어느 쪽이든 실패하면
`/etc/pf.conf` 를 백업본으로 되돌린 뒤 중단한다. 재실행해도 안전하며
기존 화이트리스트를 덮어쓰지 않는다.

## 운용

root 가 필요한 명령은 **절대 경로**로 실행한다. macOS 의 sudoers 는
`secure_path="/usr/bin:/bin:/usr/sbin:/sbin"` 로 고정되어 있어 `/usr/local/sbin`
이 빠져 있고, `sudo ssh-egress-allow` 는 `command not found` 로 끝난다.
(secure_path 에 `/usr/local/sbin` 을 추가하는 방법도 있지만, 관리자가 쓸 수
있는 디렉터리를 sudo 검색 경로에 넣는 것이라 권한 상승 경로가 되므로
보안 통제를 배포하는 이 저장소에서는 권하지 않는다.)

```sh
# 상태 확인 (pf 활성 여부 + 적용 규칙 + 커널 테이블)
sudo /usr/local/sbin/ssh-egress-allow status

# 실증 검증 (규칙 적재 / SYN 유출 / 즉시 거부 여부 / pflog0)
sudo /usr/local/sbin/ssh-egress-allow verify

# 예외 추가 — 사유 필수(감사 추적)
sudo /usr/local/sbin/ssh-egress-allow add 192.0.2.10/32 "사내 빌드서버 (INFRA-123)"

# 예외 제거
sudo /usr/local/sbin/ssh-egress-allow remove 192.0.2.10/32

# 목록 (root 불필요)
ssh-egress-allow list

# 특정 목적지 도달 여부 테스트 (root 불필요)
ssh-egress-allow test github.com

# 차단 시도 실시간 감사
sudo tcpdump -n -e -ttt -i pflog0
```

짧게 쓰고 싶다면 셸 별칭을 두면 된다.

```sh
alias ssh-egress='sudo /usr/local/sbin/ssh-egress-allow'
```

`add`/`remove` 는 파일 수정 후 즉시 커널 테이블에 반영하며,
실패하면 파일을 자동 롤백한다. 재부팅이 필요 없다.

### 호스트명 대신 CIDR 을 쓸 것

pf 는 호스트명을 **로드 시점에 1회만** DNS 해석한다. IP 가 도는 서비스는
CIDR 로 등록해야 한다. 예를 들어 GitHub 을 허용해야 한다면:

```sh
curl -s https://api.github.com/meta | python3 -c \
  'import json,sys; [print(c) for c in json.load(sys.stdin)["git"] if ":" not in c]'
# 출력된 CIDR 을 각각 add
```

단 이 대역은 GitHub 이 수시로 갱신하므로, 예외를 열 거라면 주기적
재동기화 잡을 별도로 두는 편이 안전하다.

## 제거

```sh
sudo bash uninstall.sh
```

## 한계 — 반드시 인지할 것

이 통제는 **사고 방지용 가드레일**이지, 의도적 우회까지 막는 봉쇄선이 아니다.

1. **포트 기반이라 비표준 포트 SSH 는 못 막는다.** 특히 GitHub 은
   `ssh.github.com:443` 을 공식 지원한다. 443 을 막을 수는 없으므로
   `git@ssh.github.com:443` 경로는 이 정책을 통과한다.
   → 아래 "git URL 강제 치환"을 함께 적용할 것을 권한다.
2. **sudo 권한자는 `pfctl -d` 로 끌 수 있다.** LaunchDaemon 이 5분 안에
   되살리고 그 사이 로그가 남지만, 관리자 권한 자체를 회수하지 않는 한
   기술적 봉쇄는 불가능하다. 로컬 관리자 권한 회수나 MDM 기반 배포가
   필요하다면 그건 별도 과제다.
3. **호스트 단위 통제다.** 조직 전체에 강제하려면 MDM(Jamf/Intune)으로
   이 번들을 배포하거나, 사내 방화벽/프록시에서 동일 정책을 거는 편이
   근본적이다. 이 저장소는 그 배포 단위로 그대로 쓸 수 있게 구성했다.

### 함께 적용 권장: git URL 강제 치환

포트 우회를 포함해 "실수로 SSH 로 clone" 자체를 원천 차단한다.
사용자 단위 설정이라 별도로 적용한다.

```sh
git config --global url."https://github.com/".insteadOf "git@github.com:"
git config --global url."https://github.com/".insteadOf "ssh://git@github.com/"
git config --global url."https://github.com/".insteadOf "git@ssh.github.com:"
```

이후 `git clone git@github.com:org/repo.git` 은 자동으로 HTTPS 로 바뀐다.
