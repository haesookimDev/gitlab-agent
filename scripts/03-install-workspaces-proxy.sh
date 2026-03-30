#!/usr/bin/env bash
# ============================================================
# GitLab Workspaces - Workspaces Proxy 설치 스크립트
# 대상: GitLab 18.9 / gitlab-workspaces-proxy 0.1.25+
# ============================================================
# 수행 작업:
#   1. GitLab OAuth Application 생성
#      (redirect URI: https://<PROXY_DOMAIN>/auth/callback)
#   2. 보안 키 생성 (signing_key)
#   3. Kubernetes Secret으로 자격증명 저장
#   4. Helm으로 Workspaces Proxy 설치
#   5. TLS 인증서 발급 대기 및 Ingress 확인
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

source "${SCRIPT_DIR}/lib/logging.sh"
setup_logging

ENV_FILE="${ROOT_DIR}/.env"
if [[ ! -f "${ENV_FILE}" ]]; then
    log_error ".env 파일이 없습니다."; exit 1
fi
source "${ENV_FILE}"

PROXY_NS="${WORKSPACES_PROXY_NAMESPACE}"
PROXY_CHART_VER="${WORKSPACES_PROXY_CHART_VERSION:-0.1.25}"

# GitLab 18.9 Workspaces Proxy OAuth 콜백 URL 형식
# (이전: /oauth/callback → 현재: /auth/callback)
OAUTH_REDIRECT_URI="https://${WORKSPACES_PROXY_DOMAIN}/auth/callback"
OAUTH_APP_NAME="GitLab Workspaces Proxy"

# ── 리소스 계산기 실행 ─────────────────────────────────────────
CONCURRENT_USERS="${CONCURRENT_USERS:-100}"
log_info "리소스 계산 기준 동시 사용자 수: ${CONCURRENT_USERS}명"
# 리소스 계산기에서 변수 로드 (setup_logging 덮어쓰기 방지)
_ORIG_LOG="${LOG_FILE}"
source "${SCRIPT_DIR}/resource-calculator.sh" "${CONCURRENT_USERS}" 2>/dev/null || true
LOG_FILE="${_ORIG_LOG}"

# ============================================================
log_header "GitLab Workspaces Proxy 설치 (GitLab 18.9)"
# ============================================================

log_info "설치 파라미터:"
log_info "  Proxy 네임스페이스  : ${PROXY_NS}"
log_info "  Proxy 도메인        : ${WORKSPACES_PROXY_DOMAIN}"
log_info "  Workspaces 도메인   : ${WORKSPACES_DOMAIN}"
log_info "  OAuth Redirect URI  : ${OAUTH_REDIRECT_URI}"
log_info "  차트 버전           : ${PROXY_CHART_VER}"

# ============================================================
log_step "1. GitLab OAuth Application 생성"
# ============================================================

log_info "기존 OAuth Application '${OAUTH_APP_NAME}' 확인..."
APPS_JSON=$(curl -s "${GITLAB_URL}/api/v4/applications" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null || echo "[]")

EXISTING_ID=$(echo "${APPS_JSON}" | \
    jq -r ".[] | select(.application_name == \"${OAUTH_APP_NAME}\") | .id" \
    2>/dev/null || echo "")

if [[ -n "${EXISTING_ID}" && "${EXISTING_ID}" != "null" ]]; then
    log_warn "기존 OAuth Application 발견 (ID: ${EXISTING_ID}) - 삭제 후 재생성..."
    curl -s -X DELETE \
        "${GITLAB_URL}/api/v4/applications/${EXISTING_ID}" \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" > /dev/null
    log_info "기존 Application 삭제 완료"
fi

log_info "OAuth Application 생성..."
log_info "  이름       : ${OAUTH_APP_NAME}"
log_info "  Redirect   : ${OAUTH_REDIRECT_URI}"
log_info "  Scopes     : api read_user openid profile"

OAUTH_RESP=$(curl -s -X POST \
    "${GITLAB_URL}/api/v4/applications" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
        \"name\": \"${OAUTH_APP_NAME}\",
        \"redirect_uri\": \"${OAUTH_REDIRECT_URI}\",
        \"scopes\": \"api read_user openid profile\",
        \"confidential\": true
    }")

OAUTH_CLIENT_ID=$(echo "${OAUTH_RESP}" | jq -r '.application_id' 2>/dev/null || echo "")
OAUTH_CLIENT_SECRET=$(echo "${OAUTH_RESP}" | jq -r '.secret' 2>/dev/null || echo "")

if [[ -z "${OAUTH_CLIENT_ID}" || "${OAUTH_CLIENT_ID}" == "null" || \
      -z "${OAUTH_CLIENT_SECRET}" || "${OAUTH_CLIENT_SECRET}" == "null" ]]; then
    log_error "OAuth Application 생성 실패:"
    echo "${OAUTH_RESP}" | jq '.' 2>/dev/null || echo "${OAUTH_RESP}"
    log_warn ""
    log_warn "수동으로 GitLab Admin에서 OAuth Application을 생성하세요:"
    log_warn "  URL: ${GITLAB_URL}/admin/applications/new"
    log_warn "  - Name: ${OAUTH_APP_NAME}"
    log_warn "  - Redirect URI: ${OAUTH_REDIRECT_URI}"
    log_warn "  - Scopes: api, read_user, openid, profile"
    log_warn "  - Confidential: 체크"
    echo ""
    read -r -p "Client ID를 입력하세요: " OAUTH_CLIENT_ID
    read -r -s -p "Client Secret을 입력하세요: " OAUTH_CLIENT_SECRET
    echo ""
fi

log_success "OAuth Application 생성 완료"
log_info "  Client ID: ${OAUTH_CLIENT_ID}"
log_info "  Client Secret: [보안상 표시 안 함]"

# ============================================================
log_step "2. 보안 서명 키 생성"
# ============================================================

# signing_key: 세션 서명용 32바이트 랜덤 키
SIGNING_KEY=$(openssl rand -hex 32)
log_success "signing_key 생성 완료 (32바이트 hex)"

# ============================================================
log_step "3. 네임스페이스 및 Kubernetes Secret 생성"
# ============================================================

log_info "네임스페이스 '${PROXY_NS}' 생성..."
kubectl create namespace "${PROXY_NS}" --dry-run=client -o yaml | kubectl apply -f -
log_success "네임스페이스 준비 완료"

# GitLab 18.9 Workspaces Proxy는 다음 두 Secret 사용:
# 1. gitlab-workspaces-proxy-config: OAuth 자격증명
# 2. (선택) 추가 TLS Secret

log_info "OAuth 자격증명 Secret 생성: gitlab-workspaces-proxy-config"
kubectl create secret generic gitlab-workspaces-proxy-config \
    --namespace="${PROXY_NS}" \
    --from-literal=client_id="${OAUTH_CLIENT_ID}" \
    --from-literal=client_secret="${OAUTH_CLIENT_SECRET}" \
    --from-literal=signing_key="${SIGNING_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f -
log_success "Secret 'gitlab-workspaces-proxy-config' 생성 완료"

# ============================================================
log_step "4. Helm Values 파일 생성 및 Workspaces Proxy 설치"
# ============================================================

PROXY_VALUES_FILE="/tmp/workspaces-proxy-values.yaml"

cat > "${PROXY_VALUES_FILE}" <<EOF
# GitLab Workspaces Proxy Helm Values
# GitLab 18.9 / 생성일: $(date '+%Y-%m-%d %H:%M:%S')

# ----------------------------------------
# 인증 설정 (Kubernetes Secret 참조)
# ----------------------------------------
auth:
  # GitLab 인스턴스 URL
  host: "${GITLAB_URL}"
  # OAuth Application Client ID
  client_id: "${OAUTH_CLIENT_ID}"
  # OAuth Application Client Secret
  client_secret: "${OAUTH_CLIENT_SECRET}"
  # 세션 서명 키
  signing_key: "${SIGNING_KEY}"
  # OAuth 콜백 URL (GitLab 18.x: /auth/callback)
  redirect_uri: "${OAUTH_REDIRECT_URI}"

# ----------------------------------------
# 도메인 설정
# ----------------------------------------
hosts:
  # Workspaces 와일드카드 도메인
  domain: "${WORKSPACES_DOMAIN}"
  # Proxy 인증 도메인
  # 이 호스트로 OAuth 콜백 처리
  # auth.<domain> 자동 생성됨

# ----------------------------------------
# Ingress 설정
# ----------------------------------------
ingress:
  enabled: true
  className: "${INGRESS_CLASS:-nginx}"
  annotations:
    # WebSocket 및 장시간 연결 지원 (Workspace IDE 사용)
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-buffering: "off"
    nginx.ingress.kubernetes.io/proxy-http-version: "1.1"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection "upgrade";
  tls:
    enabled: true
    secretName: "gitlab-workspaces-proxy-tls"

# ----------------------------------------
# cert-manager TLS 인증서 자동 발급
# ----------------------------------------
certificate:
  create: true
  issuerRef:
    name: "${CERT_ISSUER_NAME}"
    kind: "ClusterIssuer"
    group: "cert-manager.io"

# ----------------------------------------
# 리소스 설정 (동시 사용자 ${CONCURRENT_USERS}명 기준 자동 산정)
# ----------------------------------------
resources:
  requests:
    cpu: "${PROXY_CPU_REQ_M:-200}m"
    memory: "${PROXY_MEM_REQ_MI:-256}Mi"
  limits:
    cpu: "${PROXY_CPU_LIM_M:-500}m"
    memory: "${PROXY_MEM_LIM_MI:-512}Mi"

replicaCount: ${PROXY_REPLICAS:-1}

# ----------------------------------------
# HPA 설정 (동시 사용자 250명 초과 시 자동 활성화)
# ----------------------------------------
$(if [[ ${CONCURRENT_USERS:-100} -gt 250 ]]; then
    PROXY_MAX=$(( ${PROXY_REPLICAS:-2} * 2 ))
    echo "autoscaling:"
    echo "  enabled: true"
    echo "  minReplicas: ${PROXY_REPLICAS:-2}"
    echo "  maxReplicas: ${PROXY_MAX}"
    echo "  targetCPUUtilizationPercentage: 70"
fi)
EOF

log_info "Helm Values 내용 확인 (민감 정보 마스킹):"
divider
grep -v "client_secret\|signing_key\|client_id" "${PROXY_VALUES_FILE}" || true
divider

# Helm 설치 실행
log_info "사용 가능한 Workspaces Proxy 차트 버전 확인..."
helm search repo gitlab-workspaces-proxy --versions --output json 2>/dev/null | \
    jq -r '.[].version' | head -5 || true

if helm list -n "${PROXY_NS}" 2>/dev/null | grep -q "gitlab-workspaces-proxy"; then
    HELM_ACTION="upgrade"
    log_info "기존 릴리즈 발견 → upgrade"
else
    HELM_ACTION="install"
    log_info "신규 설치 → install"
fi

log_info "Workspaces Proxy ${HELM_ACTION} 시작 (차트: ${PROXY_CHART_VER})..."
helm "${HELM_ACTION}" gitlab-workspaces-proxy \
    gitlab-workspaces-proxy/gitlab-workspaces-proxy \
    --namespace "${PROXY_NS}" \
    --version "${PROXY_CHART_VER}" \
    --values "${PROXY_VALUES_FILE}" \
    --wait \
    --timeout 5m \
    2>&1 | grep -E "STATUS|NOTES|deployed|Error|Warning|NAME:|LAST DEPLOYED" || true

log_info "Workspaces Proxy Rollout 확인..."
kubectl rollout status deployment/gitlab-workspaces-proxy \
    -n "${PROXY_NS}" --timeout=3m 2>/dev/null || \
    kubectl get pods -n "${PROXY_NS}" 2>/dev/null || true

echo ""
log_info "파드 상태:"
kubectl get pods -n "${PROXY_NS}" -o wide

# ============================================================
log_step "5. Ingress 및 TLS 인증서 확인"
# ============================================================

echo ""
log_info "Ingress 리소스:"
kubectl get ingress -n "${PROXY_NS}" -o wide 2>/dev/null || true

log_info "Certificate 리소스 (cert-manager):"
kubectl get certificate -n "${PROXY_NS}" 2>/dev/null || true

log_info "TLS 인증서 발급 대기 (최대 120초)..."
for i in $(seq 1 12); do
    CERT_STATUS=$(kubectl get certificate -n "${PROXY_NS}" \
        -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' \
        2>/dev/null || echo "")
    if [[ "${CERT_STATUS}" == "True" ]]; then
        log_success "TLS 인증서 발급 완료!"
        break
    fi
    log_info "  인증서 대기 중... (${i}/12, 상태: ${CERT_STATUS:-Pending})"
    kubectl describe certificate -n "${PROXY_NS}" 2>/dev/null | \
        grep -E "Message:|Reason:|Status:" | tail -3 || true
    sleep 10
done

# ============================================================
log_step "6. Workspaces Proxy 서비스 및 로그 확인"
# ============================================================

echo ""
log_info "서비스 목록:"
kubectl get svc -n "${PROXY_NS}" -o wide

echo ""
log_info "Workspaces Proxy 로그 (최근 30줄):"
divider
kubectl logs -n "${PROXY_NS}" \
    -l app.kubernetes.io/name=gitlab-workspaces-proxy \
    --tail=30 2>/dev/null || \
    kubectl logs -n "${PROXY_NS}" deployment/gitlab-workspaces-proxy \
    --tail=30 2>/dev/null || true
divider

# LoadBalancer IP 정보
LB_IP=$(cat /tmp/lb-external-ip 2>/dev/null || \
    kubectl get svc ingress-nginx-controller -n ingress-nginx \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "[미확인]")

# ============================================================
log_step "완료"
# ============================================================
log_success "GitLab Workspaces Proxy 설치 완료!"
echo ""
divider
log_info "DNS 설정 필요:"
log_info "  *.${WORKSPACES_DOMAIN}     →  ${LB_IP}"
log_info "  ${WORKSPACES_PROXY_DOMAIN} →  ${LB_IP}"
divider
echo ""
log_info "GitLab Workspaces 접속:"
log_info "  ${GITLAB_URL}/-/remote_development/workspaces/new"
echo ""
log_info "  다음: bash ${SCRIPT_DIR}/04-configure-gitlab-workspaces.sh"
