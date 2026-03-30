#!/bin/bash
set -euo pipefail

# ============================================================
# GitLab AI Gateway - Korean Prompt Patcher
# 용도: AI Gateway 프롬프트에 한국어 응답 지시를 주입/복구
# 사용법:
#   ./patch-korean-prompts.sh patch   [PROMPT_DIR]  - 패치 적용
#   ./patch-korean-prompts.sh restore [PROMPT_DIR]  - 백업에서 복구
#   ./patch-korean-prompts.sh status  [PROMPT_DIR]  - 패치 상태 확인
# ============================================================

# --- 설정 ---
PROMPT_DIR="${2:-/app/ai_gateway/prompts/definitions}"
BACKUP_DIR="${PROMPT_DIR}/.korean-patch-backup"
LOG_PREFIX="[korean-patch]"

# 패치 대상 기능 디렉토리 (필요에 따라 추가/제거)
TARGETS=(
  "merge_request_summary"
  "review_merge_request"
  "explain_code"
  "explain_vulnerability"
  "generate_description"
  "summarize_review"
  "generate_commit_message"
)

# 주입할 한국어 지시문
read -r -d '' KOREAN_BLOCK << 'INSTRUCTION' || true
    # [KOREAN-PATCH-APPLIED]
    Always respond in Korean (한국어).
    Use English only for code, variable names, CLI commands,
    and technical terms that have no standard Korean translation.
INSTRUCTION

# 패치 식별 마커
PATCH_MARKER="# [KOREAN-PATCH-APPLIED]"

# --- 함수 ---

log_info()  { echo "${LOG_PREFIX} [INFO]  $*"; }
log_warn()  { echo "${LOG_PREFIX} [WARN]  $*" >&2; }
log_error() { echo "${LOG_PREFIX} [ERROR] $*" >&2; }

# 백업 생성
do_backup() {
  local src_file="$1"
  local relative_path="${src_file#${PROMPT_DIR}/}"
  local backup_file="${BACKUP_DIR}/${relative_path}"
  local backup_subdir
  backup_subdir="$(dirname "$backup_file")"

  mkdir -p "$backup_subdir"

  # 이미 백업이 있으면 덮어쓰지 않음 (최초 원본 보존)
  if [[ ! -f "$backup_file" ]]; then
    cp -p "$src_file" "$backup_file"
    log_info "백업 생성: ${relative_path}"
  else
    log_info "백업 존재, 유지: ${relative_path}"
  fi
}

# 패치 적용
do_patch() {
  log_info "========== 패치 시작 =========="
  log_info "프롬프트 디렉토리: ${PROMPT_DIR}"
  log_info "백업 디렉토리:     ${BACKUP_DIR}"
  log_info "대상 기능:         ${TARGETS[*]}"
  echo ""

  if [[ ! -d "$PROMPT_DIR" ]]; then
    log_error "프롬프트 디렉토리가 존재하지 않습니다: ${PROMPT_DIR}"
    exit 1
  fi

  local patched=0
  local skipped=0
  local failed=0

  for target in "${TARGETS[@]}"; do
    local target_dir="${PROMPT_DIR}/${target}"

    if [[ ! -d "$target_dir" ]]; then
      log_warn "디렉토리 없음, 건너뜀: ${target}"
      continue
    fi

    while IFS= read -r -d '' yml_file; do
      local relative_path="${yml_file#${PROMPT_DIR}/}"

      # 이미 패치된 파일은 건너뜀 (멱등성)
      if grep -q "${PATCH_MARKER}" "$yml_file" 2>/dev/null; then
        log_info "이미 패치됨, 건너뜀: ${relative_path}"
        ((skipped++))
        continue
      fi

      # system: | 패턴이 없으면 건너뜀
      if ! grep -q "system: |" "$yml_file" 2>/dev/null; then
        log_warn "system 프롬프트 없음, 건너뜀: ${relative_path}"
        ((skipped++))
        continue
      fi

      # 백업 생성
      do_backup "$yml_file"

      # 패치 적용: system: | 다음 줄에 한국어 지시 블록 삽입
      local tmp_file="${yml_file}.tmp"
      if awk -v block="$KOREAN_BLOCK" '
        /system: \|/ {
          print
          print block
          next
        }
        { print }
      ' "$yml_file" > "$tmp_file" && mv "$tmp_file" "$yml_file"; then
        log_info "패치 완료: ${relative_path}"
        ((patched++))
      else
        log_error "패치 실패: ${relative_path}"
        rm -f "$tmp_file"
        ((failed++))
      fi

    done < <(find "$target_dir" -name "*.yml" -type f -print0 2>/dev/null)
  done

  echo ""
  log_info "========== 패치 결과 =========="
  log_info "패치 적용: ${patched}개"
  log_info "건너뜀:    ${skipped}개"
  log_info "실패:      ${failed}개"

  if [[ $failed -gt 0 ]]; then
    return 1
  fi
}

# 백업에서 복구
do_restore() {
  log_info "========== 복구 시작 =========="

  if [[ ! -d "$BACKUP_DIR" ]]; then
    log_error "백업 디렉토리가 없습니다: ${BACKUP_DIR}"
    log_error "패치가 적용된 적이 없거나, 백업이 삭제되었습니다."
    return 1
  fi

  local restored=0
  local failed=0

  while IFS= read -r -d '' backup_file; do
    local relative_path="${backup_file#${BACKUP_DIR}/}"
    local original_file="${PROMPT_DIR}/${relative_path}"
    local original_dir
    original_dir="$(dirname "$original_file")"

    # 원본 디렉토리가 없으면 건너뜀
    if [[ ! -d "$original_dir" ]]; then
      log_warn "원본 디렉토리 없음, 건너뜀: ${relative_path}"
      continue
    fi

    if cp -p "$backup_file" "$original_file"; then
      log_info "복구 완료: ${relative_path}"
      ((restored++))
    else
      log_error "복구 실패: ${relative_path}"
      ((failed++))
    fi

  done < <(find "$BACKUP_DIR" -name "*.yml" -type f -print0 2>/dev/null)

  echo ""
  log_info "========== 복구 결과 =========="
  log_info "복구 완료: ${restored}개"
  log_info "실패:      ${failed}개"

  if [[ $restored -gt 0 && $failed -eq 0 ]]; then
    echo ""
    log_info "백업 디렉토리는 유지됩니다."
    log_info "백업 삭제하려면: rm -rf ${BACKUP_DIR}"
  fi

  if [[ $failed -gt 0 ]]; then
    return 1
  fi
}

# 패치 상태 확인
do_status() {
  log_info "========== 패치 상태 확인 =========="
  log_info "프롬프트 디렉토리: ${PROMPT_DIR}"
  echo ""

  local patched=0
  local unpatched=0
  local missing=0

  for target in "${TARGETS[@]}"; do
    local target_dir="${PROMPT_DIR}/${target}"

    if [[ ! -d "$target_dir" ]]; then
      echo "  [ - ] ${target}/ (디렉토리 없음)"
      ((missing++))
      continue
    fi

    while IFS= read -r -d '' yml_file; do
      local relative_path="${yml_file#${PROMPT_DIR}/}"

      if grep -q "${PATCH_MARKER}" "$yml_file" 2>/dev/null; then
        echo "  [ ✓ ] ${relative_path}"
        ((patched++))
      else
        echo "  [   ] ${relative_path}"
        ((unpatched++))
      fi

    done < <(find "$target_dir" -name "*.yml" -type f -print0 2>/dev/null)
  done

  echo ""
  log_info "--- 요약 ---"
  log_info "패치됨:       ${patched}개"
  log_info "미패치:       ${unpatched}개"
  log_info "디렉토리없음: ${missing}개"

  if [[ -d "$BACKUP_DIR" ]]; then
    local backup_count
    backup_count=$(find "$BACKUP_DIR" -name "*.yml" -type f 2>/dev/null | wc -l)
    log_info "백업 파일:    ${backup_count}개 (${BACKUP_DIR})"
  else
    log_info "백업 없음"
  fi
}

# --- 메인 ---

usage() {
  cat << 'EOF'
GitLab AI Gateway - Korean Prompt Patcher

사용법:
  ./patch-korean-prompts.sh <command> [prompt_dir]

Commands:
  patch    패치 적용 (백업 자동 생성, 멱등성 보장)
  restore  백업에서 원본 복구
  status   현재 패치 상태 확인

Options:
  prompt_dir  프롬프트 디렉토리 경로
              (기본값: /app/ai_gateway/prompts/definitions)

예시:
  ./patch-korean-prompts.sh patch                           # 기본 경로에 패치
  ./patch-korean-prompts.sh patch /custom/path/definitions  # 커스텀 경로
  ./patch-korean-prompts.sh restore                         # 원본으로 복구
  ./patch-korean-prompts.sh status                          # 상태 확인

Kubernetes 환경:
  # ConfigMap으로 등록
  kubectl create configmap korean-patch --from-file=patch-korean-prompts.sh

  # Pod 내부에서 직접 실행
  kubectl exec -it <ai-gateway-pod> -- /scripts/patch-korean-prompts.sh status
  kubectl exec -it <ai-gateway-pod> -- /scripts/patch-korean-prompts.sh patch
  kubectl exec -it <ai-gateway-pod> -- /scripts/patch-korean-prompts.sh restore

대상 기능 수정:
  스크립트 상단의 TARGETS 배열에서 필요한 기능만 남기세요.
EOF
}

COMMAND="${1:-}"

case "$COMMAND" in
  patch)
    do_patch
    ;;
  restore)
    do_restore
    ;;
  status)
    do_status
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac