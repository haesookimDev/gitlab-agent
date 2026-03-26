#!/usr/bin/env bash
# ============================================================
# GitLab Workspaces - 전체 설치 오케스트레이션 스크립트
# ============================================================
# 이 스크립트는 모든 설치 단계를 순서대로 실행합니다.
# 개별 스크립트를 직접 실행하거나 이 스크립트로 전체 설치를
# 자동화할 수 있습니다.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

source "${SCRIPT_DIR}/lib/logging.sh"
setup_logging

# ============================================================
log_header "GitLab Workspaces 전체 설치 시작"
# ============================================================

log_info "설치 단계:"
log_info "  [0] 사전 요구사항 점검"
log_info "  [1] 의존성 설치 (cert-manager, ingress-nginx)"
log_info "  [2] GitLab Agent 설치"
log_info "  [3] Workspaces Proxy 설치"
log_info "  [4] GitLab 설정"
log_info "  [5] 설치 검증"
echo ""

# .env 파일 존재 확인
if [[ ! -f "${ROOT_DIR}/.env" ]]; then
    log_error ".env 파일이 없습니다!"
    log_error "다음 명령으로 .env 파일을 생성하세요:"
    log_error "  cp ${ROOT_DIR}/.env.example ${ROOT_DIR}/.env"
    log_error "  # .env 파일을 편집하여 실제 값을 입력하세요"
    exit 1
fi

# 단계별 실행 여부 플래그
SKIP_PREREQ="${SKIP_PREREQ:-false}"
SKIP_DEPS="${SKIP_DEPS:-false}"
SKIP_AGENT="${SKIP_AGENT:-false}"
SKIP_PROXY="${SKIP_PROXY:-false}"
SKIP_CONFIG="${SKIP_CONFIG:-false}"

START_TIME=$(date +%s)

run_step() {
    local step_num="$1"
    local step_name="$2"
    local script="$3"
    local skip_flag="$4"

    if [[ "${skip_flag}" == "true" ]]; then
        log_warn "단계 ${step_num} '${step_name}' 건너뜀 (SKIP 플래그 설정됨)"
        return 0
    fi

    log_step "단계 ${step_num}: ${step_name}"
    if bash "${script}"; then
        log_success "단계 ${step_num} '${step_name}' 완료"
    else
        log_fail "단계 ${step_num} '${step_name}' 실패"
        log_error "설치를 중단합니다. 오류를 해결한 후 다음 명령으로 재시작하세요:"
        log_error "  bash ${script}"
        exit 1
    fi
    echo ""
    sleep 2
}

# 실행 확인
echo -e "${YELLOW}${BOLD}주의: 이 스크립트는 Kubernetes 클러스터에 여러 컴포넌트를 설치합니다.${NC}"
echo -e "${YELLOW}계속하려면 Enter를 누르고, 취소하려면 Ctrl+C를 누르세요.${NC}"
read -r

# 단계별 실행
run_step "0" "사전 요구사항 점검"   "${SCRIPT_DIR}/00-check-prerequisites.sh"  "${SKIP_PREREQ}"
run_step "1" "의존성 설치"          "${SCRIPT_DIR}/01-setup-dependencies.sh"   "${SKIP_DEPS}"
run_step "2" "GitLab Agent 설치"    "${SCRIPT_DIR}/02-install-gitlab-agent.sh" "${SKIP_AGENT}"
run_step "3" "Workspaces Proxy 설치" "${SCRIPT_DIR}/03-install-workspaces-proxy.sh" "${SKIP_PROXY}"
run_step "4" "GitLab 설정"          "${SCRIPT_DIR}/04-configure-gitlab-workspaces.sh" "${SKIP_CONFIG}"
run_step "5" "설치 검증"            "${SCRIPT_DIR}/05-verify-installation.sh"  "false"

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
log_header "설치 완료"
log_success "GitLab Workspaces 전체 설치 완료!"
log_info "총 소요 시간: $((ELAPSED / 60))분 $((ELAPSED % 60))초"
echo ""
log_info "로그 파일 위치: ${LOG_FILE}"
