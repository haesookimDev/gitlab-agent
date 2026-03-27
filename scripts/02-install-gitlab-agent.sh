#!/usr/bin/env bash
# ============================================================
# GitLab Workspaces - GitLab Agent for Kubernetes 설치
# 대상: GitLab 18.9
# ============================================================
# 수행 작업:
#   1. GitLab API로 에이전트 등록
#   2. 에이전트 토큰 생성
#   3. 에이전트 config.yaml을 프로젝트 저장소에 업로드
#   4. Helm으로 클러스터에 에이전트 설치
#      (차트 버전을 GitLab 버전과 자동 매핑)
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

CONFIG_DIR="${ROOT_DIR}/config"
AGENT_NS="${GITLAB_AGENT_NAMESPACE}"

# ============================================================
log_header "GitLab Agent for Kubernetes 설치 (GitLab 18.9)"
# ============================================================

# ============================================================
log_step "1. 에이전트 config.yaml 생성"
# ============================================================

RENDERED_CFG="/tmp/agent-config-rendered.yaml"

# ── 리소스 계산기 실행 (CONCURRENT_USERS 기반 자동 산정) ───────
CONCURRENT_USERS="${CONCURRENT_USERS:-100}"
log_info "리소스 계산 기준 동시 사용자 수: ${CONCURRENT_USERS}명"
source "${SCRIPT_DIR}/resource-calculator.sh" "${CONCURRENT_USERS}" 2>/dev/null || true

# active-tier.yaml 로드 (계산기 출력)
TIER_FILE="${ROOT_DIR}/config/resource-tiers/active-tier.yaml"

# shared_namespace 설정
if [[ "${WORKSPACES_SHARED_NAMESPACE:-false}" == "true" ]]; then
    SHARED_NS_VALUE="${WORKSPACES_PROXY_NAMESPACE}"
    SHARED_NS_BLOCK="  # GitLab 18.0+ 공유 네임스페이스 모드
  shared_namespace: \"${SHARED_NS_VALUE}\"
  max_resources_per_workspace: {}"
else
    # 리소스 계산기 값 사용 (없으면 GitLab 18.9 기본값)
    WS_CPU_REQ_M="${WS_CPU_REQ_M:-500}"
    WS_CPU_MAX_M="${WS_CPU_MAX_M:-2000}"
    WS_MEM_REQ_MI="${WS_MEM_REQ_MI:-512}"
    WS_MEM_MAX_MI="${WS_MEM_MAX_MI:-4096}"
    AGENT_WS_QUOTA="${AGENT_WS_QUOTA:-${CONCURRENT_USERS}}"
    AGENT_WS_PER_USER_QUOTA="${AGENT_WS_PER_USER_QUOTA:-5}"

    SHARED_NS_BLOCK="  # Workspace마다 별도 네임스페이스 생성 (기본값)
  # shared_namespace: \"\"   # GitLab 18.0+: 공유 네임스페이스 사용 시 설정"
fi

cat > "${RENDERED_CFG}" <<EOF
# ============================================================
# GitLab Agent for Kubernetes 설정 파일
# GitLab 18.9 / 동시 사용자: ${CONCURRENT_USERS}명
# 생성일: $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

# GitLab CI/CD 파이프라인에서 이 에이전트를 통해 클러스터 접근 허용
ci_access:
  projects:
    - id: ${GITLAB_PROJECT_PATH}

# ============================================================
# Remote Development (Workspaces) 설정 - 필수
# ============================================================
remote_development:
  enabled: true

  # Workspace URL에 사용될 DNS 영역
  dns_zone: "${WORKSPACES_DOMAIN}"

${SHARED_NS_BLOCK}

  # ── 리소스 쿼터 (동시 사용자 ${CONCURRENT_USERS}명 기준) ────────────
  # 에이전트가 허용하는 최대 워크스페이스 수
  workspaces_quota: ${AGENT_WS_QUOTA:-${CONCURRENT_USERS}}
  # 사용자당 최대 워크스페이스 수
  workspaces_per_user_quota: ${AGENT_WS_PER_USER_QUOTA:-5}

  # ── Workspace 기본 리소스 (GitLab 18.9 공식 기본값) ─────────────
  default_resources_per_workspace_container:
    requests:
      cpu: "${WS_CPU_REQ_M:-500}m"
      memory: "${WS_MEM_REQ_MI:-512}Mi"
    limits:
      cpu: "1"
      memory: "1Gi"

  # ── Workspace 최대 허용 리소스 (devfile 상한값) ──────────────
  max_resources_per_workspace:
    requests:
      cpu: "1"
      memory: "1Gi"
    limits:
      cpu: "2"
      memory: "4Gi"

  # 네트워크 정책 (선택사항)
  # network_policy_egress:
  #   - ports:
  #     - port: 443
  #       protocol: TCP
  #     - port: 80
  #       protocol: TCP
EOF

log_info "생성된 에이전트 설정:"
divider
cat "${RENDERED_CFG}"
divider

# ============================================================
log_step "2. GitLab 프로젝트에 에이전트 등록"
# ============================================================

log_info "프로젝트 ID 조회: ${GITLAB_PROJECT_PATH}"
PROJ_ENC=$(echo "${GITLAB_PROJECT_PATH}" | sed 's/\//%2F/g')
PROJ_JSON=$(curl -s "${GITLAB_URL}/api/v4/projects/${PROJ_ENC}" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")
PROJECT_ID=$(echo "${PROJ_JSON}" | jq -r '.id')

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "null" ]]; then
    log_error "프로젝트를 찾을 수 없습니다: ${GITLAB_PROJECT_PATH}"
    exit 1
fi
log_success "프로젝트 ID: ${PROJECT_ID}"

log_info "기존 에이전트 목록..."
EXISTING_AGENTS=$(curl -s \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/cluster_agents" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")
log_info "  등록된 에이전트: $(echo "${EXISTING_AGENTS}" | jq -r '.[].name' 2>/dev/null | tr '\n' ', ' || echo '없음')"

AGENT_ID=$(echo "${EXISTING_AGENTS}" | \
    jq -r ".[] | select(.name == \"${GITLAB_AGENT_NAME}\") | .id" 2>/dev/null || echo "")

if [[ -n "${AGENT_ID}" && "${AGENT_ID}" != "null" ]]; then
    log_warn "에이전트 '${GITLAB_AGENT_NAME}' 이미 등록됨 (ID: ${AGENT_ID}) - 기존 에이전트 재사용"
else
    log_info "에이전트 '${GITLAB_AGENT_NAME}' 신규 등록..."
    CREATE_RESP=$(curl -s -X POST \
        "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/cluster_agents" \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"${GITLAB_AGENT_NAME}\"}")
    AGENT_ID=$(echo "${CREATE_RESP}" | jq -r '.id')
    if [[ -z "${AGENT_ID}" || "${AGENT_ID}" == "null" ]]; then
        log_error "에이전트 등록 실패: $(echo "${CREATE_RESP}" | jq -r '.message // .')"
        exit 1
    fi
    log_success "에이전트 등록 완료 (ID: ${AGENT_ID})"
fi

# ============================================================
log_step "3. 에이전트 토큰 생성"
# ============================================================

TOKEN_NAME="k8s-workspaces-$(date +%Y%m%d%H%M%S)"
log_info "에이전트 토큰 생성: ${TOKEN_NAME}"
TOKEN_RESP=$(curl -s -X POST \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/cluster_agents/${AGENT_ID}/tokens" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${TOKEN_NAME}\"}")

AGENT_TOKEN=$(echo "${TOKEN_RESP}" | jq -r '.token')
if [[ -z "${AGENT_TOKEN}" || "${AGENT_TOKEN}" == "null" ]]; then
    log_error "토큰 생성 실패: $(echo "${TOKEN_RESP}" | jq -r '.message // .')"
    exit 1
fi
log_success "에이전트 토큰 생성 완료"
# 토큰을 임시 파일에 저장 (chmod 600으로 보호)
echo "${AGENT_TOKEN}" > /tmp/gitlab-agent-token
chmod 600 /tmp/gitlab-agent-token

# ============================================================
log_step "4. 에이전트 config.yaml을 저장소에 업로드"
# ============================================================

AGENT_CFG_REPO_PATH=".gitlab/agents/${GITLAB_AGENT_NAME}/config.yaml"
CFG_PATH_ENC=$(echo "${AGENT_CFG_REPO_PATH}" | sed 's/\//%2F/g')

log_info "저장소 기본 브랜치 확인..."
DEFAULT_BRANCH=$(echo "${PROJ_JSON}" | jq -r '.default_branch // "main"')
log_info "  기본 브랜치: ${DEFAULT_BRANCH}"

log_info "기존 config.yaml 존재 여부 확인..."
EXISTING_FILE=$(curl -s \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/repository/files/${CFG_PATH_ENC}?ref=${DEFAULT_BRANCH}" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" | jq -r '.file_name' 2>/dev/null || echo "")

CFG_CONTENT=$(jq -Rs '.' "${RENDERED_CFG}")

if [[ -n "${EXISTING_FILE}" && "${EXISTING_FILE}" != "null" ]]; then
    log_info "기존 config.yaml 업데이트..."
    UPLOAD_RESP=$(curl -s -X PUT \
        "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/repository/files/${CFG_PATH_ENC}" \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"branch\": \"${DEFAULT_BRANCH}\",
            \"content\": ${CFG_CONTENT},
            \"commit_message\": \"chore: update GitLab Agent config for Workspaces (GitLab 18.9)\"
        }")
else
    log_info "config.yaml 신규 생성..."
    UPLOAD_RESP=$(curl -s -X POST \
        "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/repository/files/${CFG_PATH_ENC}" \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"branch\": \"${DEFAULT_BRANCH}\",
            \"content\": ${CFG_CONTENT},
            \"commit_message\": \"feat: add GitLab Agent config with remote_development (GitLab 18.9)\"
        }")
fi

if echo "${UPLOAD_RESP}" | jq -e '.file_path // .branch' &>/dev/null; then
    log_success "config.yaml 업로드 완료: ${AGENT_CFG_REPO_PATH}"
else
    log_warn "config.yaml 자동 업로드 실패 (오류: $(echo "${UPLOAD_RESP}" | jq -r '.message // .'))"
    log_warn "수동으로 파일을 생성하세요:"
    log_warn "  경로: ${AGENT_CFG_REPO_PATH}"
    log_warn "  내용: cat ${RENDERED_CFG}"
fi

# ============================================================
log_step "5. GitLab Agent Helm 설치"
# ============================================================

log_info "에이전트 네임스페이스 생성..."
kubectl create namespace "${AGENT_NS}" --dry-run=client -o yaml | kubectl apply -f -

log_info "에이전트 토큰 Secret 생성..."
kubectl create secret generic gitlab-agent-token \
    --namespace="${AGENT_NS}" \
    --from-literal=token="${AGENT_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -

# KAS 주소 조회
log_info "KAS 주소 조회..."
META_JSON=$(curl -s "${GITLAB_URL}/api/v4/metadata" -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")
KAS_ADDRESS=$(echo "${META_JSON}" | jq -r '.kas.externalUrl' 2>/dev/null || echo "")
KAS_VERSION=$(echo "${META_JSON}" | jq -r '.kas.version' 2>/dev/null || echo "")
if [[ -z "${KAS_ADDRESS}" || "${KAS_ADDRESS}" == "null" ]]; then
    GL_HOST=$(echo "${GITLAB_URL}" | sed 's|https://||;s|http://||')
    KAS_ADDRESS="wss://${GL_HOST}/-/kubernetes-agent"
    log_warn "KAS 주소 자동 감지 실패 → 기본값 사용: ${KAS_ADDRESS}"
else
    log_success "KAS 주소: ${KAS_ADDRESS} (버전: ${KAS_VERSION})"
fi

# GitLab 버전에서 차트 버전 결정
# GitLab 18.9 → 에이전트 차트 버전은 18.9.x 형태
if [[ -z "${GITLAB_AGENT_CHART_VERSION:-}" ]]; then
    GL_MINOR_VER=$(curl -s "${GITLAB_URL}/api/v4/version" \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" | \
        jq -r '.version' 2>/dev/null | cut -d'.' -f1,2 || echo "")

    if [[ -n "${GL_MINOR_VER}" ]]; then
        # 사용 가능한 최신 호환 차트 버전 조회
        AVAILABLE_VERSIONS=$(helm search repo gitlab/gitlab-agent -l \
            --output json 2>/dev/null | \
            jq -r '.[].version' | grep "^${GL_MINOR_VER}\." | head -1 || echo "")

        if [[ -n "${AVAILABLE_VERSIONS}" ]]; then
            GITLAB_AGENT_CHART_VERSION="${AVAILABLE_VERSIONS}"
            log_success "GitLab ${GL_MINOR_VER}.x 호환 차트 버전 자동 선택: ${GITLAB_AGENT_CHART_VERSION}"
        else
            # GitLab 버전과 동일 버전 시도, 없으면 최신 버전
            LATEST_VER=$(helm search repo gitlab/gitlab-agent --output json 2>/dev/null | \
                jq -r '.[0].version' || echo "")
            GITLAB_AGENT_CHART_VERSION="${LATEST_VER:-3.0.0}"
            log_warn "호환 차트 자동 감지 실패 → 최신 버전 사용: ${GITLAB_AGENT_CHART_VERSION}"
        fi
    else
        GITLAB_AGENT_CHART_VERSION="3.0.0"
        log_warn "GitLab 버전 감지 실패 → 기본 차트 버전: ${GITLAB_AGENT_CHART_VERSION}"
    fi
fi

log_info "에이전트 설치 정보:"
log_info "  Namespace   : ${AGENT_NS}"
log_info "  Chart 버전  : ${GITLAB_AGENT_CHART_VERSION}"
log_info "  KAS 주소    : ${KAS_ADDRESS}"
log_info "  Agent 이름  : ${GITLAB_AGENT_NAME}"

if helm list -n "${AGENT_NS}" 2>/dev/null | grep -q "gitlab-agent"; then
    HELM_ACTION="upgrade"
    log_info "기존 릴리즈 발견 → upgrade"
else
    HELM_ACTION="install"
    log_info "신규 설치 → install"
fi

helm "${HELM_ACTION}" gitlab-agent gitlab/gitlab-agent \
    --namespace "${AGENT_NS}" \
    --version "${GITLAB_AGENT_CHART_VERSION}" \
    --set config.token="${AGENT_TOKEN}" \
    --set config.kasAddress="${KAS_ADDRESS}" \
    --set rbac.create=true \
    --set serviceAccount.create=true \
    --set config.observabilityPort=8888 \
    --wait \
    --timeout 5m \
    2>&1 | grep -E "STATUS|NOTES|deployed|Error|Warning|NAME:|LAST DEPLOYED" || true

log_info "에이전트 Rollout 확인..."
kubectl rollout status deployment/gitlab-agent -n "${AGENT_NS}" --timeout=3m

echo ""
log_info "에이전트 파드 상태:"
kubectl get pods -n "${AGENT_NS}" -o wide

echo ""
log_info "에이전트 초기 로그 (최근 30줄):"
divider
sleep 5
kubectl logs -n "${AGENT_NS}" -l app=gitlab-agent --tail=30 2>/dev/null || true
divider

# ============================================================
log_step "6. GitLab에서 에이전트 연결 확인"
# ============================================================

log_info "KAS 연결 대기 (20초)..."
sleep 20

AGENT_INFO=$(curl -s \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/cluster_agents/${AGENT_ID}" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")
log_info "에이전트 정보:"
echo "${AGENT_INFO}" | jq '{id: .id, name: .name, created_at: .created_at}' 2>/dev/null || true

# ============================================================
log_step "완료"
# ============================================================
log_success "GitLab Agent 설치 완료!"
echo ""
log_info "GitLab 에이전트 확인:"
log_info "  ${GITLAB_URL}/${GITLAB_PROJECT_PATH}/-/clusters/agents"
log_info ""
log_info "  다음: bash ${SCRIPT_DIR}/03-install-workspaces-proxy.sh"
