#!/usr/bin/env bash
# ============================================================
# GitLab Workspaces - Workspaces Proxy 설치 스크립트
# ============================================================
# 수행 작업:
#   1. GitLab OAuth Application 생성
#   2. Workspaces Proxy Helm Values 생성
#   3. Helm으로 Workspaces Proxy 설치
#   4. Ingress 및 TLS 설정 확인
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

source "${SCRIPT_DIR}/lib/logging.sh"
setup_logging

ENV_FILE="${ROOT_DIR}/.env"
if [[ ! -f "${ENV_FILE}" ]]; then
    log_error ".env 파일이 없습니다."
    exit 1
fi
source "${ENV_FILE}"

CONFIG_DIR="${ROOT_DIR}/config"
PROXY_NS="${WORKSPACES_PROXY_NAMESPACE}"
WORKSPACES_PROXY_CHART_VERSION="${WORKSPACES_PROXY_CHART_VERSION:-0.1.18}"

# ============================================================
log_header "GitLab Workspaces Proxy 설치"
# ============================================================

# ============================================================
log_step "1. GitLab OAuth Application 생성"
# ============================================================

# Workspace Proxy의 콜백 URL
OAUTH_CALLBACK_URL="https://auth.${WORKSPACES_DOMAIN}/oauth/callback"
OAUTH_APP_NAME="GitLab Workspaces Proxy"

log_info "기존 OAuth Application 확인..."
EXISTING_APPS=$(curl -s \
    "${GITLAB_URL}/api/v4/applications" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null || echo "[]")

EXISTING_APP_ID=$(echo "${EXISTING_APPS}" | \
    jq -r ".[] | select(.application_name == \"${OAUTH_APP_NAME}\") | .id" 2>/dev/null || echo "")

if [[ -n "${EXISTING_APP_ID}" && "${EXISTING_APP_ID}" != "null" ]]; then
    log_warn "OAuth Application '${OAUTH_APP_NAME}' 이미 존재 (ID: ${EXISTING_APP_ID})"
    log_warn "기존 Application을 삭제하고 재생성합니다..."

    DELETE_RESPONSE=$(curl -s -X DELETE \
        "${GITLAB_URL}/api/v4/applications/${EXISTING_APP_ID}" \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")
    log_info "기존 Application 삭제 완료"
fi

log_info "새 OAuth Application 생성..."
log_info "  - 이름: ${OAUTH_APP_NAME}"
log_info "  - 콜백 URL: ${OAUTH_CALLBACK_URL}"

OAUTH_RESPONSE=$(curl -s -X POST \
    "${GITLAB_URL}/api/v4/applications" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
        \"name\": \"${OAUTH_APP_NAME}\",
        \"redirect_uri\": \"${OAUTH_CALLBACK_URL}\",
        \"scopes\": \"openid profile email api read_user\",
        \"confidential\": true
    }")

OAUTH_APP_ID=$(echo "${OAUTH_RESPONSE}" | jq -r '.application_id' 2>/dev/null || echo "")
OAUTH_CLIENT_ID=$(echo "${OAUTH_RESPONSE}" | jq -r '.application_id' 2>/dev/null || echo "")
OAUTH_CLIENT_SECRET=$(echo "${OAUTH_RESPONSE}" | jq -r '.secret' 2>/dev/null || echo "")

if [[ -z "${OAUTH_CLIENT_ID}" || "${OAUTH_CLIENT_ID}" == "null" || \
      -z "${OAUTH_CLIENT_SECRET}" || "${OAUTH_CLIENT_SECRET}" == "null" ]]; then
    log_error "OAuth Application 생성 실패:"
    echo "${OAUTH_RESPONSE}" | jq '.'
    log_warn "수동으로 GitLab에서 OAuth Application을 생성하세요:"
    log_warn "  ${GITLAB_URL}/admin/applications/new"
    log_warn "  - Name: ${OAUTH_APP_NAME}"
    log_warn "  - Callback URL: ${OAUTH_CALLBACK_URL}"
    log_warn "  - Scopes: openid, profile, email, api, read_user"
    echo ""
    read -r -p "Client ID를 입력하세요: " OAUTH_CLIENT_ID
    read -r -s -p "Client Secret을 입력하세요: " OAUTH_CLIENT_SECRET
    echo ""
fi

log_success "OAuth Application 생성 완료"
log_info "  Client ID: ${OAUTH_CLIENT_ID}"
log_info "  Client Secret: [보안상 표시하지 않음]"

# 시크릿 키 생성
log_info "보안 키 생성 (signing_key, encryption_key)..."
SIGNING_KEY=$(openssl rand -hex 32)
ENCRYPTION_KEY=$(openssl rand -hex 32)
log_success "보안 키 생성 완료"

# ============================================================
log_step "2. Workspaces 네임스페이스 생성"
# ============================================================

log_info "Workspaces Proxy 네임스페이스 '${PROXY_NS}' 생성..."
kubectl create namespace "${PROXY_NS}" --dry-run=client -o yaml | kubectl apply -f -
log_success "네임스페이스 '${PROXY_NS}' 준비 완료"

log_info "OAuth 자격증명을 Kubernetes Secret으로 저장..."
kubectl create secret generic gitlab-workspaces-proxy-oauth2 \
    --namespace="${PROXY_NS}" \
    --from-literal=client_id="${OAUTH_CLIENT_ID}" \
    --from-literal=client_secret="${OAUTH_CLIENT_SECRET}" \
    --from-literal=signing_key="${SIGNING_KEY}" \
    --from-literal=encryption_key="${ENCRYPTION_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f -
log_success "OAuth Secret 생성 완료"

# ============================================================
log_step "3. Workspaces Proxy Helm Values 파일 생성"
# ============================================================

PROXY_VALUES_TEMPLATE="${CONFIG_DIR}/workspaces-proxy-values.yaml"
PROXY_VALUES_RENDERED="/tmp/workspaces-proxy-values-rendered.yaml"

log_info "Helm Values 파일 렌더링..."
sed \
    -e "s|__OAUTH_CLIENT_ID__|${OAUTH_CLIENT_ID}|g" \
    -e "s|__OAUTH_CLIENT_SECRET__|${OAUTH_CLIENT_SECRET}|g" \
    -e "s|__SIGNING_KEY__|${SIGNING_KEY}|g" \
    -e "s|__ENCRYPTION_KEY__|${ENCRYPTION_KEY}|g" \
    -e "s|https://gitlab.example.com|${GITLAB_URL}|g" \
    -e "s|workspaces.example.com|${WORKSPACES_DOMAIN}|g" \
    -e "s|letsencrypt-prod|${CERT_ISSUER_NAME}|g" \
    -e "s|className: \"nginx\"|className: \"${INGRESS_CLASS:-nginx}\"|g" \
    "${PROXY_VALUES_TEMPLATE}" > "${PROXY_VALUES_RENDERED}"

log_info "렌더링된 Values 파일 (민감 정보 제외):"
divider
grep -v "client_secret\|signing_key\|encryption_key\|client_id" "${PROXY_VALUES_RENDERED}" || true
divider

# ============================================================
log_step "4. GitLab Workspaces Proxy Helm 설치"
# ============================================================

log_info "Workspaces Proxy 설치 정보:"
log_info "  - Chart 버전: ${WORKSPACES_PROXY_CHART_VERSION}"
log_info "  - Namespace: ${PROXY_NS}"
log_info "  - 도메인: ${WORKSPACES_DOMAIN}"

if helm list -n "${PROXY_NS}" 2>/dev/null | grep -q "gitlab-workspaces-proxy"; then
    log_info "기존 Workspaces Proxy Helm 릴리즈 발견 - 업그레이드 진행..."
    HELM_ACTION="upgrade"
else
    log_info "신규 Workspaces Proxy Helm 설치 진행..."
    HELM_ACTION="install"
fi

helm "${HELM_ACTION}" gitlab-workspaces-proxy \
    gitlab/gitlab-workspaces-proxy \
    --namespace "${PROXY_NS}" \
    --version "${WORKSPACES_PROXY_CHART_VERSION}" \
    --values "${PROXY_VALUES_RENDERED}" \
    --wait \
    --timeout 5m \
    --debug 2>&1 | grep -E "STATUS|NOTES|deployed|error|Warning|NAME:|LAST DEPLOYED" || true

log_info "Workspaces Proxy 파드 상태 확인..."
kubectl rollout status deployment/gitlab-workspaces-proxy -n "${PROXY_NS}" --timeout=3m 2>/dev/null || \
    kubectl get pods -n "${PROXY_NS}" 2>/dev/null || true

echo ""
log_info "설치된 파드 상태:"
kubectl get pods -n "${PROXY_NS}" -o wide
echo ""

# ============================================================
log_step "5. Ingress 및 TLS 인증서 확인"
# ============================================================

log_info "Ingress 리소스 확인..."
kubectl get ingress -n "${PROXY_NS}" -o wide 2>/dev/null || true

log_info "TLS 인증서(Secret) 확인..."
kubectl get secret -n "${PROXY_NS}" | grep -E "tls|cert" || true

log_info "Certificate 리소스 확인 (cert-manager)..."
kubectl get certificate -n "${PROXY_NS}" 2>/dev/null || true

log_info "Certificate 상태 대기 (최대 120초)..."
for i in $(seq 1 12); do
    CERT_READY=$(kubectl get certificate -n "${PROXY_NS}" \
        -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [[ "${CERT_READY}" == "True" ]]; then
        log_success "TLS 인증서 발급 완료!"
        break
    else
        log_info "  인증서 발급 대기 중... (${i}/12)"
        kubectl describe certificate -n "${PROXY_NS}" 2>/dev/null | grep -E "Status|Message|Reason" | tail -5 || true
        sleep 10
    fi
done

# ============================================================
log_step "6. Workspaces Proxy 서비스 확인"
# ============================================================

log_info "서비스 상태 확인..."
kubectl get svc -n "${PROXY_NS}" -o wide

log_info "Workspaces Proxy 로그 (최근 30줄):"
divider
kubectl logs -n "${PROXY_NS}" -l app=gitlab-workspaces-proxy --tail=30 2>/dev/null || \
    kubectl logs -n "${PROXY_NS}" deployment/gitlab-workspaces-proxy --tail=30 2>/dev/null || true
divider

# ============================================================
log_step "완료"
# ============================================================
log_success "GitLab Workspaces Proxy 설치 완료!"
echo ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Workspaces 접속 URL:"
log_info "  https://${WORKSPACES_DOMAIN}"
log_info ""
log_info "DNS 설정 확인:"
log_info "  Ingress LoadBalancer IP를 다음 DNS에 연결하세요:"
INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "[LoadBalancer IP]")
log_info "  *.${WORKSPACES_DOMAIN} → ${INGRESS_IP}"
log_info "  ${WORKSPACES_DOMAIN}   → ${INGRESS_IP}"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log_info "다음 단계: bash ${SCRIPT_DIR}/04-configure-gitlab-workspaces.sh"
