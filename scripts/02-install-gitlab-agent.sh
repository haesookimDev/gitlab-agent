#!/usr/bin/env bash
# ============================================================
# GitLab Workspaces - GitLab Agent for Kubernetes 설치 스크립트
# ============================================================
# 수행 작업:
#   1. GitLab에 Agent 등록 (API 사용)
#   2. 에이전트 설정 파일을 GitLab 프로젝트에 커밋
#   3. Helm을 사용하여 클러스터에 에이전트 설치
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

# ============================================================
log_header "GitLab Agent for Kubernetes 설치"
# ============================================================

# ============================================================
log_step "1. 에이전트 설정 파일 준비"
# ============================================================

AGENT_CONFIG_TEMPLATE="${CONFIG_DIR}/agent-config.yaml"
AGENT_CONFIG_RENDERED="/tmp/agent-config-rendered.yaml"

log_info "에이전트 설정 파일 렌더링: ${AGENT_CONFIG_TEMPLATE}"
sed \
    -e "s|your-group/your-project|${GITLAB_PROJECT_PATH}|g" \
    -e "s|workspaces.example.com|${WORKSPACES_DOMAIN}|g" \
    -e "s|https://gitlab.example.com|${GITLAB_URL}|g" \
    "${AGENT_CONFIG_TEMPLATE}" > "${AGENT_CONFIG_RENDERED}"

log_info "렌더링된 에이전트 설정 내용:"
divider
cat "${AGENT_CONFIG_RENDERED}"
divider

# ============================================================
log_step "2. GitLab 프로젝트에 Agent 등록"
# ============================================================

# 프로젝트 ID 조회
log_info "GitLab 프로젝트 ID 조회: ${GITLAB_PROJECT_PATH}..."
PROJECT_ENCODED=$(echo "${GITLAB_PROJECT_PATH}" | sed 's/\//%2F/g')
PROJECT_INFO=$(curl -s \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ENCODED}" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")
PROJECT_ID=$(echo "${PROJECT_INFO}" | jq -r '.id')

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "null" ]]; then
    log_error "프로젝트를 찾을 수 없습니다: ${GITLAB_PROJECT_PATH}"
    exit 1
fi
log_success "프로젝트 ID: ${PROJECT_ID}"

# 기존 에이전트 확인
log_info "기존 등록된 에이전트 목록 조회..."
EXISTING_AGENTS=$(curl -s \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/cluster_agents" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")
log_info "기존 에이전트: $(echo "${EXISTING_AGENTS}" | jq -r '.[].name' 2>/dev/null | tr '\n' ', ' || echo '없음')"

AGENT_ID=$(echo "${EXISTING_AGENTS}" | jq -r ".[] | select(.name == \"${GITLAB_AGENT_NAME}\") | .id" 2>/dev/null || echo "")

if [[ -n "${AGENT_ID}" && "${AGENT_ID}" != "null" ]]; then
    log_warn "에이전트 '${GITLAB_AGENT_NAME}'가 이미 등록되어 있습니다 (ID: ${AGENT_ID})"
    log_info "기존 에이전트를 사용합니다."
else
    log_info "에이전트 '${GITLAB_AGENT_NAME}' 등록..."
    CREATE_RESPONSE=$(curl -s -X POST \
        "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/cluster_agents" \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"${GITLAB_AGENT_NAME}\"}")

    AGENT_ID=$(echo "${CREATE_RESPONSE}" | jq -r '.id')
    if [[ -z "${AGENT_ID}" || "${AGENT_ID}" == "null" ]]; then
        log_error "에이전트 등록 실패: $(echo "${CREATE_RESPONSE}" | jq -r '.message // .')"
        exit 1
    fi
    log_success "에이전트 등록 완료 (ID: ${AGENT_ID})"
fi

# ============================================================
log_step "3. 에이전트 토큰 생성"
# ============================================================

# 기존 토큰 확인
log_info "에이전트 토큰 목록 조회..."
EXISTING_TOKENS=$(curl -s \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/cluster_agents/${AGENT_ID}/tokens" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")
TOKEN_COUNT=$(echo "${EXISTING_TOKENS}" | jq 'length' 2>/dev/null || echo "0")
log_info "기존 토큰 수: ${TOKEN_COUNT}"

# 새 토큰 생성 (항상 새로 생성 - 보안상)
log_info "새 에이전트 토큰 생성..."
TOKEN_RESPONSE=$(curl -s -X POST \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/cluster_agents/${AGENT_ID}/tokens" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"k8s-install-$(date +%Y%m%d%H%M%S)\"}")

AGENT_TOKEN=$(echo "${TOKEN_RESPONSE}" | jq -r '.token')
if [[ -z "${AGENT_TOKEN}" || "${AGENT_TOKEN}" == "null" ]]; then
    log_error "에이전트 토큰 생성 실패: $(echo "${TOKEN_RESPONSE}" | jq -r '.message // .')"
    exit 1
fi

log_success "에이전트 토큰 생성 완료"
log_warn "이 토큰은 다시 표시되지 않습니다. 안전한 곳에 보관하세요."

# 토큰을 임시 파일에 저장 (프록시 설치 시 참조)
echo "${AGENT_TOKEN}" > /tmp/gitlab-agent-token
chmod 600 /tmp/gitlab-agent-token
log_info "토큰이 /tmp/gitlab-agent-token에 임시 저장되었습니다."

# ============================================================
log_step "4. GitLab 프로젝트에 에이전트 설정 파일 업로드"
# ============================================================

AGENT_CONFIG_PATH=".gitlab/agents/${GITLAB_AGENT_NAME}/config.yaml"
AGENT_CONFIG_CONTENT=$(base64 -w 0 "${AGENT_CONFIG_RENDERED}")

log_info "에이전트 설정 파일 경로: ${AGENT_CONFIG_PATH}"

# 파일 존재 여부 확인
EXISTING_FILE=$(curl -s \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/repository/files/$(echo "${AGENT_CONFIG_PATH}" | sed 's/\//%2F/g')?ref=main" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null | jq -r '.file_name' 2>/dev/null || echo "")

if [[ -n "${EXISTING_FILE}" && "${EXISTING_FILE}" != "null" ]]; then
    log_info "기존 설정 파일 업데이트..."
    UPDATE_RESPONSE=$(curl -s -X PUT \
        "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/repository/files/$(echo "${AGENT_CONFIG_PATH}" | sed 's/\//%2F/g')" \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"branch\": \"main\",
            \"content\": $(jq -Rs '.' "${AGENT_CONFIG_RENDERED}"),
            \"commit_message\": \"chore: update GitLab Agent config for Workspaces\"
        }")
    log_success "설정 파일 업데이트 완료"
else
    log_info "새 설정 파일 생성..."

    # 디렉토리 구조 생성이 필요할 수 있어 단계적으로 처리
    CREATE_RESPONSE=$(curl -s -X POST \
        "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/repository/files/$(echo "${AGENT_CONFIG_PATH}" | sed 's/\//%2F/g')" \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"branch\": \"main\",
            \"content\": $(jq -Rs '.' "${AGENT_CONFIG_RENDERED}"),
            \"commit_message\": \"feat: add GitLab Agent config for Workspaces\"
        }")

    if echo "${CREATE_RESPONSE}" | jq -e '.file_path' &>/dev/null; then
        log_success "설정 파일 생성 완료: ${AGENT_CONFIG_PATH}"
    else
        log_warn "설정 파일 자동 생성 실패 - 수동으로 파일을 생성해주세요."
        log_warn "  경로: ${AGENT_CONFIG_PATH}"
        log_warn "  내용: ${AGENT_CONFIG_RENDERED}"
        log_info "오류: $(echo "${CREATE_RESPONSE}" | jq -r '.message // .')"
    fi
fi

# ============================================================
log_step "5. Kubernetes에 GitLab Agent 설치 (Helm)"
# ============================================================

AGENT_NS="${GITLAB_AGENT_NAMESPACE}"
GITLAB_AGENT_CHART_VERSION="${GITLAB_AGENT_CHART_VERSION:-2.4.0}"

log_info "에이전트 네임스페이스 '${AGENT_NS}' 생성..."
kubectl create namespace "${AGENT_NS}" --dry-run=client -o yaml | kubectl apply -f -
log_success "네임스페이스 준비 완료"

log_info "에이전트 토큰을 Kubernetes Secret으로 생성..."
kubectl create secret generic gitlab-agent-token \
    --namespace="${AGENT_NS}" \
    --from-literal=token="${AGENT_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
log_success "Secret 'gitlab-agent-token' 생성 완료"

# KAS 주소 조회
log_info "GitLab KAS 주소 조회..."
KAS_INFO=$(curl -s \
    "${GITLAB_URL}/api/v4/metadata" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")
KAS_ADDRESS=$(echo "${KAS_INFO}" | jq -r '.kas.externalUrl' 2>/dev/null || echo "")

if [[ -z "${KAS_ADDRESS}" || "${KAS_ADDRESS}" == "null" ]]; then
    # GitLab.com 기본 KAS 주소
    if echo "${GITLAB_URL}" | grep -q "gitlab.com"; then
        KAS_ADDRESS="wss://kas.gitlab.com"
    else
        # 자체 호스팅의 경우 기본 주소 추측
        GITLAB_HOST=$(echo "${GITLAB_URL}" | sed 's|https://||;s|http://||')
        KAS_ADDRESS="wss://${GITLAB_HOST}/-/kubernetes-agent"
        log_warn "KAS 주소를 자동 감지하지 못했습니다. 기본값 사용: ${KAS_ADDRESS}"
    fi
else
    log_success "KAS 주소: ${KAS_ADDRESS}"
fi

log_info "GitLab Agent Helm 설치 시작 (버전: ${GITLAB_AGENT_CHART_VERSION})..."
log_info "  - Namespace: ${AGENT_NS}"
log_info "  - KAS Address: ${KAS_ADDRESS}"
log_info "  - Agent Name: ${GITLAB_AGENT_NAME}"

if helm list -n "${AGENT_NS}" 2>/dev/null | grep -q "gitlab-agent"; then
    log_info "기존 gitlab-agent Helm 릴리즈 발견 - 업그레이드 진행..."
    HELM_ACTION="upgrade"
else
    log_info "신규 gitlab-agent Helm 설치 진행..."
    HELM_ACTION="install"
fi

helm "${HELM_ACTION}" gitlab-agent gitlab/gitlab-agent \
    --namespace "${AGENT_NS}" \
    --version "${GITLAB_AGENT_CHART_VERSION}" \
    --set config.token="${AGENT_TOKEN}" \
    --set config.kasAddress="${KAS_ADDRESS}" \
    --set rbac.create=true \
    --set serviceAccount.create=true \
    --set rbac.useExistingRole=false \
    --set config.observabilityPort=8888 \
    --wait \
    --timeout 5m \
    --debug 2>&1 | grep -E "STATUS|NOTES|deployed|error|Warning|NAME:" || true

log_info "GitLab Agent 파드 상태 확인..."
kubectl rollout status deployment/gitlab-agent -n "${AGENT_NS}" --timeout=3m

echo ""
log_info "설치된 에이전트 파드:"
kubectl get pods -n "${AGENT_NS}" -o wide
echo ""
log_info "에이전트 로그 (최근 20줄):"
kubectl logs -n "${AGENT_NS}" -l app=gitlab-agent --tail=20 2>/dev/null || true

# ============================================================
log_step "6. GitLab에서 에이전트 연결 확인"
# ============================================================

log_info "GitLab에서 에이전트 연결 상태 확인..."
sleep 15  # 에이전트가 KAS에 연결할 시간 대기

CONNECTION_STATUS=$(curl -s \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/cluster_agents/${AGENT_ID}" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")

AGENT_STATUS=$(echo "${CONNECTION_STATUS}" | jq -r '.connected // false' 2>/dev/null || echo "unknown")
log_info "에이전트 연결 상태: ${AGENT_STATUS}"

# ============================================================
log_step "완료"
# ============================================================
log_success "GitLab Agent 설치 완료!"
log_info ""
log_info "GitLab에서 에이전트 확인:"
log_info "  ${GITLAB_URL}/${GITLAB_PROJECT_PATH}/-/clusters/agents"
log_info ""
log_info "다음 단계: bash ${SCRIPT_DIR}/03-install-workspaces-proxy.sh"
