#!/usr/bin/env bash
# ============================================================
# GitLab Workspaces - 설치 검증 스크립트
# ============================================================
# 모든 컴포넌트가 정상적으로 설치 및 동작하는지 확인합니다.
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

PASS=0
FAIL=0
WARN=0

check_pass() { log_success "  ✔ $*"; ((PASS++)); }
check_fail() { log_fail    "  ✖ $*"; ((FAIL++)); }
check_warn() { log_warn    "  ⚠ $*"; ((WARN++)); }

# ============================================================
log_header "GitLab Workspaces 설치 검증"
# ============================================================

# ============================================================
log_step "1. cert-manager 컴포넌트 확인"
# ============================================================

log_info "cert-manager 파드 상태:"
kubectl get pods -n cert-manager -o wide 2>/dev/null || true

for deploy in cert-manager cert-manager-webhook cert-manager-cainjector; do
    READY=$(kubectl get deployment "${deploy}" -n cert-manager \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    DESIRED=$(kubectl get deployment "${deploy}" -n cert-manager \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    if [[ "${READY}" == "${DESIRED}" && "${READY}" != "0" ]]; then
        check_pass "cert-manager/${deploy}: ${READY}/${DESIRED} 파드 Ready"
    else
        check_fail "cert-manager/${deploy}: ${READY:-0}/${DESIRED} 파드 Ready"
    fi
done

log_info "ClusterIssuer 상태:"
kubectl get clusterissuer -o wide 2>/dev/null || true

ISSUER_READY=$(kubectl get clusterissuer "${CERT_ISSUER_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [[ "${ISSUER_READY}" == "True" ]]; then
    check_pass "ClusterIssuer '${CERT_ISSUER_NAME}' Ready"
else
    check_warn "ClusterIssuer '${CERT_ISSUER_NAME}' 상태: ${ISSUER_READY:-알 수 없음}"
fi

# ============================================================
log_step "2. ingress-nginx 확인"
# ============================================================

INGRESS_NS="ingress-nginx"
log_info "ingress-nginx 파드 상태:"
kubectl get pods -n "${INGRESS_NS}" -o wide 2>/dev/null || true

INGRESS_READY=$(kubectl get deployment ingress-nginx-controller -n "${INGRESS_NS}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "${INGRESS_READY}" -gt 0 ]]; then
    check_pass "ingress-nginx-controller: ${INGRESS_READY} 파드 Ready"
else
    check_fail "ingress-nginx-controller: Ready 파드 없음"
fi

INGRESS_LB_IP=$(kubectl get svc ingress-nginx-controller -n "${INGRESS_NS}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
INGRESS_LB_HOST=$(kubectl get svc ingress-nginx-controller -n "${INGRESS_NS}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

if [[ -n "${INGRESS_LB_IP}" ]]; then
    check_pass "ingress-nginx LoadBalancer IP: ${INGRESS_LB_IP}"
elif [[ -n "${INGRESS_LB_HOST}" ]]; then
    check_pass "ingress-nginx LoadBalancer Hostname: ${INGRESS_LB_HOST}"
else
    check_warn "ingress-nginx LoadBalancer IP/Hostname 미할당"
fi

# ============================================================
log_step "3. GitLab Agent 확인"
# ============================================================

AGENT_NS="${GITLAB_AGENT_NAMESPACE}"
log_info "GitLab Agent 파드 상태:"
kubectl get pods -n "${AGENT_NS}" -o wide 2>/dev/null || true

AGENT_READY=$(kubectl get deployment gitlab-agent -n "${AGENT_NS}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "${AGENT_READY}" -gt 0 ]]; then
    check_pass "gitlab-agent: ${AGENT_READY} 파드 Ready"
else
    check_fail "gitlab-agent: Ready 파드 없음"
fi

log_info "GitLab Agent 최근 로그 (에러/경고):"
kubectl logs -n "${AGENT_NS}" -l app=gitlab-agent --tail=50 2>/dev/null | \
    grep -iE "error|warn|connected|disconnected" || echo "  (관련 로그 없음)"

# GitLab API에서 에이전트 연결 상태 확인
log_info "GitLab에서 에이전트 연결 상태 확인..."
PROJECT_ENCODED=$(echo "${GITLAB_PROJECT_PATH}" | sed 's/\//%2F/g')
PROJECT_ID=$(curl -s \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ENCODED}" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" | jq -r '.id' 2>/dev/null || echo "")

if [[ -n "${PROJECT_ID}" && "${PROJECT_ID}" != "null" ]]; then
    AGENT_ID=$(curl -s \
        "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/cluster_agents" \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" | \
        jq -r ".[] | select(.name == \"${GITLAB_AGENT_NAME}\") | .id" 2>/dev/null || echo "")

    if [[ -n "${AGENT_ID}" ]]; then
        AGENT_INFO=$(curl -s \
            "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/cluster_agents/${AGENT_ID}" \
            -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")
        CONNECTED=$(echo "${AGENT_INFO}" | jq -r '.connected // false' 2>/dev/null || echo "false")
        if [[ "${CONNECTED}" == "true" ]]; then
            check_pass "GitLab Agent '${GITLAB_AGENT_NAME}' GitLab에 연결됨"
        else
            check_warn "GitLab Agent '${GITLAB_AGENT_NAME}' 연결 상태 확인 필요 (connected: ${CONNECTED})"
        fi
    else
        check_warn "GitLab에서 에이전트 '${GITLAB_AGENT_NAME}'를 찾을 수 없음"
    fi
fi

# ============================================================
log_step "4. Workspaces Proxy 확인"
# ============================================================

PROXY_NS="${WORKSPACES_PROXY_NAMESPACE}"
log_info "Workspaces Proxy 파드 상태:"
kubectl get pods -n "${PROXY_NS}" -o wide 2>/dev/null || true

PROXY_READY=$(kubectl get deployment gitlab-workspaces-proxy -n "${PROXY_NS}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "${PROXY_READY}" -gt 0 ]]; then
    check_pass "gitlab-workspaces-proxy: ${PROXY_READY} 파드 Ready"
else
    check_fail "gitlab-workspaces-proxy: Ready 파드 없음"
fi

log_info "Workspaces Proxy Ingress:"
kubectl get ingress -n "${PROXY_NS}" -o wide 2>/dev/null || true

log_info "Workspaces Proxy TLS 인증서:"
kubectl get certificate -n "${PROXY_NS}" 2>/dev/null || true

CERT_READY=$(kubectl get certificate -n "${PROXY_NS}" \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [[ "${CERT_READY}" == "True" ]]; then
    check_pass "TLS 인증서 발급 완료"
elif [[ -z "${CERT_READY}" ]]; then
    check_warn "TLS 인증서 미발급 (cert-manager Certificate 리소스 없음)"
else
    check_warn "TLS 인증서 발급 대기 중 (상태: ${CERT_READY})"
fi

log_info "Workspaces Proxy 최근 로그:"
kubectl logs -n "${PROXY_NS}" deployment/gitlab-workspaces-proxy --tail=30 2>/dev/null || true

# ============================================================
log_step "5. 엔드포인트 연결 테스트"
# ============================================================

log_info "Workspaces Proxy 도메인 연결 테스트..."
PROXY_URL="https://${WORKSPACES_DOMAIN}"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 10 \
    --max-time 15 \
    -k "${PROXY_URL}" 2>/dev/null || echo "000")

if [[ "${HTTP_STATUS}" =~ ^[23] ]]; then
    check_pass "Workspaces Proxy 응답: HTTP ${HTTP_STATUS}"
elif [[ "${HTTP_STATUS}" == "401" || "${HTTP_STATUS}" == "302" ]]; then
    check_pass "Workspaces Proxy 응답: HTTP ${HTTP_STATUS} (인증 리디렉션 - 정상)"
elif [[ "${HTTP_STATUS}" == "000" ]]; then
    check_warn "Workspaces Proxy 연결 불가 (DNS 또는 네트워크 설정 확인 필요)"
else
    check_warn "Workspaces Proxy 응답: HTTP ${HTTP_STATUS}"
fi

# GitLab Workspaces API 확인
log_info "GitLab Workspaces API 확인..."
WS_API_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 10 \
    "${GITLAB_URL}/-/remote_development/workspaces" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null || echo "000")
log_info "Workspaces API 응답 코드: ${WS_API_STATUS}"

# ============================================================
log_step "6. 전체 인프라 요약"
# ============================================================

echo ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "설치된 컴포넌트 목록"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_info "[Helm Releases]"
helm list -A --output table 2>/dev/null || true
echo ""

log_info "[전체 네임스페이스 파드 상태]"
for ns in cert-manager ingress-nginx "${GITLAB_AGENT_NAMESPACE}" "${WORKSPACES_PROXY_NAMESPACE}"; do
    echo ""
    echo -e "${CYAN}Namespace: ${ns}${NC}"
    kubectl get pods -n "${ns}" --no-headers 2>/dev/null | \
        awk '{printf "  %-50s %-15s %-10s\n", $1, $3, $5}' || echo "  (네임스페이스 없음)"
done

echo ""
# ============================================================
log_step "검증 결과 요약"
# ============================================================
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  PASS: ${PASS}${NC}  |  ${YELLOW}${BOLD}WARN: ${WARN}${NC}  |  ${RED}${BOLD}FAIL: ${FAIL}${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [[ "${FAIL}" -gt 0 ]]; then
    log_error "검증 실패 ${FAIL}개 - 위의 FAIL 항목을 확인하고 해결하세요."
    exit 1
elif [[ "${WARN}" -gt 0 ]]; then
    log_warn "경고 ${WARN}개 - 경고 항목을 검토하세요."
    echo ""
    log_info "GitLab Workspaces 사용 방법:"
    log_info "  1. GitLab 프로젝트에서 '.devfile.yaml' 파일 생성"
    log_info "  2. ${GITLAB_URL}/-/remote_development/workspaces/new 접속"
    log_info "  3. 에이전트와 프로젝트 선택 후 Workspace 생성"
else
    log_success "모든 검증 통과! GitLab Workspaces 사용 준비 완료"
    echo ""
    log_info "GitLab Workspaces 사용 방법:"
    log_info "  1. GitLab 프로젝트에서 '.devfile.yaml' 파일 생성"
    log_info "  2. ${GITLAB_URL}/-/remote_development/workspaces/new 접속"
    log_info "  3. 에이전트와 프로젝트 선택 후 Workspace 생성"
fi
