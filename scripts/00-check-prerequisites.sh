#!/usr/bin/env bash
# ============================================================
# GitLab Workspaces - 사전 요구사항 점검 스크립트
# 대상: GitLab 18.9
# ============================================================
# 점검 항목:
#   1. 필수 CLI 도구 (kubectl, helm, curl, jq, openssl)
#   2. Kubernetes 버전 (1.33 이상) 및 클러스터 연결
#   3. GitLab 버전 (18.0 이상), 라이선스, KAS 상태
#   4. 기존 컴포넌트 설치 여부
#   5. 네트워크 및 DNS
#   6. 스토리지클래스 및 RBAC 권한
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

source "${SCRIPT_DIR}/lib/logging.sh"
setup_logging

ENV_FILE="${ROOT_DIR}/.env"
if [[ ! -f "${ENV_FILE}" ]]; then
    log_error ".env 파일이 없습니다."
    log_error "  cp ${ROOT_DIR}/.env.example ${ROOT_DIR}/.env"
    exit 1
fi
source "${ENV_FILE}"

PASS=0; FAIL=0; WARN=0
check_pass() { log_success "  ✔ $*"; ((PASS++)); }
check_fail() { log_fail    "  ✖ $*"; ((FAIL++)); }
check_warn() { log_warn    "  ⚠ $*"; ((WARN++)); }

# ============================================================
log_header "GitLab Workspaces 사전 요구사항 점검 (GitLab 18.9)"
# ============================================================

# ============================================================
log_step "1. 필수 CLI 도구 확인"
# ============================================================

declare -A TOOL_MIN_VERSIONS=(
    ["kubectl"]="1.33"
    ["helm"]="3.14"
    ["curl"]="7"
    ["jq"]="1.6"
    ["openssl"]="3"
)

for tool in kubectl helm curl jq openssl; do
    if command -v "${tool}" &>/dev/null; then
        ver=$(${tool} version --client --short 2>/dev/null | head -1 || \
              ${tool} --version 2>/dev/null | head -1 || echo "버전 불명")
        check_pass "${tool}: ${ver}"
    else
        check_fail "${tool} 미설치"
    fi
done

# Helm 버전 확인 (3.14 이상 권장)
HELM_VER=$(helm version --short 2>/dev/null | sed 's/v//' | cut -d'.' -f1,2 || echo "0.0")
HELM_MAJOR=$(echo "${HELM_VER}" | cut -d'.' -f1)
HELM_MINOR=$(echo "${HELM_VER}" | cut -d'.' -f2)
if [[ "${HELM_MAJOR}" -ge 3 && "${HELM_MINOR}" -ge 14 ]]; then
    check_pass "Helm 버전 충족 (${HELM_VER})"
elif [[ "${HELM_MAJOR}" -ge 3 && "${HELM_MINOR}" -ge 6 ]]; then
    check_warn "Helm ${HELM_VER} - GitLab 18.9은 3.14 이상 권장"
else
    check_fail "Helm 3.6 이상 필요 (현재: ${HELM_VER})"
fi

# ============================================================
log_step "2. Kubernetes 클러스터 확인"
# ============================================================

log_info "현재 kubeconfig context..."
CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "")
if [[ -n "${CURRENT_CTX}" ]]; then
    check_pass "현재 context: ${CURRENT_CTX}"
else
    check_fail "kubectl context 미설정"
fi

log_info "클러스터 API 서버 연결 확인..."
if kubectl cluster-info &>/dev/null; then
    kubectl cluster-info | grep -E "Kubernetes|running" || true
    check_pass "클러스터 API 서버 연결 성공"
else
    check_fail "클러스터 API 서버 연결 실패"
fi

log_info "Kubernetes 버전 확인 (최소 1.33 필요)..."
K8S_JSON=$(kubectl version -o json 2>/dev/null || echo "{}")
K8S_VER=$(echo "${K8S_JSON}" | jq -r '.serverVersion.gitVersion' 2>/dev/null || echo "")
if [[ -n "${K8S_VER}" && "${K8S_VER}" != "null" ]]; then
    K8S_MINOR=$(echo "${K8S_VER}" | sed 's/v[0-9]*\.\([0-9]*\).*/\1/')
    K8S_MAJOR=$(echo "${K8S_VER}" | sed 's/v\([0-9]*\)\..*/\1/')
    if [[ "${K8S_MAJOR}" -ge 1 && "${K8S_MINOR}" -ge 33 ]]; then
        check_pass "Kubernetes 버전: ${K8S_VER} (요구사항 충족: 1.33+)"
    elif [[ "${K8S_MAJOR}" -ge 1 && "${K8S_MINOR}" -ge 27 ]]; then
        check_warn "Kubernetes ${K8S_VER} - GitLab 18.9은 1.33 이상 권장"
    else
        check_fail "Kubernetes 버전 부족: ${K8S_VER} (1.33 이상 필요)"
    fi
else
    check_warn "Kubernetes 버전 확인 불가"
fi

log_info "노드 상태..."
echo ""
kubectl get nodes -o wide 2>/dev/null || true
echo ""

READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
if [[ "${READY_NODES}" -gt 0 ]]; then
    check_pass "Ready 상태 노드: ${READY_NODES}개"
else
    check_fail "Ready 상태 노드 없음"
fi

log_info "클러스터 노드 리소스 (metrics-server 필요)..."
kubectl top nodes 2>/dev/null || log_warn "  metrics-server 미설치 - 리소스 사용량 확인 불가"

# ============================================================
log_step "3. GitLab 인스턴스 확인 (18.0 이상 필요)"
# ============================================================

log_info "GitLab URL: ${GITLAB_URL}"

log_info "GitLab API 연결 확인..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 10 \
    "${GITLAB_URL}/api/v4/version" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null || echo "000")

if [[ "${HTTP_CODE}" == "200" ]]; then
    check_pass "GitLab API 응답: HTTP ${HTTP_CODE}"
else
    check_fail "GitLab API 연결 실패: HTTP ${HTTP_CODE}"
fi

log_info "GitLab 버전 확인..."
VERSION_JSON=$(curl -s --connect-timeout 10 \
    "${GITLAB_URL}/api/v4/version" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null || echo "{}")

GL_VERSION=$(echo "${VERSION_JSON}" | jq -r '.version' 2>/dev/null || echo "")
GL_REVISION=$(echo "${VERSION_JSON}" | jq -r '.revision' 2>/dev/null || echo "")
if [[ -n "${GL_VERSION}" && "${GL_VERSION}" != "null" ]]; then
    GL_MAJOR=$(echo "${GL_VERSION}" | cut -d'.' -f1)
    GL_MINOR=$(echo "${GL_VERSION}" | cut -d'.' -f2)
    if [[ "${GL_MAJOR}" -ge 18 ]]; then
        check_pass "GitLab 버전: ${GL_VERSION} (revision: ${GL_REVISION}) - 요구사항 충족"
    elif [[ "${GL_MAJOR}" -eq 17 && "${GL_MINOR}" -ge 0 ]]; then
        check_warn "GitLab ${GL_VERSION} - 이 스크립트는 18.0 이상 기준으로 작성됨"
    else
        check_fail "GitLab 버전 부족: ${GL_VERSION} (18.0 이상 필요)"
    fi
else
    check_warn "GitLab 버전 확인 불가 (토큰/URL 재확인)"
fi

log_info "GitLab 라이선스 확인 (Premium/Ultimate 필요)..."
LICENSE_JSON=$(curl -s --connect-timeout 10 \
    "${GITLAB_URL}/api/v4/license" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null || echo "{}")
GL_PLAN=$(echo "${LICENSE_JSON}" | jq -r '.plan' 2>/dev/null || echo "")
GL_EXP=$(echo "${LICENSE_JSON}" | jq -r '.expires_at' 2>/dev/null || echo "")
case "${GL_PLAN}" in
    ultimate|premium)
        check_pass "GitLab 라이선스: ${GL_PLAN} (만료: ${GL_EXP})" ;;
    free|starter|bronze)
        check_fail "GitLab 라이선스 부족: ${GL_PLAN} (Premium/Ultimate 필요)" ;;
    *)
        check_warn "라이선스 확인 불가 (plan: '${GL_PLAN}') - Admin 권한 토큰 확인" ;;
esac

log_info "Personal Access Token 권한 확인..."
TOKEN_JSON=$(curl -s --connect-timeout 10 \
    "${GITLAB_URL}/api/v4/personal_access_tokens/self" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null || echo "{}")
TOKEN_SCOPES=$(echo "${TOKEN_JSON}" | jq -r '.scopes[]?' 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo "")
TOKEN_ACTIVE=$(echo "${TOKEN_JSON}" | jq -r '.active' 2>/dev/null || echo "false")
if [[ "${TOKEN_ACTIVE}" == "true" ]]; then
    if echo "${TOKEN_SCOPES}" | grep -q "api"; then
        check_pass "토큰 활성 상태, 권한: ${TOKEN_SCOPES}"
    else
        check_warn "토큰은 활성화되어 있으나 'api' 권한 없음: ${TOKEN_SCOPES}"
    fi
else
    check_fail "토큰 비활성 또는 만료됨"
fi

log_info "GitLab 프로젝트 접근 확인 (${GITLAB_PROJECT_PATH})..."
PROJ_ENC=$(echo "${GITLAB_PROJECT_PATH}" | sed 's/\//%2F/g')
PROJ_JSON=$(curl -s --connect-timeout 10 \
    "${GITLAB_URL}/api/v4/projects/${PROJ_ENC}" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null || echo "{}")
PROJ_ID=$(echo "${PROJ_JSON}" | jq -r '.id' 2>/dev/null || echo "")
if [[ -n "${PROJ_ID}" && "${PROJ_ID}" != "null" ]]; then
    PROJ_NAME=$(echo "${PROJ_JSON}" | jq -r '.name_with_namespace')
    check_pass "프로젝트 접근 성공: ${PROJ_NAME} (ID: ${PROJ_ID})"
else
    check_fail "프로젝트 '${GITLAB_PROJECT_PATH}' 접근 불가"
fi

log_info "GitLab KAS (Kubernetes Agent Server) 활성화 확인..."
META_JSON=$(curl -s --connect-timeout 10 \
    "${GITLAB_URL}/api/v4/metadata" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null || echo "{}")
KAS_ENABLED=$(echo "${META_JSON}" | jq -r '.kas.enabled' 2>/dev/null || echo "false")
KAS_EXT_URL=$(echo "${META_JSON}" | jq -r '.kas.externalUrl' 2>/dev/null || echo "")
KAS_VER=$(echo "${META_JSON}" | jq -r '.kas.version' 2>/dev/null || echo "")
if [[ "${KAS_ENABLED}" == "true" ]]; then
    check_pass "KAS 활성화됨 | URL: ${KAS_EXT_URL} | 버전: ${KAS_VER}"
else
    check_fail "KAS 비활성화 - Admin > Settings > Kubernetes > Agent Server 에서 활성화 필요"
fi

# ============================================================
log_step "4. 기존 컴포넌트 설치 여부 확인"
# ============================================================

log_info "cert-manager 확인..."
if kubectl get ns cert-manager &>/dev/null; then
    CM_RUNNING=$(kubectl get pods -n cert-manager --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    if [[ "${CM_RUNNING}" -gt 0 ]]; then
        CM_VER=$(helm list -n cert-manager -o json 2>/dev/null | jq -r '.[0].chart' || echo "버전 불명")
        check_pass "cert-manager 설치됨 (Running: ${CM_RUNNING}, chart: ${CM_VER})"
    else
        check_warn "cert-manager 네임스페이스 존재, Running 파드 없음"
    fi
    kubectl get pods -n cert-manager 2>/dev/null || true
else
    check_warn "cert-manager 미설치 - 01-setup-dependencies.sh 에서 설치됩니다"
fi

log_info "Ingress Controller 확인..."
INGRESS_FOUND=false
for ns in ingress-nginx nginx-ingress kube-system; do
    if kubectl get pods -n "${ns}" --no-headers 2>/dev/null | grep -qi "ingress"; then
        CNT=$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null | grep -i ingress | grep -c "Running" || echo "0")
        check_pass "Ingress Controller 발견: ns=${ns}, Running=${CNT}"
        INGRESS_FOUND=true
        break
    fi
done
[[ "${INGRESS_FOUND}" == "false" ]] && \
    check_warn "Ingress Controller 없음 - 01-setup-dependencies.sh 에서 설치됩니다"

log_info "GitLab Agent (${GITLAB_AGENT_NAMESPACE}) 확인..."
if kubectl get ns "${GITLAB_AGENT_NAMESPACE}" &>/dev/null; then
    AG_PODS=$(kubectl get pods -n "${GITLAB_AGENT_NAMESPACE}" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    check_warn "에이전트 네임스페이스 이미 존재 (Running: ${AG_PODS}) - 재설치 시 기존 릴리즈 업그레이드됩니다"
    kubectl get pods -n "${GITLAB_AGENT_NAMESPACE}" 2>/dev/null || true
else
    check_pass "에이전트 네임스페이스 미존재 - 신규 설치 진행 가능"
fi

log_info "Workspaces Proxy (${WORKSPACES_PROXY_NAMESPACE}) 확인..."
if kubectl get ns "${WORKSPACES_PROXY_NAMESPACE}" &>/dev/null; then
    WP_PODS=$(kubectl get pods -n "${WORKSPACES_PROXY_NAMESPACE}" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    check_warn "Proxy 네임스페이스 이미 존재 (Running: ${WP_PODS})"
else
    check_pass "Proxy 네임스페이스 미존재 - 신규 설치 진행 가능"
fi

# ============================================================
log_step "5. 네트워크 및 DNS 확인"
# ============================================================

log_info "Workspaces 도메인 DNS 확인: *.${WORKSPACES_DOMAIN}"
if nslookup "test.${WORKSPACES_DOMAIN}" &>/dev/null 2>&1; then
    check_pass "*.${WORKSPACES_DOMAIN} DNS 해석 가능"
else
    check_warn "*.${WORKSPACES_DOMAIN} DNS 미설정 - 설치 후 LoadBalancer IP로 와일드카드 DNS 등록 필요"
fi

log_info "Workspaces Proxy 도메인 DNS 확인: ${WORKSPACES_PROXY_DOMAIN}"
if nslookup "${WORKSPACES_PROXY_DOMAIN}" &>/dev/null 2>&1; then
    check_pass "${WORKSPACES_PROXY_DOMAIN} DNS 해석 가능"
else
    check_warn "${WORKSPACES_PROXY_DOMAIN} DNS 미설정"
fi

log_info "GitLab Helm 저장소 접근 확인..."
if curl -s --connect-timeout 5 "https://charts.gitlab.io" &>/dev/null; then
    check_pass "GitLab Helm 저장소(charts.gitlab.io) 접근 가능"
else
    check_warn "GitLab Helm 저장소 접근 불가 - 내부망의 경우 미러 저장소 설정 필요"
fi

log_info "Workspaces Proxy Helm 저장소 접근 확인..."
if curl -s --connect-timeout 5 \
    "https://gitlab.com/api/v4/projects/gitlab-org%2Fworkspaces%2Fgitlab-workspaces-proxy/packages/helm/devel" \
    &>/dev/null; then
    check_pass "Workspaces Proxy Helm 저장소 접근 가능"
else
    check_warn "Workspaces Proxy Helm 저장소 접근 불가 (gitlab.com 연결 확인)"
fi

# ============================================================
log_step "6. 스토리지 클래스 확인"
# ============================================================

log_info "StorageClass 목록..."
kubectl get storageclass 2>/dev/null || log_warn "StorageClass 정보 없음"

DEFAULT_SC=$(kubectl get storageclass -o json 2>/dev/null | \
    jq -r '.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true") | .metadata.name' 2>/dev/null || echo "")
if [[ -n "${DEFAULT_SC}" ]]; then
    check_pass "기본 StorageClass: ${DEFAULT_SC} (Workspace PVC 동적 프로비저닝 가능)"
else
    check_fail "기본 StorageClass 없음 - Workspace PVC 생성 불가 (동적 프로비저닝 필수)"
fi

# ============================================================
log_step "7. RBAC 권한 확인"
# ============================================================

for action_resource in "create:namespace" "create:clusterrolebinding" "create:deployment" "get:secret"; do
    action="${action_resource%%:*}"
    resource="${action_resource##*:}"
    if kubectl auth can-i "${action}" "${resource}" &>/dev/null; then
        check_pass "kubectl auth can-i ${action} ${resource}: 허용"
    else
        check_fail "kubectl auth can-i ${action} ${resource}: 거부 - cluster-admin 권한 필요"
    fi
done

# ============================================================
log_step "점검 결과 요약"
# ============================================================
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GREEN}${BOLD}PASS: ${PASS}${NC}  |  ${YELLOW}${BOLD}WARN: ${WARN}${NC}  |  ${RED}${BOLD}FAIL: ${FAIL}${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [[ "${FAIL}" -gt 0 ]]; then
    log_error "필수 요구사항 ${FAIL}개 미충족 - FAIL 항목 해결 후 재실행하세요."
    exit 1
elif [[ "${WARN}" -gt 0 ]]; then
    log_warn "경고 ${WARN}개 - 내용 확인 후 다음 단계 진행하세요."
    log_info "  다음: bash ${SCRIPT_DIR}/01-setup-dependencies.sh"
    exit 0
else
    log_success "모든 사전 요구사항 충족!"
    log_info "  다음: bash ${SCRIPT_DIR}/01-setup-dependencies.sh"
    exit 0
fi
