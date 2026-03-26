#!/usr/bin/env bash
# ============================================================
# GitLab Workspaces - GitLab 인스턴스 설정 스크립트
# ============================================================
# 수행 작업:
#   1. GitLab Admin 설정에서 Remote Development 활성화
#   2. 네트워크 허용 목록 설정
#   3. 설정 검증
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

# ============================================================
log_header "GitLab Workspaces 인스턴스 설정"
# ============================================================

# ============================================================
log_step "1. GitLab Admin 설정 확인"
# ============================================================

log_info "GitLab Application Settings 조회..."
APP_SETTINGS=$(curl -s \
    "${GITLAB_URL}/api/v4/application/settings" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")

if echo "${APP_SETTINGS}" | jq -e '.error' &>/dev/null; then
    log_error "Application Settings 조회 실패 - Admin 권한 토큰이 필요합니다."
    log_warn "현재 오류: $(echo "${APP_SETTINGS}" | jq -r '.error')"
    log_warn "GITLAB_TOKEN이 Admin 권한을 가진 사용자의 토큰인지 확인하세요."
fi

# Remote Development 설정 확인
REMOTE_DEV_ENABLED=$(echo "${APP_SETTINGS}" | jq -r '.remote_development_enabled // false' 2>/dev/null || echo "false")
log_info "Remote Development 활성화 상태: ${REMOTE_DEV_ENABLED}"

# ============================================================
log_step "2. GitLab Workspaces 기능 활성화"
# ============================================================

if [[ "${REMOTE_DEV_ENABLED}" == "true" ]]; then
    log_success "Remote Development(Workspaces) 이미 활성화됨"
else
    log_info "Remote Development(Workspaces) 활성화 중..."
    UPDATE_RESPONSE=$(curl -s -X PUT \
        "${GITLAB_URL}/api/v4/application/settings" \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"remote_development_enabled": true}')

    NEW_STATUS=$(echo "${UPDATE_RESPONSE}" | jq -r '.remote_development_enabled // false' 2>/dev/null || echo "false")
    if [[ "${NEW_STATUS}" == "true" ]]; then
        log_success "Remote Development 활성화 완료"
    else
        log_warn "Remote Development 활성화 실패 또는 수동 설정이 필요합니다."
        log_warn "GitLab Admin 패널에서 수동으로 활성화하세요:"
        log_warn "  ${GITLAB_URL}/admin/application_settings/general"
        log_warn "  → 'Remote Development' 섹션 → Enable 체크"
    fi
fi

# ============================================================
log_step "3. 네트워크 외부 요청 허용 설정"
# ============================================================

log_info "현재 네트워크 외부 요청 설정 확인..."
OUTBOUND_LOCAL=$(echo "${APP_SETTINGS}" | jq -r '.allow_local_requests_from_web_hooks_and_services // false' 2>/dev/null || echo "false")
log_info "  로컬 요청 허용 (Webhooks): ${OUTBOUND_LOCAL}"

# GitLab Workspaces는 내부 서비스와 통신이 필요할 수 있음
WORKSPACE_PROXY_HOST="auth.${WORKSPACES_DOMAIN}"
log_info "Workspace Proxy 호스트를 허용 목록에 추가..."

# 현재 허용된 URL 목록 조회
ALLOWLIST_RESPONSE=$(curl -s \
    "${GITLAB_URL}/api/v4/application/settings" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" | \
    jq -r '.outbound_local_requests_allowlist // []' 2>/dev/null || echo "[]")
log_info "현재 허용 목록: $(echo "${ALLOWLIST_RESPONSE}" | jq -r '.[]?' | tr '\n' ',' | sed 's/,$//' || echo '없음')"

# ============================================================
log_step "4. GitLab Admin에서 Workspaces 설정 확인 안내"
# ============================================================

log_info "GitLab 관리자 패널에서 다음 설정을 확인하세요:"
echo ""
echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│  GitLab Admin 수동 설정 체크리스트                           │${NC}"
echo -e "${CYAN}├─────────────────────────────────────────────────────────────┤${NC}"
echo -e "${CYAN}│                                                               │${NC}"
echo -e "${CYAN}│  1. KAS (Kubernetes Agent Server) 활성화                      │${NC}"
echo -e "${CYAN}│     경로: Admin > Settings > Kubernetes > Agent Server        │${NC}"
echo -e "${CYAN}│     URL: ${GITLAB_URL}/admin/clusters                         │${NC}"
echo -e "${CYAN}│                                                               │${NC}"
echo -e "${CYAN}│  2. Remote Development (Workspaces) 활성화                    │${NC}"
echo -e "${CYAN}│     경로: Admin > Settings > General > Remote Development     │${NC}"
echo -e "${CYAN}│     URL: ${GITLAB_URL}/admin/application_settings/general     │${NC}"
echo -e "${CYAN}│                                                               │${NC}"
echo -e "${CYAN}│  3. 에이전트 연결 확인                                         │${NC}"
echo -e "${CYAN}│     경로: Project > Operate > Kubernetes clusters             │${NC}"
echo -e "${CYAN}│     URL: ${GITLAB_URL}/${GITLAB_PROJECT_PATH}/-/clusters/agents │${NC}"
echo -e "${CYAN}│                                                               │${NC}"
echo -e "${CYAN}│  4. Workspace 설정 확인                                        │${NC}"
echo -e "${CYAN}│     경로: GitLab > Workspaces                                  │${NC}"
echo -e "${CYAN}│     URL: ${GITLAB_URL}/-/remote_development/workspaces/new    │${NC}"
echo -e "${CYAN}│                                                               │${NC}"
echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
echo ""

# ============================================================
log_step "5. 에이전트 설정에서 Workspaces 활성화 확인"
# ============================================================

log_info "프로젝트 ID 조회..."
PROJECT_ENCODED=$(echo "${GITLAB_PROJECT_PATH}" | sed 's/\//%2F/g')
PROJECT_INFO=$(curl -s \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ENCODED}" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")
PROJECT_ID=$(echo "${PROJECT_INFO}" | jq -r '.id')

if [[ -n "${PROJECT_ID}" && "${PROJECT_ID}" != "null" ]]; then
    log_info "등록된 에이전트 목록 조회 (Project ID: ${PROJECT_ID})..."
    AGENTS=$(curl -s \
        "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/cluster_agents" \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")

    log_info "등록된 에이전트:"
    echo "${AGENTS}" | jq -r '.[] | "  - \(.name) (ID: \(.id), Created: \(.created_at))"' 2>/dev/null || \
        echo "  에이전트 없음 또는 조회 실패"

    # 에이전트 ID 조회
    AGENT_ID=$(echo "${AGENTS}" | jq -r ".[] | select(.name == \"${GITLAB_AGENT_NAME}\") | .id" 2>/dev/null || echo "")
    if [[ -n "${AGENT_ID}" ]]; then
        log_info "에이전트 '${GITLAB_AGENT_NAME}' 상세 정보:"
        curl -s \
            "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/cluster_agents/${AGENT_ID}" \
            -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" | jq '.'
    fi
fi

# ============================================================
log_step "완료"
# ============================================================
log_success "GitLab Workspaces 설정 완료!"
log_info "다음 단계: bash ${SCRIPT_DIR}/05-verify-installation.sh"
