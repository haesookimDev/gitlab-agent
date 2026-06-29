#!/usr/bin/env bash
# openssl 기반 사설 TLS 발급 스크립트 (mkcert 대체)
#
# 시나리오:
#   1) 50년짜리 사설 rootCA 생성
#   2) 그 CA로 *.test.localhost.me 발급  (이미 구성돼 있다고 "가정"하는 기존 와일드카드)
#   3) 그 CA로 *.gitlab.localhost.me 발급 (Web IDE extension host domain 용 신규 와일드카드)
#
# 같은 rootCA로 서명하므로, rootCA 하나만 신뢰시키면 두 와일드카드 모두 신뢰된다.
set -euo pipefail
cd "$(dirname "$0")"

OPENSSL="${OPENSSL:-openssl}"          # brew openssl 3.x 권장
CA_DAYS="${CA_DAYS:-18250}"            # 50년
LEAF_DAYS="${LEAF_DAYS:-3650}"         # 10년 (사설 root는 브라우저 수명제한 미적용. 거부 시 825로)
CA_KEY=rootCA.key
CA_CRT=rootCA.crt
CA_SUBJ="/C=KR/O=Local Dev/OU=WebIDE Test/CN=Local Dev Root CA (50yr)"

# 1) rootCA (한 번만 생성, 이미 있으면 재사용 = "이미 등록된 CA" 가정)
if [[ -f "$CA_KEY" && -f "$CA_CRT" ]]; then
  echo "[CA] 기존 rootCA 재사용: $CA_CRT"
else
  echo "[CA] 50년 rootCA 생성"
  "$OPENSSL" genrsa -out "$CA_KEY" 4096
  "$OPENSSL" req -x509 -new -nodes -key "$CA_KEY" -sha256 -days "$CA_DAYS" \
    -subj "$CA_SUBJ" -out "$CA_CRT" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash"
fi

# 2) 와일드카드 leaf 발급 함수
#    issue_leaf <base-domain>  ->  <base>.key / <base>.crt / <base>.fullchain.crt
issue_leaf() {
  local domain="$1" name
  name="$(echo "$domain" | tr '.*' '__')"   # 파일명 안전화
  echo "[LEAF] 발급: *.$domain  (+ $domain)"

  "$OPENSSL" genrsa -out "${name}.key" 2048
  "$OPENSSL" req -new -key "${name}.key" \
    -subj "/C=KR/O=Local Dev/CN=*.${domain}" -out "${name}.csr"

  cat > "${name}.ext" <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:*.${domain},DNS:${domain}
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF

  "$OPENSSL" x509 -req -in "${name}.csr" \
    -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
    -days "$LEAF_DAYS" -sha256 -extfile "${name}.ext" -out "${name}.crt"

  # ingress/nginx 용 풀체인 (leaf + CA)
  cat "${name}.crt" "$CA_CRT" > "${name}.fullchain.crt"
  rm -f "${name}.csr" "${name}.ext"
}

# 2-a) 기존 와일드카드 (가정): *.test.localhost.me
issue_leaf "test.localhost.me"
# 2-b) 신규 와일드카드: *.gitlab.localhost.me  (Web IDE extension host)
issue_leaf "gitlab.localhost.me"

echo
echo "=== 생성 결과 ==="
ls -1 *.crt *.key
echo
echo "rootCA 신뢰 등록(브라우저/시스템):"
echo "  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $CA_CRT"
