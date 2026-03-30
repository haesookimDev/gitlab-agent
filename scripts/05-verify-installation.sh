#!/usr/bin/env bash
# ============================================================
# GitLab Workspaces - 설치 검증 스크립트
# 대상: GitLab 18.9
# ============================================================
# 검증 항목:
#   1. cert-manager 컴포넌트 정상 동작
#   2. ingress-nginx 정상 동작
#   3. GitLab Agent 파드 상태 및 KAS 연결
#   4. Workspaces Proxy 파드, Ingress, TLS 인증서
#   5. 엔드포인트 HTTP 응답 확인
#   6. GitLab Workspaces API 조회
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

PASS=0; FAIL=0; WARN=0
check_pass() { log_success "  ✔ $*"; ((PASS++)); }
check_fail() { log_fail    "  ✖ $*"; ((FAIL++)); }
check_warn() { log_warn    "  ⚠ $*"; ((WARN++)); }

# ============================================================
log_header "GitLab Workspaces 설치 검증 (GitLab 18.9)"
# ============================================================

# ============================================================
log_step "1. cert-manager 검증"
# ============================================================

log_info "cert-manager 파드 상태:"
kubectl get pods -n cert-manager -o wide 2>/dev/null || true

for deploy in cert-manager cert-manager-webhook cert-manager-cainjector; do
    READY=$(kubectl get deployment "${deploy}" -n cert-manager \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    DESIRED=$(kubectl get deployment "${deploy}" -n cert-manager \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    if [[ "${READY:-0}" -ge "${DESIRED:-1}" && "${READY:-0}" -gt 0 ]]; then
        check_pass "cert-manager ${deploy}: ${READY}/${DESIRED} Ready"
    else
        check_fail "cert-manager ${deploy}: ${READY:-0}/${DESIRED} Ready"
    fi
done

log_info "ClusterIssuer 상태:"
kubectl get clusterissuer -o wide 2>/dev/null || true
ISSUER_READY=$(kubectl get clusterissuer "${CERT_ISSUER_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [[ "${ISSUER_READY}" == "True" ]]; then
    check_pass "ClusterIssuer '${CERT_ISSUER_NAME}': Ready"
else
    check_warn "ClusterIssuer '${CERT_ISSUER_NAME}': ${ISSUER_READY:-알 수 없음}"
fi

# ============================================================
log_step "2. ingress-nginx 검증"
# ============================================================

INGRESS_NS="ingress-nginx"
log_info "ingress-nginx 파드 상태:"
kubectl get pods -n "${INGRESS_NS}" -o wide 2>/dev/null || true

INGRESS_READY=$(kubectl get deployment ingress-nginx-controller -n "${INGRESS_NS}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "${INGRESS_READY:-0}" -gt 0 ]]; then
    check_pass "ingress-nginx-controller: ${INGRESS_READY} 파드 Ready"
else
    check_fail "ingress-nginx-controller: Ready 파드 없음"
fi

LB_IP=$(kubectl get svc ingress-nginx-controller -n "${INGRESS_NS}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
LB_HOST=$(kubectl get svc ingress-nginx-controller -n "${INGRESS_NS}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

if [[ -n "${LB_IP}" ]]; then
    check_pass "LoadBalancer IP: ${LB_IP}"
elif [[ -n "${LB_HOST}" ]]; then
    check_pass "LoadBalancer Hostname: ${LB_HOST}"
    LB_IP="${LB_HOST}"
else
    check_warn "LoadBalancer IP/Hostname 미할당"
fi

# ============================================================
log_step "3. GitLab Agent 검증"
# ============================================================

AGENT_NS="${GITLAB_AGENT_NAMESPACE}"
log_info "GitLab Agent 파드 상태:"
kubectl get pods -n "${AGENT_NS}" -o wide 2>/dev/null || true

AGENT_READY=$(kubectl get deployment gitlab-agent -n "${AGENT_NS}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "${AGENT_READY:-0}" -gt 0 ]]; then
    check_pass "gitlab-agent: ${AGENT_READY} 파드 Ready"
else
    check_fail "gitlab-agent: Ready 파드 없음"
fi

log_info "에이전트 로그 (error/warn 필터링):"
kubectl logs -n "${AGENT_NS}" -l app=gitlab-agent --tail=100 2>/dev/null | \
    grep -iE "error|warn|connect|register" | tail -10 || echo "  (관련 로그 없음)"

# GitLab API로 에이전트 연결 확인
log_info "GitLab에서 에이전트 연결 상태 조회..."
PROJ_ENC=$(echo "${GITLAB_PROJECT_PATH}" | sed 's/\//%2F/g')
PROJ_ID=$(curl -s "${GITLAB_URL}/api/v4/projects/${PROJ_ENC}" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" | jq -r '.id' 2>/dev/null || echo "")

if [[ -n "${PROJ_ID}" && "${PROJ_ID}" != "null" ]]; then
    AGENT_ID=$(curl -s \
        "${GITLAB_URL}/api/v4/projects/${PROJ_ID}/cluster_agents" \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" | \
        jq -r ".[] | select(.name == \"${GITLAB_AGENT_NAME}\") | .id" 2>/dev/null || echo "")

    if [[ -n "${AGENT_ID}" ]]; then
        AGENT_DETAIL=$(curl -s \
            "${GITLAB_URL}/api/v4/projects/${PROJ_ID}/cluster_agents/${AGENT_ID}" \
            -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")
        CONNECTED=$(echo "${AGENT_DETAIL}" | jq -r '.connected // false' 2>/dev/null || echo "false")
        if [[ "${CONNECTED}" == "true" ]]; then
            check_pass "GitLab Agent '${GITLAB_AGENT_NAME}' KAS 연결됨"
        else
            check_warn "GitLab Agent 연결 미확인 (connected: ${CONNECTED}) - 로그 확인 필요"
        fi
    else
        check_warn "GitLab에서 에이전트 '${GITLAB_AGENT_NAME}' 미발견"
    fi
fi

# ============================================================
log_step "4. Workspaces Proxy 검증"
# ============================================================

PROXY_NS="${WORKSPACES_PROXY_NAMESPACE}"
log_info "Workspaces Proxy 파드 상태:"
kubectl get pods -n "${PROXY_NS}" -o wide 2>/dev/null || true

PROXY_READY=$(kubectl get deployment gitlab-workspaces-proxy -n "${PROXY_NS}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "${PROXY_READY:-0}" -gt 0 ]]; then
    check_pass "gitlab-workspaces-proxy: ${PROXY_READY} 파드 Ready"
else
    check_fail "gitlab-workspaces-proxy: Ready 파드 없음"
fi

log_info "Ingress 리소스:"
kubectl get ingress -n "${PROXY_NS}" -o wide 2>/dev/null || true

log_info "TLS Certificate 상태:"
kubectl get certificate -n "${PROXY_NS}" -o wide 2>/dev/null || true

CERT_READY=$(kubectl get certificate -n "${PROXY_NS}" \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' \
    2>/dev/null || echo "")
if [[ "${CERT_READY}" == "True" ]]; then
    # 인증서 만료일 확인
    CERT_EXPIRY=$(kubectl get secret -n "${PROXY_NS}" gitlab-workspaces-proxy-tls \
        -o jsonpath='{.data.tls\.crt}' 2>/dev/null | \
        base64 -d 2>/dev/null | \
        openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || echo "확인 불가")
    check_pass "TLS 인증서 Ready (만료: ${CERT_EXPIRY})"
elif [[ -z "${CERT_READY}" ]]; then
    check_warn "TLS Certificate 리소스 없음 (cert-manager 설정 확인)"
else
    check_warn "TLS 인증서 발급 대기 중 (상태: ${CERT_READY})"
fi

log_info "Workspaces Proxy 로그 (최근 20줄):"
divider
kubectl logs -n "${PROXY_NS}" deployment/gitlab-workspaces-proxy --tail=20 2>/dev/null || true
divider

# ============================================================
log_step "5. 엔드포인트 HTTP 응답 검증"
# ============================================================

log_info "Workspaces Proxy 도메인 응답 확인: https://${WORKSPACES_PROXY_DOMAIN}"
PROXY_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 10 --max-time 15 -k \
    "https://${WORKSPACES_PROXY_DOMAIN}" 2>/dev/null || echo "000")

case "${PROXY_HTTP}" in
    200|204)        check_pass "Workspaces Proxy: HTTP ${PROXY_HTTP}" ;;
    301|302|307|308) check_pass "Workspaces Proxy: HTTP ${PROXY_HTTP} (리디렉션 - 정상)" ;;
    401|403)        check_pass "Workspaces Proxy: HTTP ${PROXY_HTTP} (인증 요구 - 정상)" ;;
    000)            check_warn "Workspaces Proxy 연결 불가 (DNS 또는 TLS 확인 필요)" ;;
    *)              check_warn "Workspaces Proxy: HTTP ${PROXY_HTTP}" ;;
esac

log_info "GitLab Workspaces 페이지 접근 확인..."
GL_WS_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 10 \
    "${GITLAB_URL}/-/remote_development/workspaces" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null || echo "000")
log_info "  GitLab Workspaces 페이지: HTTP ${GL_WS_HTTP}"

# ============================================================
log_step "6. GitLab Workspaces API 검증"
# ============================================================

if [[ -n "${PROJ_ID:-}" ]]; then
    log_info "Workspaces API 조회 (프로젝트 레벨)..."
    WS_API=$(curl -s \
        "${GITLAB_URL}/api/v4/projects/${PROJ_ID}/remote_development/workspaces" \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null || echo "[]")
    WS_COUNT=$(echo "${WS_API}" | jq 'length' 2>/dev/null || echo "0")
    check_pass "Workspaces API 응답 성공 (현재 Workspace 수: ${WS_COUNT})"

    log_info "에이전트 Workspace 설정 확인..."
    if [[ -n "${AGENT_ID:-}" ]]; then
        AGENT_WS_CFG=$(curl -s \
            "${GITLAB_URL}/api/v4/projects/${PROJ_ID}/cluster_agents/${AGENT_ID}" \
            -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" | \
            jq '.remote_development // "설정 없음"' 2>/dev/null || echo "{}")
        log_info "  에이전트 Remote Development 설정: ${AGENT_WS_CFG}"
    fi
fi

# ============================================================
log_step "7. 전체 설치 인프라 요약"
# ============================================================

echo ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Helm Releases"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
helm list -A --output table 2>/dev/null || true

echo ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "네임스페이스별 파드 상태"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
for ns in cert-manager ingress-nginx "${GITLAB_AGENT_NAMESPACE}" "${WORKSPACES_PROXY_NAMESPACE}"; do
    echo ""
    echo -e "${CYAN}  [Namespace: ${ns}]${NC}"
    kubectl get pods -n "${ns}" --no-headers 2>/dev/null | \
        awk '{printf "    %-45s %-10s %s\n", $1, $3, $5}' || \
        echo "    (네임스페이스 없음 또는 파드 없음)"
done

# ============================================================
log_step "검증 결과 요약"
# ============================================================
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GREEN}${BOLD}PASS: ${PASS}${NC}  |  ${YELLOW}${BOLD}WARN: ${WARN}${NC}  |  ${RED}${BOLD}FAIL: ${FAIL}${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [[ "${FAIL}" -gt 0 ]]; then
    log_error "검증 실패 ${FAIL}개 - FAIL 항목 해결 후 해당 스크립트를 재실행하세요."
    exit 1
elif [[ "${WARN}" -gt 0 ]]; then
    log_warn "경고 ${WARN}개 - 경고 항목을 검토한 후 Workspace를 생성해 보세요."
else
    log_success "모든 항목 통과! GitLab 18.9 Workspaces 사용 준비 완료"
fi

echo ""
divider
log_info "Workspace 생성 방법:"
log_info "  1. 프로젝트 루트에 '.devfile.yaml' 추가 (config/devfile-example.yaml 참고)"
log_info "  2. ${GITLAB_URL}/-/remote_development/workspaces/new 접속"
log_info "  3. 에이전트 '${GITLAB_AGENT_NAME}' 선택 → 프로젝트 선택 → 생성"
log_info ""
log_info "  GitLab 18.0+ 신기능: MR 페이지에서 'Open in Workspace' 바로 클릭 가능"
divider
echo ""
log_info "로그 파일: ${LOG_FILE}"
