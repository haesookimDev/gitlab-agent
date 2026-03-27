#!/usr/bin/env bash
# ============================================================
# GitLab Workspaces - 전체 설치 오케스트레이션
# 대상: GitLab 18.9 / Kubernetes 1.33+
# ============================================================
# 개별 스크립트 단계를 순서대로 실행합니다.
# 특정 단계를 건너뛰려면 환경 변수로 제어하세요:
#   SKIP_PREREQ=true   사전 점검 건너뜀
#   SKIP_DEPS=true     cert-manager/ingress-nginx 설치 건너뜀
#   SKIP_AGENT=true    GitLab Agent 설치 건너뜀
#   SKIP_PROXY=true    Workspaces Proxy 설치 건너뜀
#   SKIP_CONFIG=true   GitLab 설정 건너뜀
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

source "${SCRIPT_DIR}/lib/logging.sh"
setup_logging

# ============================================================
log_header "GitLab Workspaces 전체 설치 (GitLab 18.9)"
# ============================================================

log_info "설치 단계:"
log_info "  [0] 사전 요구사항 점검"
log_info "  [1] 의존성 설치 (cert-manager v1.17, ingress-nginx, Helm repos)"
log_info "  [2] GitLab Agent for Kubernetes 설치"
log_info "  [3] Workspaces Proxy 설치 (v0.1.25+)"
log_info "  [4] GitLab 인스턴스 설정 확인"
log_info "  [5] 전체 설치 검증"
echo ""

# .env 파일 확인
if [[ ! -f "${ROOT_DIR}/.env" ]]; then
    log_error ".env 파일이 없습니다!"
    log_error "  cp ${ROOT_DIR}/.env.example ${ROOT_DIR}/.env"
    log_error "  vi ${ROOT_DIR}/.env  # 실제 값으로 수정"
    exit 1
fi
source "${ROOT_DIR}/.env"

log_info "설정된 값 확인:"
log_info "  GitLab URL        : ${GITLAB_URL}"
log_info "  프로젝트 경로     : ${GITLAB_PROJECT_PATH}"
log_info "  에이전트 이름     : ${GITLAB_AGENT_NAME}"
log_info "  Workspaces 도메인 : ${WORKSPACES_DOMAIN}"
log_info "  Proxy 도메인      : ${WORKSPACES_PROXY_DOMAIN}"
echo ""

echo -e "${YELLOW}${BOLD}위 설정으로 설치를 진행합니다. 계속하려면 Enter, 취소는 Ctrl+C${NC}"
read -r

# 단계별 실행 플래그
SKIP_PREREQ="${SKIP_PREREQ:-false}"
SKIP_DEPS="${SKIP_DEPS:-false}"
SKIP_AGENT="${SKIP_AGENT:-false}"
SKIP_PROXY="${SKIP_PROXY:-false}"
SKIP_CONFIG="${SKIP_CONFIG:-false}"

START_TIME=$(date +%s)

run_step() {
    local num="$1" name="$2" script="$3" skip="$4"
    if [[ "${skip}" == "true" ]]; then
        log_warn "단계 [${num}] '${name}' 건너뜀 (SKIP 플래그)"
        return 0
    fi
    log_step "단계 [${num}]: ${name}"
    if bash "${script}"; then
        log_success "단계 [${num}] '${name}' 완료"
    else
        log_fail "단계 [${num}] '${name}' 실패"
        log_error "오류를 해결한 후 다음 명령으로 해당 단계부터 재실행:"
        log_error "  bash ${script}"
        exit 1
    fi
    echo ""
    sleep 2
}

run_step "0" "사전 요구사항 점검"         "${SCRIPT_DIR}/00-check-prerequisites.sh"        "${SKIP_PREREQ}"
run_step "1" "의존성 설치"                 "${SCRIPT_DIR}/01-setup-dependencies.sh"         "${SKIP_DEPS}"
run_step "2" "GitLab Agent 설치"           "${SCRIPT_DIR}/02-install-gitlab-agent.sh"       "${SKIP_AGENT}"
run_step "3" "Workspaces Proxy 설치"       "${SCRIPT_DIR}/03-install-workspaces-proxy.sh"   "${SKIP_PROXY}"
run_step "4" "GitLab 설정 확인"            "${SCRIPT_DIR}/04-configure-gitlab-workspaces.sh" "${SKIP_CONFIG}"
run_step "5" "설치 검증"                   "${SCRIPT_DIR}/05-verify-installation.sh"         "false"

END=$(date +%s)
ELAPSED=$(( END - START_TIME ))

echo ""
log_header "전체 설치 완료"
log_success "GitLab Workspaces (GitLab 18.9) 설치 완료!"
log_info "총 소요 시간: $((ELAPSED / 60))분 $((ELAPSED % 60))초"
log_info "로그 파일   : ${LOG_FILE}"
