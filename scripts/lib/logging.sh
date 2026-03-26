#!/usr/bin/env bash
# ============================================================
# 공통 로깅 유틸리티 라이브러리
# ============================================================

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# 로그 파일 경로 (스크립트 실행 디렉토리 기준)
LOG_DIR="${SCRIPT_DIR:-$(pwd)}/logs"
LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"

# 로그 디렉토리 생성
setup_logging() {
    mkdir -p "${LOG_DIR}"
    echo "로그 파일: ${LOG_FILE}"
    exec > >(tee -a "${LOG_FILE}") 2>&1
}

# 타임스탬프 반환
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# 로그 레벨 함수들
log_info() {
    echo -e "${GREEN}[INFO ]${NC} $(timestamp) $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN ]${NC} $(timestamp) $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(timestamp) $*" >&2
}

log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $(timestamp) $*"
    fi
}

log_step() {
    echo ""
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}▶ $(timestamp) $*${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

log_success() {
    echo -e "${GREEN}${BOLD}✔ $(timestamp) $*${NC}"
}

log_fail() {
    echo -e "${RED}${BOLD}✖ $(timestamp) $*${NC}" >&2
}

log_header() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  $*${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# 명령어 실행 및 로그 출력
run_cmd() {
    local desc="$1"
    shift
    log_info "실행: $*"
    if "$@"; then
        log_success "${desc} 완료"
        return 0
    else
        local exit_code=$?
        log_fail "${desc} 실패 (exit code: ${exit_code})"
        return ${exit_code}
    fi
}

# 명령어 존재 여부 확인
check_command() {
    local cmd="$1"
    if command -v "${cmd}" &>/dev/null; then
        log_info "  ✔ ${cmd} 설치됨 ($(command -v "${cmd}"))"
        return 0
    else
        log_error "  ✖ ${cmd} 미설치"
        return 1
    fi
}

# 대기 함수 (with spinner)
wait_for() {
    local description="$1"
    local timeout="${2:-300}"
    local interval="${3:-10}"
    local elapsed=0
    local spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0

    log_info "${description} 대기 중... (최대 ${timeout}초)"
    while [[ ${elapsed} -lt ${timeout} ]]; do
        if eval "${4}"; then
            log_success "${description} 완료 (${elapsed}초 소요)"
            return 0
        fi
        printf "\r${CYAN}  ${spinner[$i]}${NC} 경과: %ds / 최대: %ds" "${elapsed}" "${timeout}"
        sleep "${interval}"
        elapsed=$((elapsed + interval))
        i=$(( (i + 1) % ${#spinner[@]} ))
    done
    echo ""
    log_fail "${description} 타임아웃 (${timeout}초 초과)"
    return 1
}

# 구분선 출력
divider() {
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
}
