# GitLab Web IDE Extension Host Domain — 로컬 테스트 환경

kind + Helm으로 GitLab을 로컬에 설치하고, Web IDE의 **extension host domain**(VS Code 정적 자산을
본 도메인과 분리된 와일드카드 origin에서 서빙)을 구성·검증하는 환경이다.

외부 CDN(`*.cdn.web-ide.gitlab-static.net`) 대신, 같은 GitLab 인스턴스(Workhorse)를 가리키는
와일드카드 도메인 `*.webide.localtest.me`로 `/assets`를 서빙한다.

## 구성 요소

| 항목 | 값 |
|------|-----|
| k8s | kind 클러스터 `gitlab-webide` (host 80/443 → ingress) |
| Ingress | ingress-nginx (kind variant, class `nginx`) |
| GitLab | Helm chart `gitlab/gitlab` 9.11.7 (GitLab v18.11.6, CE) |
| 메인 도메인 | https://gitlab.localtest.me |
| Extension host | `*.webide.localtest.me` → `gitlab-webservice-default:8181` (Workhorse) |
| TLS | 와일드카드 인증서 → secret `gitlab-wildcard-tls` (mkcert 또는 [openssl + 사설 rootCA](#tls-구성--openssl-방식-mkcert-대안)) |
| DNS | `localtest.me` (모든 서브도메인 → 127.0.0.1, /etc/hosts 불필요) |

`localtest.me`를 쓰는 이유: `*.localtest.me`와 다중 레벨 서브도메인이 모두 127.0.0.1로 해석되어
와일드카드 + kind hostPort 조합에서 별도 DNS 설정 없이 동작한다.

## 파일

- `kind-cluster.yaml` — kind 클러스터(포트 매핑) 정의
- `gitlab-values.yaml` — GitLab Helm 최소 로컬 values (runner/prometheus/registry/kas off)
- `webide-extension-host-ingress.yaml` — extension host 와일드카드 ingress (수동 구성, 릴리스에 추가)
- `tls.crt` / `tls.key` — 와일드카드 인증서 (mkcert, 또는 사설 rootCA로 서명한 openssl 인증서)
- `rootCA.pem` / `rootCA-key.pem` — 사설 root CA(공개 인증서 / 개인키). openssl 방식에서 사용

## 처음부터 재현

```bash
cd webide-test

# 1) 클러스터
kind create cluster --config kind-cluster.yaml --wait 120s

# 2) ingress-nginx
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait -n ingress-nginx --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=180s

# 3) TLS (와일드카드)
mkcert -install   # 브라우저 신뢰: sudo 비밀번호 필요 (1회)
mkcert -cert-file tls.crt -key-file tls.key \
  gitlab.localtest.me "*.localtest.me" "*.webide.localtest.me" localtest.me
kubectl create namespace gitlab
kubectl -n gitlab create secret tls gitlab-wildcard-tls --cert=tls.crt --key=tls.key

# 4) GitLab
helm repo add gitlab https://charts.gitlab.io/ && helm repo update gitlab
helm upgrade --install gitlab gitlab/gitlab -n gitlab \
  --version 9.11.7 -f gitlab-values.yaml --timeout 1200s --wait

# 5) extension host ingress (수동 구성 부분)
kubectl apply -f webide-extension-host-ingress.yaml

# 6) GitLab 관리자 설정 — extension host domain 지정 + single-origin fallback off
POD=$(kubectl -n gitlab get pod -l app=toolbox -o jsonpath='{.items[0].metadata.name}')
kubectl -n gitlab exec "$POD" -- gitlab-rails runner '
  s = ApplicationSetting.current
  s.vscode_extension_marketplace_extension_host_domain = "webide.localtest.me"
  v = s.vscode_extension_marketplace; v["single_origin_fallback_enabled"] = false
  s.vscode_extension_marketplace = v; s.save!'
```

UI로도 가능: **Admin → Settings → General → Web IDE → Extension host domain** = `webide.localtest.me`.

## TLS 구성 — openssl 방식 (mkcert 대안)

위 3) 단계의 `mkcert`를 쓰지 않고, **미리 만들어 둔 사설 root CA로 직접 서명한** 와일드카드
인증서를 쓰는 방법이다. mkcert도 내부적으로는 "로컬 root CA를 만들고 그 CA로 leaf 인증서를
서명"하는 동작을 자동화한 것뿐이라, openssl로 같은 일을 수동으로 하면 된다.

> **전제**: 사설 root CA(`rootCA.pem` / `rootCA-key.pem`)를 이미 생성해 두었고,
> 그 CA로 `*.test.localhost.me`에 대한 와일드카드 인증서(`tls.crt` / `tls.key`)를
> **이미 발급해 둔 상태**라고 가정한다. 이 경우 남는 일은 **(A) root CA 신뢰 등록**과
> **(B) 시크릿 생성** 두 가지뿐이다.

### A. root CA를 시스템/브라우저에 신뢰 등록 (`mkcert -install` 대체)

mkcert는 `mkcert -install`로 자기 root CA를 신뢰 저장소에 넣는다. 사설 CA는 직접 등록한다.

```bash
# Linux 시스템 신뢰 저장소 (Debian/Ubuntu 계열)
sudo cp rootCA.pem /usr/local/share/ca-certificates/test-localhost-rootCA.crt
sudo update-ca-certificates

# Chrome/Chromium·Firefox 등 NSS DB를 쓰는 브라우저 (libnss3-tools 필요)
certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n "test.localhost.me Local Root CA" -i rootCA.pem

# macOS
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain rootCA.pem
```

> root CA의 **개인키(`rootCA-key.pem`)는 신뢰 저장소에 넣지 않는다.** 등록·배포 대상은
> 공개 인증서(`rootCA.pem`)뿐이다. 개인키는 인증서를 **서명할 때만** 쓰고 외부에 노출하지 않는다.

### B. 이미 발급된 인증서로 시크릿 생성 (mkcert 절과 동일)

인증서 파일명만 같으면(`tls.crt` / `tls.key`) 이후 단계는 mkcert 방식과 100% 동일하다.

```bash
kubectl create namespace gitlab
kubectl -n gitlab create secret tls gitlab-wildcard-tls --cert=tls.crt --key=tls.key
```

`gitlab-values.yaml`의 `secretName`과 `webide-extension-host-ingress.yaml`의 `secretName`이
모두 `gitlab-wildcard-tls`를 가리키므로, 시크릿만 같은 이름으로 만들면 차트/ingress 수정은 필요 없다.

### (참고) `*.test.localhost.me` 인증서를 openssl로 직접 발급하는 전체 과정

위 "전제"의 인증서를 처음부터 다시 만들어야 할 때 사용한다. mkcert 명령
(`mkcert -cert-file tls.crt -key-file tls.key gitlab.localtest.me "*.localtest.me" ...`)
한 줄이 아래 0)~5) 단계에 대응한다.

```bash
# 0) 사설 root CA (이미 있다면 건너뜀) — 한 번만 만들고 재사용
openssl genrsa -out rootCA-key.pem 4096
openssl req -x509 -new -nodes -key rootCA-key.pem -sha256 -days 3650 \
  -subj "/CN=test.localhost.me Local Root CA" -out rootCA.pem

# 1) leaf(서버) 개인키
openssl genrsa -out tls.key 2048

# 2) SAN 설정 — openssl은 와일드카드/멀티 도메인을 SAN 확장으로 줘야 한다.
#    *.test.localhost.me 는 한 레벨만 매칭하므로 webide 한 단계 더는 따로 적는다
#    (mkcert 에서 "*.webide.localtest.me" 를 별도로 적은 것과 같은 이유).
cat > tls.ext <<'EOF'
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt
[alt]
DNS.1 = test.localhost.me
DNS.2 = *.test.localhost.me
DNS.3 = gitlab.test.localhost.me
DNS.4 = *.webide.test.localhost.me
EOF

# 3) CSR 생성
openssl req -new -key tls.key -out tls.csr -subj "/CN=gitlab.test.localhost.me"

# 4) root CA로 서명 (-CAcreateserial 로 rootCA.srl 자동 생성)
openssl x509 -req -in tls.csr \
  -CA rootCA.pem -CAkey rootCA-key.pem -CAcreateserial \
  -days 825 -sha256 -extfile tls.ext -out tls.crt

# 5) 검증
openssl verify -CAfile rootCA.pem tls.crt
openssl x509 -in tls.crt -noout -text | grep -A1 "Subject Alternative Name"
```

주의할 점:

- **leaf 인증서 유효기간은 825일 이하**로 둔다(Apple/Chrome 정책). root CA는 더 길게(예 3650일) 둬도 된다.
- SAN에 들어간 호스트만 유효하다. 도메인을 `localtest.me` 대신 `test.localhost.me`로 쓰려면
  `gitlab-values.yaml`(`global.hosts.domain`, `hostname`)과
  `webide-extension-host-ingress.yaml`(`host` / `tls.hosts`)의 도메인도 같은 값으로 맞춰야 한다.
- `*.test.localhost.me`가 127.0.0.1로 해석돼야 한다. `localtest.me`처럼 자동 해석되지 않는다면
  `/etc/hosts`에 사용할 호스트를 직접 등록하거나 와일드카드 DNS(dnsmasq 등)를 둔다.

## 접속

- URL: https://gitlab.localtest.me  (사용자 `root`)
- 초기 root 비밀번호:
  ```bash
  kubectl -n gitlab get secret gitlab-gitlab-initial-root-password \
    -o jsonpath='{.data.password}' | base64 -d; echo
  ```

## 검증

실존 자산이 메인/extension-host 양쪽에서 동일하게 서빙되는지 비교:

```bash
ASSET=$(curl -ksS https://gitlab.localtest.me/users/sign_in \
  | grep -oE '/assets/[A-Za-z0-9._/-]+\.css' | head -1)
curl -ksS -o /dev/null -w "%{http_code} %{size_download}\n" "https://gitlab.localtest.me$ASSET"
curl -ksS -o /dev/null -w "%{http_code} %{size_download}\n" "https://abc123.webide.localtest.me$ASSET"
```

두 응답의 HTTP 200 + 동일 size면 라우팅 정상.

## 정리(cleanup)

```bash
kind delete cluster --name gitlab-webide

# 로컬 CA 신뢰 제거(선택)
mkcert -uninstall                                              # mkcert 방식
# openssl 방식이면 신뢰 저장소에서 직접 제거:
sudo rm /usr/local/share/ca-certificates/test-localhost-rootCA.crt && sudo update-ca-certificates --fresh
certutil -d sql:$HOME/.pki/nssdb -D -n "test.localhost.me Local Root CA"   # NSS DB(브라우저)
```
