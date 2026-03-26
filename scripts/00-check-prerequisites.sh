#!/usr/bin/env bash
# ============================================================
# GitLab Workspaces - 사전 요구사항 점검 스크립트
# ============================================================
# 이 스크립트는 GitLab Workspaces 설치 전에 필요한 모든
# 환경 조건을 점검합니다.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

# 공통 라이브러리 로드
source "${SCRIPT_DIR}/lib/logging.sh"
setup_logging

# 환경 변수 파일 로드
ENV_FILE="${ROOT_DIR}/.env"
if [[ ! -f "${ENV_FILE}" ]]; then
    log_error ".env 파일이 없습니다. ${ROOT_DIR}/.env.example 을 복사하여 설정하세요."
    log_error "  cp ${ROOT_DIR}/.env.example ${ROOT_DIR}/.env"
    exit 1
fi
source "${ENV_FILE}"

# 점검 결과 추적
PASS=0
FAIL=0
WARN=0

check_pass() { log_success "  ✔ $*"; ((PASS++)); }
check_fail() { log_fail    "  ✖ $*"; ((FAIL++)); }
check_warn() { log_warn    "  ⚠ $*"; ((WARN++)); }

# ============================================================
log_header "GitLab Workspaces 사전 요구사항 점검"
# ============================================================

# ============================================================
log_step "1. 필수 CLI 도구 확인"
# ============================================================

REQUIRED_TOOLS=("kubectl" "helm" "curl" "jq" "openssl")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if command -v "${tool}" &>/dev/null; then
        version=$(${tool} version --client 2>/dev/null | head -1 || ${tool} --version 2>/dev/null | head -1 || echo "버전 확인 불가")
        check_pass "${tool} 설치됨: ${version}"
    else
        check_fail "${tool} 미설치 - 설치 필요"
    fi
done

# ============================================================
log_step "2. Kubernetes 클러스터 연결 확인"
# ============================================================

log_info "현재 kubeconfig context 확인..."
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "")
if [[ -z "${CURRENT_CONTEXT}" ]]; then
    check_fail "kubectl context가 설정되지 않음"
else
    check_pass "현재 context: ${CURRENT_CONTEXT}"
fi

log_info "클러스터 API 서버 연결 확인..."
if kubectl cluster-info &>/dev/null; then
    check_pass "클러스터 API 서버 연결 성공"
    kubectl cluster-info | grep -E "Kubernetes|running"
else
    check_fail "클러스터 API 서버에 연결할 수 없음"
fi

log_info "Kubernetes 버전 확인 (최소 1.23 필요)..."
K8S_VERSION=$(kubectl version --output=json 2>/dev/null | jq -r '.serverVersion.gitVersion' 2>/dev/null || echo "")
if [[ -n "${K8S_VERSION}" ]]; then
    MINOR=$(echo "${K8S_VERSION}" | sed 's/v[0-9]*\.\([0-9]*\).*/\1/')
    if [[ "${MINOR}" -ge 23 ]]; then
        check_pass "Kubernetes 버전: ${K8S_VERSION} (요구사항 충족)"
    else
        check_fail "Kubernetes 버전: ${K8S_VERSION} (1.23 이상 필요)"
    fi
else
    check_warn "Kubernetes 버전을 확인할 수 없음"
fi

log_info "노드 상태 확인..."
echo ""
kubectl get nodes -o wide 2>/dev/null || log_warn "노드 정보를 가져올 수 없음"
echo ""

READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready" || echo "0")
if [[ "${READY_NODES}" -gt 0 ]]; then
    check_pass "Ready 상태 노드: ${READY_NODES}개"
else
    check_fail "Ready 상태의 노드가 없음"
fi

log_info "노드 리소스 확인..."
kubectl top nodes 2>/dev/null || log_warn "metrics-server가 설치되지 않아 리소스 사용량 확인 불가"

# ============================================================
log_step "3. GitLab 인스턴스 연결 확인"
# ============================================================

log_info "GitLab URL: ${GITLAB_URL}"

log_info "GitLab API 연결 확인..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 10 \
    "${GITLAB_URL}/api/v4/version" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null || echo "000")

if [[ "${HTTP_STATUS}" == "200" ]]; then
    check_pass "GitLab API 연결 성공 (HTTP ${HTTP_STATUS})"
else
    check_fail "GitLab API 연결 실패 (HTTP ${HTTP_STATUS})"
fi

log_info "GitLab 버전 확인 (최소 16.0 필요)..."
GITLAB_VERSION_INFO=$(curl -s \
    --connect-timeout 10 \
    "${GITLAB_URL}/api/v4/version" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null || echo "{}")

GITLAB_VERSION=$(echo "${GITLAB_VERSION_INFO}" | jq -r '.version' 2>/dev/null || echo "")
if [[ -n "${GITLAB_VERSION}" && "${GITLAB_VERSION}" != "null" ]]; then
    MAJOR_VERSION=$(echo "${GITLAB_VERSION}" | cut -d'.' -f1)
    if [[ "${MAJOR_VERSION}" -ge 16 ]]; then
        check_pass "GitLab 버전: ${GITLAB_VERSION} (요구사항 충족)"
    else
        check_fail "GitLab 버전: ${GITLAB_VERSION} (16.0 이상 필요)"
    fi
else
    check_warn "GitLab 버전을 확인할 수 없음 (토큰 권한 또는 URL 확인 필요)"
fi

log_info "GitLab 라이선스 확인 (Premium/Ultimate 필요)..."
LICENSE_INFO=$(curl -s \
    --connect-timeout 10 \
    "${GITLAB_URL}/api/v4/license" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null || echo "{}")

LICENSE_PLAN=$(echo "${LICENSE_INFO}" | jq -r '.plan' 2>/dev/null || echo "")
if [[ "${LICENSE_PLAN}" == "premium" || "${LICENSE_PLAN}" == "ultimate" ]]; then
    check_pass "GitLab 라이선스: ${LICENSE_PLAN} (Workspaces 사용 가능)"
elif [[ "${LICENSE_PLAN}" == "free" || "${LICENSE_PLAN}" == "starter" ]]; then
    check_fail "GitLab 라이선스: ${LICENSE_PLAN} (Premium 또는 Ultimate 필요)"
else
    check_warn "GitLab 라이선스 확인 불가 (plan: '${LICENSE_PLAN}') - 관리자 권한 토큰 필요"
fi

log_info "GitLab Personal Access Token 권한 확인..."
TOKEN_INFO=$(curl -s \
    --connect-timeout 10 \
    "${GITLAB_URL}/api/v4/personal_access_tokens/self" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null || echo "{}")

TOKEN_SCOPES=$(echo "${TOKEN_INFO}" | jq -r '.scopes[]?' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
if echo "${TOKEN_SCOPES}" | grep -q "api"; then
    check_pass "토큰 권한: ${TOKEN_SCOPES}"
else
    check_warn "토큰 권한 확인 불가 또는 'api' 권한 없음: ${TOKEN_SCOPES}"
fi

log_info "GitLab 프로젝트 접근 확인 (${GITLAB_PROJECT_PATH})..."
PROJECT_INFO=$(curl -s \
    --connect-timeout 10 \
    "${GITLAB_URL}/api/v4/projects/$(echo "${GITLAB_PROJECT_PATH}" | sed 's/\//%2F/g')" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null || echo "{}")

PROJECT_ID=$(echo "${PROJECT_INFO}" | jq -r '.id' 2>/dev/null || echo "")
if [[ -n "${PROJECT_ID}" && "${PROJECT_ID}" != "null" ]]; then
    check_pass "프로젝트 접근 성공 (ID: ${PROJECT_ID})"
else
    check_fail "프로젝트 '${GITLAB_PROJECT_PATH}'에 접근할 수 없음"
fi

log_info "GitLab KAS (Kubernetes Agent Server) 활성화 여부 확인..."
KAS_INFO=$(curl -s \
    --connect-timeout 10 \
    "${GITLAB_URL}/api/v4/metadata" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null || echo "{}")

KAS_ENABLED=$(echo "${KAS_INFO}" | jq -r '.kas.enabled' 2>/dev/null || echo "false")
KAS_ADDRESS=$(echo "${KAS_INFO}" | jq -r '.kas.externalUrl' 2>/dev/null || echo "")
if [[ "${KAS_ENABLED}" == "true" ]]; then
    check_pass "GitLab KAS 활성화됨: ${KAS_ADDRESS}"
else
    check_fail "GitLab KAS가 비활성화됨. GitLab 관리자에서 KAS를 활성화해야 합니다."
    log_warn "  GitLab Admin > Settings > Kubernetes > Agent Server 에서 활성화"
fi

# ============================================================
log_step "4. 기존 설치 컴포넌트 확인"
# ============================================================

log_info "cert-manager 설치 여부 확인..."
if kubectl get namespace cert-manager &>/dev/null; then
    CM_PODS=$(kubectl get pods -n cert-manager --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    if [[ "${CM_PODS}" -gt 0 ]]; then
        check_pass "cert-manager 설치됨 (Running pods: ${CM_PODS})"
        kubectl get pods -n cert-manager 2>/dev/null
    else
        check_warn "cert-manager 네임스페이스 존재하나 Running 파드 없음"
        kubectl get pods -n cert-manager 2>/dev/null
    fi
else
    check_warn "cert-manager 미설치 - 설치 스크립트에서 자동 설치됩니다"
fi

log_info "Ingress Controller 확인..."
INGRESS_NS_LIST=("ingress-nginx" "nginx-ingress" "kube-system")
INGRESS_FOUND=false
for ns in "${INGRESS_NS_LIST[@]}"; do
    if kubectl get pods -n "${ns}" --no-headers 2>/dev/null | grep -q "ingress"; then
        INGRESS_PODS=$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null | grep "ingress" | grep -c "Running" || echo "0")
        check_pass "Ingress Controller 발견: namespace=${ns} (Running pods: ${INGRESS_PODS})"
        INGRESS_FOUND=true
        break
    fi
done
if [[ "${INGRESS_FOUND}" == "false" ]]; then
    check_warn "Ingress Controller를 찾을 수 없음 - 설치 스크립트에서 확인하세요"
fi

log_info "기존 GitLab Agent 설치 여부 확인..."
AGENT_NS="${GITLAB_AGENT_NAMESPACE:-gitlab-agent}"
if kubectl get namespace "${AGENT_NS}" &>/dev/null; then
    AGENT_PODS=$(kubectl get pods -n "${AGENT_NS}" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    check_warn "GitLab Agent 네임스페이스 '${AGENT_NS}' 이미 존재 (Running pods: ${AGENT_PODS})"
    kubectl get pods -n "${AGENT_NS}" 2>/dev/null
else
    check_pass "GitLab Agent 네임스페이스 '${AGENT_NS}' 미존재 (신규 설치 진행 가능)"
fi

log_info "기존 Workspaces Proxy 설치 여부 확인..."
PROXY_NS="${WORKSPACES_PROXY_NAMESPACE:-gitlab-workspaces}"
if kubectl get namespace "${PROXY_NS}" &>/dev/null; then
    PROXY_PODS=$(kubectl get pods -n "${PROXY_NS}" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    check_warn "Workspaces Proxy 네임스페이스 '${PROXY_NS}' 이미 존재 (Running pods: ${PROXY_PODS})"
else
    check_pass "Workspaces Proxy 네임스페이스 '${PROXY_NS}' 미존재 (신규 설치 진행 가능)"
fi

# ============================================================
log_step "5. 네트워크 및 DNS 확인"
# ============================================================

log_info "Workspaces 도메인 DNS 확인: *.${WORKSPACES_DOMAIN}"
if nslookup "test.${WORKSPACES_DOMAIN}" &>/dev/null 2>&1; then
    check_pass "*.${WORKSPACES_DOMAIN} DNS 해석 성공"
else
    check_warn "*.${WORKSPACES_DOMAIN} DNS 미설정 - 설치 후 Ingress LoadBalancer IP를 DNS에 등록해야 합니다"
fi

log_info "외부 인터넷 연결 확인 (Helm Chart 다운로드용)..."
if curl -s --connect-timeout 5 "https://charts.gitlab.io" &>/dev/null; then
    check_pass "GitLab Helm Repository 접근 가능"
else
    check_warn "GitLab Helm Repository 접근 불가 - 내부망 환경에서는 미러 저장소 설정 필요"
fi

# ============================================================
log_step "6. 스토리지 클래스 확인"
# ============================================================

log_info "사용 가능한 StorageClass 목록..."
kubectl get storageclass 2>/dev/null || log_warn "StorageClass 정보를 가져올 수 없음"

DEFAULT_SC=$(kubectl get storageclass -o json 2>/dev/null | \
    jq -r '.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true") | .metadata.name' 2>/dev/null || echo "")
if [[ -n "${DEFAULT_SC}" ]]; then
    check_pass "기본 StorageClass: ${DEFAULT_SC}"
else
    check_warn "기본 StorageClass가 설정되지 않음 - Workspace PVC 생성 시 명시적 지정 필요"
fi

# ============================================================
log_step "7. RBAC 권한 확인"
# ============================================================

log_info "현재 사용자의 클러스터 관리자 권한 확인..."
if kubectl auth can-i create namespace &>/dev/null; then
    check_pass "네임스페이스 생성 권한 있음"
else
    check_fail "네임스페이스 생성 권한 없음 - 클러스터 관리자 권한 필요"
fi

if kubectl auth can-i create clusterrolebinding &>/dev/null; then
    check_pass "ClusterRoleBinding 생성 권한 있음"
else
    check_fail "ClusterRoleBinding 생성 권한 없음 - cluster-admin 권한 필요"
fi

# ============================================================
log_step "점검 결과 요약"
# ============================================================
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  PASS: ${PASS}${NC}  |  ${YELLOW}${BOLD}WARN: ${WARN}${NC}  |  ${RED}${BOLD}FAIL: ${FAIL}${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [[ "${FAIL}" -gt 0 ]]; then
    log_error "필수 요구사항 ${FAIL}개 미충족 - FAIL 항목을 해결한 후 재실행하세요."
    exit 1
elif [[ "${WARN}" -gt 0 ]]; then
    log_warn "경고 ${WARN}개 존재 - 내용을 확인 후 다음 단계를 진행하세요."
    exit 0
else
    log_success "모든 사전 요구사항 충족! 다음 단계를 진행하세요:"
    log_info "  다음: bash ${SCRIPT_DIR}/01-setup-dependencies.sh"
    exit 0
fi
