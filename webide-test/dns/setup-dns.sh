#!/usr/bin/env bash
# 로컬 와일드카드 DNS 설정 (dnsmasq + macOS /etc/resolver).
# *.gitlab.localhost.me / *.test.localhost.me -> 127.0.0.1
#
# dnsmasq를 53 포트로 띄우고 /etc/resolver를 쓰려면 root 권한이 필요하다:
#   sudo ./setup-dns.sh
#
# dnsmasq.conf 에 (이미 .preview.localhost 처럼) address= 라인을 직접 추가하는 방식.
# (이 머신의 dnsmasq.conf 는 conf-dir 이 주석 처리돼 있어 dnsmasq.d 가 로드되지 않으므로)
set -euo pipefail
cd "$(dirname "$0")"

DNSMASQ_CONF=/opt/homebrew/etc/dnsmasq.conf

echo "[1/3] dnsmasq.conf 에 와일드카드 address 라인 추가 (중복 방지)"
# dnsmasq-localhost-me.conf 의 'address=' 라인만 골라 없으면 추가
grep -E '^address=' dnsmasq-localhost-me.conf | while read -r line; do
  grep -qxF "$line" "$DNSMASQ_CONF" || echo "$line" >> "$DNSMASQ_CONF"
done

echo "[2/3] /etc/resolver/localhost.me 생성 (*.localhost.me -> 127.0.0.1 dnsmasq)"
mkdir -p /etc/resolver
printf 'nameserver 127.0.0.1\n' > /etc/resolver/localhost.me

echo "[3/3] dnsmasq (재)시작"
brew services restart dnsmasq

echo
echo "=== 검증 ==="
sleep 1
echo -n "abc123.gitlab.localhost.me -> "; dig +short @127.0.0.1 abc123.gitlab.localhost.me
echo -n "foo.test.localhost.me      -> "; dig +short @127.0.0.1 foo.test.localhost.me
echo "둘 다 127.0.0.1 이면 정상. 시스템 해석: dscacheutil -q host -a name x.gitlab.localhost.me"
