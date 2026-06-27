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
| TLS | mkcert 와일드카드 인증서 → secret `gitlab-wildcard-tls` |
| DNS | `localtest.me` (모든 서브도메인 → 127.0.0.1, /etc/hosts 불필요) |

`localtest.me`를 쓰는 이유: `*.localtest.me`와 다중 레벨 서브도메인이 모두 127.0.0.1로 해석되어
와일드카드 + kind hostPort 조합에서 별도 DNS 설정 없이 동작한다.

## 파일

- `kind-cluster.yaml` — kind 클러스터(포트 매핑) 정의
- `gitlab-values.yaml` — GitLab Helm 최소 로컬 values (runner/prometheus/registry/kas off)
- `webide-extension-host-ingress.yaml` — extension host 와일드카드 ingress (수동 구성, 릴리스에 추가)
- `tls.crt` / `tls.key` — mkcert 와일드카드 인증서

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
mkcert -uninstall   # 로컬 CA 신뢰 제거(선택)
```
