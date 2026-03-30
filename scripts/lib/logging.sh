#!/usr/bin/env bash
# ============================================================
# 공통 로깅 유틸리티 라이브러리
# GitLab 18.9 기준
# ============================================================

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# 로그 파일 경로
LOG_DIR="${SCRIPT_DIR:-$(pwd)}/logs"
LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"

# 로그 디렉토리 생성 및 tee 설정
setup_logging() {
    mkdir -p "${LOG_DIR}"
    echo "로그 파일: ${LOG_FILE}"
    # stdout/stderr 모두 파일과 터미널에 동시 출력
    exec > >(tee -a "${LOG_FILE}") 2>&1
}

# 타임스탬프
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# 로그 레벨 함수
log_info()  { echo -e "${GREEN}[INFO ]${NC} $(timestamp) $*"; }
log_warn()  { echo -e "${YELLOW}[WARN ]${NC} $(timestamp) $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(timestamp) $*" >&2; }
log_debug() {
    [[ "${DEBUG:-false}" == "true" ]] && \
        echo -e "${CYAN}[DEBUG]${NC} $(timestamp) $*"
}

log_step() {
    echo ""
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}▶ $(timestamp) $*${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

log_success() { echo -e "${GREEN}${BOLD}✔ $(timestamp) $*${NC}"; }
log_fail()    { echo -e "${RED}${BOLD}✖ $(timestamp) $*${NC}" >&2; }

log_header() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    printf "${BOLD}║  %-60s  ║${NC}\n" "$*"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# 명령어 실행 + 결과 로그
run_cmd() {
    local desc="$1"; shift
    log_info "실행: $*"
    if "$@"; then
        log_success "${desc} 완료"
        return 0
    else
        local rc=$?
        log_fail "${desc} 실패 (exit code: ${rc})"
        return ${rc}
    fi
}

# 명령어 존재 여부 확인
check_command() {
    local cmd="$1"
    if command -v "${cmd}" &>/dev/null; then
        local ver
        ver=$(${cmd} version --client 2>/dev/null | head -1 || \
              ${cmd} --version 2>/dev/null | head -1 || echo "버전 확인 불가")
        log_info "  ✔ ${cmd} 설치됨: ${ver}"
        return 0
    else
        log_error "  ✖ ${cmd} 미설치"
        return 1
    fi
}

# 구분선
divider() { echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"; }
