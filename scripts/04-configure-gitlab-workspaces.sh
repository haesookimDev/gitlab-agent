#!/usr/bin/env bash
# ============================================================
# GitLab Workspaces - GitLab 인스턴스 설정 스크립트
# 대상: GitLab 18.9
# ============================================================
# 수행 작업:
#   1. GitLab Admin API로 Remote Development 활성화 확인
#   2. KAS 활성화 상태 재확인
#   3. Workspace Proxy 연동 상태 확인
#   4. 관리자 패널 수동 설정 안내 출력
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

# ============================================================
log_header "GitLab Workspaces 인스턴스 설정 확인 (GitLab 18.9)"
# ============================================================

# ============================================================
log_step "1. GitLab Admin Application Settings 확인"
# ============================================================

log_info "Application Settings 조회..."
APP_SETTINGS=$(curl -s "${GITLAB_URL}/api/v4/application/settings" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")

if echo "${APP_SETTINGS}" | jq -e '.error' &>/dev/null; then
    log_warn "Application Settings 조회 실패 (Admin 권한 필요): $(echo "${APP_SETTINGS}" | jq -r '.error')"
    log_warn "  토큰에 Admin 권한이 없는 경우 아래 수동 설정 안내를 참조하세요."
else
    # Remote Development 활성화 확인
    RD_ENABLED=$(echo "${APP_SETTINGS}" | jq -r '.remote_development_enabled // false')
    if [[ "${RD_ENABLED}" == "true" ]]; then
        log_success "Remote Development(Workspaces): 활성화됨"
    else
        log_info "Remote Development(Workspaces) 활성화 시도..."
        UPDATE_RESP=$(curl -s -X PUT \
            "${GITLAB_URL}/api/v4/application/settings" \
            -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
            -H "Content-Type: application/json" \
            -d '{"remote_development_enabled": true}')
        NEW_STATUS=$(echo "${UPDATE_RESP}" | jq -r '.remote_development_enabled // false')
        if [[ "${NEW_STATUS}" == "true" ]]; then
            log_success "Remote Development 활성화 완료"
        else
            log_warn "Remote Development 활성화 실패 - 수동 설정 필요"
        fi
    fi
fi

# ============================================================
log_step "2. KAS 연결 상태 재확인"
# ============================================================

log_info "GitLab KAS 상태 조회..."
META_JSON=$(curl -s "${GITLAB_URL}/api/v4/metadata" -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")
KAS_ENABLED=$(echo "${META_JSON}" | jq -r '.kas.enabled' 2>/dev/null || echo "false")
KAS_URL=$(echo "${META_JSON}" | jq -r '.kas.externalUrl' 2>/dev/null || echo "")
KAS_VER=$(echo "${META_JSON}" | jq -r '.kas.version' 2>/dev/null || echo "")

log_info "  KAS 활성화: ${KAS_ENABLED}"
log_info "  KAS URL   : ${KAS_URL}"
log_info "  KAS 버전  : ${KAS_VER}"

if [[ "${KAS_ENABLED}" == "true" ]]; then
    log_success "KAS 정상 운영 중"
else
    log_warn "KAS 비활성화 상태 - 아래 안내대로 활성화하세요"
fi

# ============================================================
log_step "3. 등록된 에이전트 및 Workspaces 원격 개발 상태 확인"
# ============================================================

log_info "프로젝트 에이전트 목록 조회..."
PROJ_ENC=$(echo "${GITLAB_PROJECT_PATH}" | sed 's/\//%2F/g')
PROJ_ID=$(curl -s "${GITLAB_URL}/api/v4/projects/${PROJ_ENC}" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" | jq -r '.id' 2>/dev/null || echo "")

if [[ -n "${PROJ_ID}" && "${PROJ_ID}" != "null" ]]; then
    AGENTS=$(curl -s \
        "${GITLAB_URL}/api/v4/projects/${PROJ_ID}/cluster_agents" \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")
    log_info "등록된 에이전트:"
    echo "${AGENTS}" | jq -r \
        '.[] | "  - \(.name)  ID:\(.id)  Created:\(.created_at)"' \
        2>/dev/null || echo "  없음"

    # Workspaces 목록 확인 (GitLab 18.x API)
    log_info "Workspaces 목록 조회..."
    WS_LIST=$(curl -s \
        "${GITLAB_URL}/api/v4/projects/${PROJ_ID}/remote_development/workspaces" \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null || echo "[]")
    WS_COUNT=$(echo "${WS_LIST}" | jq 'length' 2>/dev/null || echo "0")
    log_info "  현재 Workspace 수: ${WS_COUNT}"
    if [[ "${WS_COUNT}" -gt 0 ]]; then
        echo "${WS_LIST}" | jq -r \
            '.[] | "  - \(.name)  상태:\(.status)  사용자:\(.user.username)"' \
            2>/dev/null || true
    fi
else
    log_warn "프로젝트 조회 실패 - 에이전트 상태를 GitLab UI에서 확인하세요"
fi

# ============================================================
log_step "4. GitLab Admin 수동 설정 안내"
# ============================================================

LB_IP=$(cat /tmp/lb-external-ip 2>/dev/null || echo "[LoadBalancer IP]")

echo ""
echo -e "${CYAN}${BOLD}┌─────────────────────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}${BOLD}│  GitLab 18.9 Admin 설정 체크리스트                               │${NC}"
echo -e "${CYAN}${BOLD}├─────────────────────────────────────────────────────────────────┤${NC}"
echo -e "${CYAN}│                                                                   │${NC}"
echo -e "${CYAN}│  [1] KAS (Kubernetes Agent Server) 활성화 확인                     │${NC}"
echo -e "${CYAN}│      Admin > Settings > Kubernetes                                 │${NC}"
echo -e "${CYAN}│      → 'Kubernetes Agent Server' 활성화                            │${NC}"
echo -e "${CYAN}│      Self-hosted의 경우 gitlab.rb에 설정:                           │${NC}"
echo -e "${CYAN}│        gitlab_kas['enable'] = true                                 │${NC}"
echo -e "${CYAN}│                                                                   │${NC}"
echo -e "${CYAN}│  [2] Remote Development (Workspaces) 기능 활성화                   │${NC}"
echo -e "${CYAN}│      Admin > Settings > General > Remote Development               │${NC}"
echo -e "${CYAN}│      → 'Enable remote development' 체크                            │${NC}"
echo -e "${CYAN}│                                                                   │${NC}"
echo -e "${CYAN}│  [3] 에이전트 연결 확인                                              │${NC}"
echo -e "${CYAN}│      ${GITLAB_URL}/${GITLAB_PROJECT_PATH}/-/clusters/agents       │${NC}"
echo -e "${CYAN}│      → 에이전트가 'Connected' 상태인지 확인                          │${NC}"
echo -e "${CYAN}│                                                                   │${NC}"
echo -e "${CYAN}│  [4] DNS 설정 확인                                                  │${NC}"
echo -e "${CYAN}│      *.${WORKSPACES_DOMAIN} → ${LB_IP}                   │${NC}"
echo -e "${CYAN}│      ${WORKSPACES_PROXY_DOMAIN} → ${LB_IP}               │${NC}"
echo -e "${CYAN}│                                                                   │${NC}"
echo -e "${CYAN}│  [5] Workspace 생성 테스트                                          │${NC}"
echo -e "${CYAN}│      ${GITLAB_URL}/-/remote_development/workspaces/new            │${NC}"
echo -e "${CYAN}│      또는: 프로젝트 > Edit > Open in a new workspace               │${NC}"
echo -e "${CYAN}│                                                                   │${NC}"
echo -e "${CYAN}│  [6] GitLab 18.0+ 신기능: MR에서 Workspace 생성                    │${NC}"
echo -e "${CYAN}│      MR 페이지 > 'Open in Workspace' 버튼                          │${NC}"
echo -e "${CYAN}│                                                                   │${NC}"
echo -e "${CYAN}└─────────────────────────────────────────────────────────────────┘${NC}"
echo ""

# ============================================================
log_step "완료"
# ============================================================
log_success "GitLab 설정 확인 완료!"
log_info "  다음: bash ${SCRIPT_DIR}/05-verify-installation.sh"
