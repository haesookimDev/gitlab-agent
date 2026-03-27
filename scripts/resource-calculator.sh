#!/usr/bin/env bash
# ============================================================
# GitLab Workspaces - 리소스 계산기
# 대상: GitLab 18.9 / 최대 5,000 동시 사용자
# ============================================================
# 사용법:
#   bash scripts/resource-calculator.sh              # .env의 CONCURRENT_USERS 사용
#   bash scripts/resource-calculator.sh 500          # 동시 사용자 수 직접 지정
#   bash scripts/resource-calculator.sh 500 --apply  # 계산 후 Kubernetes 리소스 적용
#
# 출력 결과:
#   1. 동시 사용자 수 기반 리소스 계산 테이블
#   2. 권장 Kubernetes 클러스터 구성
#   3. 컴포넌트별 Helm values 파일 (config/resource-tiers/active-tier.yaml)
#   4. ResourceQuota / LimitRange 매니페스트
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

source "${SCRIPT_DIR}/lib/logging.sh"
setup_logging

ENV_FILE="${ROOT_DIR}/.env"
[[ -f "${ENV_FILE}" ]] && source "${ENV_FILE}"

# ============================================================
# 입력 파싱
# ============================================================
CONCURRENT_USERS="${1:-${CONCURRENT_USERS:-100}}"
APPLY_RESOURCES="${2:-}"

# 숫자 검증
if ! [[ "${CONCURRENT_USERS}" =~ ^[0-9]+$ ]] || [[ "${CONCURRENT_USERS}" -lt 1 ]]; then
    log_error "동시 사용자 수는 1 이상의 정수여야 합니다: ${CONCURRENT_USERS}"
    exit 1
fi
if [[ "${CONCURRENT_USERS}" -gt 5000 ]]; then
    log_warn "5,000명 초과 시 멀티 클러스터 구성을 권장합니다."
fi

# ============================================================
# 기준 상수 (GitLab 18.9 공식 기준값)
# ============================================================

# ── Workspace 기본 리소스 (GitLab 공식 기본값) ─────────────
readonly WS_CPU_REQ_M=500        # 500 millicores request
readonly WS_CPU_LIM_M=1000       # 1 core limit (기본)
readonly WS_CPU_MAX_M=2000       # 2 core 최대 허용
readonly WS_MEM_REQ_MI=512       # 512 MiB request
readonly WS_MEM_LIM_MI=1024      # 1 GiB limit (기본)
readonly WS_MEM_MAX_MI=4096      # 4 GiB 최대 허용
readonly WS_STORAGE_GI=10        # 10 GiB PVC per workspace

# ── 노드 규격 정의 ────────────────────────────────────────
# 시스템 오버헤드: CPU 1 core, Memory 4Gi 예약
readonly NODE_SM_CPU=8           # Small node: 8 vCPU
readonly NODE_SM_MEM_GI=32       # Small node: 32 GiB
readonly NODE_MD_CPU=16          # Medium node: 16 vCPU
readonly NODE_MD_MEM_GI=64       # Medium node: 64 GiB
readonly NODE_LG_CPU=32          # Large node: 32 vCPU
readonly NODE_LG_MEM_GI=128      # Large node: 128 GiB
readonly NODE_OVERHEAD_CPU=1     # 시스템 오버헤드
readonly NODE_OVERHEAD_MEM_GI=4  # 시스템 오버헤드
readonly SCALE_BUFFER=120        # 20% 오토스케일 버퍼 (120%)

# ============================================================
# 유틸리티 함수
# ============================================================
ceil_div() {
    # 올림 나눗셈: ceil(a/b)
    local a=$1 b=$2
    echo $(( (a + b - 1) / b ))
}

mib_to_human() {
    local mib=$1
    if   [[ ${mib} -ge $((1024 * 1024)) ]]; then
        echo "$((mib / 1024 / 1024)) TiB"
    elif [[ ${mib} -ge 1024 ]]; then
        echo "$((mib / 1024)) GiB"
    else
        echo "${mib} MiB"
    fi
}

m_to_cores() {
    local m=$1
    if [[ ${m} -ge 1000 ]]; then
        echo "$((m / 1000)) cores"
    else
        echo "${m}m"
    fi
}

# ============================================================
# 1. 워크스페이스 리소스 계산
# ============================================================
compute_workspace_resources() {
    local cu=$1

    WS_TOTAL_CPU_REQ_M=$(( cu * WS_CPU_REQ_M ))
    WS_TOTAL_CPU_LIM_M=$(( cu * WS_CPU_LIM_M ))
    WS_TOTAL_CPU_MAX_M=$(( cu * WS_CPU_MAX_M ))
    WS_TOTAL_MEM_REQ_MI=$(( cu * WS_MEM_REQ_MI ))
    WS_TOTAL_MEM_LIM_MI=$(( cu * WS_MEM_LIM_MI ))
    WS_TOTAL_MEM_MAX_MI=$(( cu * WS_MEM_MAX_MI ))
    WS_TOTAL_STORAGE_GI=$(( cu * WS_STORAGE_GI ))
}

# ============================================================
# 2. GitLab Agent 리소스 계산
# ============================================================
compute_agent_resources() {
    local cu=$1

    # 에이전트는 stateless, 수평 확장 가능
    # 권장 1 replica당 최대 1,000 workspace
    if   [[ ${cu} -le 500  ]]; then
        AGENT_REPLICAS=1
        AGENT_CPU_REQ_M=200
        AGENT_CPU_LIM_M=500
        AGENT_MEM_REQ_MI=256
        AGENT_MEM_LIM_MI=512
    elif [[ ${cu} -le 1000 ]]; then
        AGENT_REPLICAS=2
        AGENT_CPU_REQ_M=300
        AGENT_CPU_LIM_M=1000
        AGENT_MEM_REQ_MI=384
        AGENT_MEM_LIM_MI=768
    elif [[ ${cu} -le 2500 ]]; then
        AGENT_REPLICAS=3
        AGENT_CPU_REQ_M=500
        AGENT_CPU_LIM_M=2000
        AGENT_MEM_REQ_MI=512
        AGENT_MEM_LIM_MI=1024
    else
        AGENT_REPLICAS=5
        AGENT_CPU_REQ_M=1000
        AGENT_CPU_LIM_M=4000
        AGENT_MEM_REQ_MI=1024
        AGENT_MEM_LIM_MI=2048
    fi

    # 전체 합계
    AGENT_TOTAL_CPU_REQ_M=$(( AGENT_REPLICAS * AGENT_CPU_REQ_M ))
    AGENT_TOTAL_CPU_LIM_M=$(( AGENT_REPLICAS * AGENT_CPU_LIM_M ))
    AGENT_TOTAL_MEM_REQ_MI=$(( AGENT_REPLICAS * AGENT_MEM_REQ_MI ))
    AGENT_TOTAL_MEM_LIM_MI=$(( AGENT_REPLICAS * AGENT_MEM_LIM_MI ))

    # workspaces_quota: 에이전트당 최대 워크스페이스 수
    AGENT_WS_QUOTA=$(( (cu + AGENT_REPLICAS - 1) / AGENT_REPLICAS ))
    # workspaces_per_user_quota: 사용자당 최대 워크스페이스 (동시 5개 제한 권장)
    AGENT_WS_PER_USER_QUOTA=5
}

# ============================================================
# 3. Workspaces Proxy 리소스 계산
# ============================================================
compute_proxy_resources() {
    local cu=$1

    # nginx 기준: 50,000 concurrent WebSocket < 1GB, < 1 core
    # proxy 오버헤드: 베이스 200m + concurrent당 0.5m CPU
    #                베이스 256Mi + concurrent당 0.5Mi memory
    if   [[ ${cu} -le 100  ]]; then
        PROXY_REPLICAS=1
        PROXY_CPU_REQ_M=200
        PROXY_CPU_LIM_M=500
        PROXY_MEM_REQ_MI=256
        PROXY_MEM_LIM_MI=512
    elif [[ ${cu} -le 250  ]]; then
        PROXY_REPLICAS=2
        PROXY_CPU_REQ_M=200
        PROXY_CPU_LIM_M=500
        PROXY_MEM_REQ_MI=256
        PROXY_MEM_LIM_MI=512
    elif [[ ${cu} -le 500  ]]; then
        PROXY_REPLICAS=2
        PROXY_CPU_REQ_M=300
        PROXY_CPU_LIM_M=1000
        PROXY_MEM_REQ_MI=384
        PROXY_MEM_LIM_MI=768
    elif [[ ${cu} -le 1000 ]]; then
        PROXY_REPLICAS=3
        PROXY_CPU_REQ_M=500
        PROXY_CPU_LIM_M=1000
        PROXY_MEM_REQ_MI=512
        PROXY_MEM_LIM_MI=1024
    elif [[ ${cu} -le 2500 ]]; then
        PROXY_REPLICAS=5
        PROXY_CPU_REQ_M=600
        PROXY_CPU_LIM_M=2000
        PROXY_MEM_REQ_MI=768
        PROXY_MEM_LIM_MI=1536
    else
        PROXY_REPLICAS=8
        PROXY_CPU_REQ_M=800
        PROXY_CPU_LIM_M=2000
        PROXY_MEM_REQ_MI=1024
        PROXY_MEM_LIM_MI=2048
    fi

    PROXY_TOTAL_CPU_REQ_M=$(( PROXY_REPLICAS * PROXY_CPU_REQ_M ))
    PROXY_TOTAL_CPU_LIM_M=$(( PROXY_REPLICAS * PROXY_CPU_LIM_M ))
    PROXY_TOTAL_MEM_REQ_MI=$(( PROXY_REPLICAS * PROXY_MEM_REQ_MI ))
    PROXY_TOTAL_MEM_LIM_MI=$(( PROXY_REPLICAS * PROXY_MEM_LIM_MI ))
}

# ============================================================
# 4. ingress-nginx 리소스 계산
# ============================================================
compute_ingress_resources() {
    local cu=$1

    # nginx 성능: ~50K WebSocket connections / replica (with <1GB, <1 core)
    # 여기서는 보수적으로 5K connections/replica 기준, 50% 버퍼
    if   [[ ${cu} -le 250  ]]; then
        INGRESS_REPLICAS=2
        INGRESS_CPU_REQ_M=200
        INGRESS_CPU_LIM_M=1000
        INGRESS_MEM_REQ_MI=256
        INGRESS_MEM_LIM_MI=512
    elif [[ ${cu} -le 500  ]]; then
        INGRESS_REPLICAS=2
        INGRESS_CPU_REQ_M=300
        INGRESS_CPU_LIM_M=1000
        INGRESS_MEM_REQ_MI=512
        INGRESS_MEM_LIM_MI=1024
    elif [[ ${cu} -le 1000 ]]; then
        INGRESS_REPLICAS=3
        INGRESS_CPU_REQ_M=400
        INGRESS_CPU_LIM_M=2000
        INGRESS_MEM_REQ_MI=512
        INGRESS_MEM_LIM_MI=1024
    elif [[ ${cu} -le 2500 ]]; then
        INGRESS_REPLICAS=4
        INGRESS_CPU_REQ_M=500
        INGRESS_CPU_LIM_M=2000
        INGRESS_MEM_REQ_MI=512
        INGRESS_MEM_LIM_MI=1024
    else
        INGRESS_REPLICAS=6
        INGRESS_CPU_REQ_M=600
        INGRESS_CPU_LIM_M=2000
        INGRESS_MEM_REQ_MI=1024
        INGRESS_MEM_LIM_MI=2048
    fi

    INGRESS_TOTAL_CPU_REQ_M=$(( INGRESS_REPLICAS * INGRESS_CPU_REQ_M ))
    INGRESS_TOTAL_CPU_LIM_M=$(( INGRESS_REPLICAS * INGRESS_CPU_LIM_M ))
    INGRESS_TOTAL_MEM_REQ_MI=$(( INGRESS_REPLICAS * INGRESS_MEM_REQ_MI ))
    INGRESS_TOTAL_MEM_LIM_MI=$(( INGRESS_REPLICAS * INGRESS_MEM_LIM_MI ))
}

# ============================================================
# 5. cert-manager 리소스 (정적 - 스케일 불필요)
# ============================================================
compute_certmanager_resources() {
    CM_TOTAL_CPU_REQ_M=300    # 3 deployments × 100m
    CM_TOTAL_CPU_LIM_M=600
    CM_TOTAL_MEM_REQ_MI=320   # 128+64+128
    CM_TOTAL_MEM_LIM_MI=640
}

# ============================================================
# 6. 노드 구성 계산
# ============================================================
compute_node_configuration() {
    local cu=$1

    # 노드 타입 선택
    if   [[ ${cu} -le 100  ]]; then
        NODE_CPU="${NODE_SM_CPU}"
        NODE_MEM_GI="${NODE_SM_MEM_GI}"
        NODE_TYPE_LABEL="Small (8 vCPU / 32 GiB)"
        INFRA_NODE_CPU=4
        INFRA_NODE_MEM_GI=16
        INFRA_NODES=2
    elif [[ ${cu} -le 500  ]]; then
        NODE_CPU="${NODE_MD_CPU}"
        NODE_MEM_GI="${NODE_MD_MEM_GI}"
        NODE_TYPE_LABEL="Medium (16 vCPU / 64 GiB)"
        INFRA_NODE_CPU=4
        INFRA_NODE_MEM_GI=16
        INFRA_NODES=3
    else
        NODE_CPU="${NODE_LG_CPU}"
        NODE_MEM_GI="${NODE_LG_MEM_GI}"
        NODE_TYPE_LABEL="Large (32 vCPU / 128 GiB)"
        INFRA_NODE_CPU=8
        INFRA_NODE_MEM_GI=32
        INFRA_NODES=4
    fi

    # 노드당 사용 가능한 리소스 (오버헤드 차감)
    local usable_cpu_m=$(( (NODE_CPU - NODE_OVERHEAD_CPU) * 1000 ))
    local usable_mem_mi=$(( (NODE_MEM_GI - NODE_OVERHEAD_MEM_GI) * 1024 ))

    # 노드당 최대 워크스페이스 수 (CPU, Memory 중 작은 값 기준)
    local ws_by_cpu=$(( usable_cpu_m / WS_CPU_REQ_M ))
    local ws_by_mem=$(( usable_mem_mi / WS_MEM_REQ_MI ))
    WS_PER_NODE=$(( ws_by_cpu < ws_by_mem ? ws_by_cpu : ws_by_mem ))
    WS_PER_NODE_BOTTLENECK=$([ ${ws_by_cpu} -le ${ws_by_mem} ] && echo "CPU" || echo "Memory")

    # 버퍼 포함 워크스페이스 노드 수 계산
    local ws_with_buffer=$(( cu * SCALE_BUFFER / 100 ))
    WS_NODES=$(ceil_div "${ws_with_buffer}" "${WS_PER_NODE}")
    TOTAL_NODES=$(( WS_NODES + INFRA_NODES ))

    # 총 클러스터 리소스
    CLUSTER_TOTAL_CPU=$(( TOTAL_NODES * NODE_CPU ))
    CLUSTER_TOTAL_MEM_GI=$(( TOTAL_NODES * NODE_MEM_GI ))
    CLUSTER_WS_CPU=$(( WS_NODES * NODE_CPU ))
    CLUSTER_WS_MEM_GI=$(( WS_NODES * NODE_MEM_GI ))
}

# ============================================================
# 7. 그랜드 토탈 계산
# ============================================================
compute_grand_total() {
    GRAND_CPU_REQ_M=$(( WS_TOTAL_CPU_REQ_M + AGENT_TOTAL_CPU_REQ_M + \
                        PROXY_TOTAL_CPU_REQ_M + INGRESS_TOTAL_CPU_REQ_M + CM_TOTAL_CPU_REQ_M ))
    GRAND_CPU_LIM_M=$(( WS_TOTAL_CPU_MAX_M + AGENT_TOTAL_CPU_LIM_M + \
                        PROXY_TOTAL_CPU_LIM_M + INGRESS_TOTAL_CPU_LIM_M + CM_TOTAL_CPU_LIM_M ))
    GRAND_MEM_REQ_MI=$(( WS_TOTAL_MEM_REQ_MI + AGENT_TOTAL_MEM_REQ_MI + \
                         PROXY_TOTAL_MEM_REQ_MI + INGRESS_TOTAL_MEM_REQ_MI + CM_TOTAL_MEM_REQ_MI ))
    GRAND_MEM_LIM_MI=$(( WS_TOTAL_MEM_MAX_MI + AGENT_TOTAL_MEM_LIM_MI + \
                         PROXY_TOTAL_MEM_LIM_MI + INGRESS_TOTAL_MEM_LIM_MI + CM_TOTAL_MEM_LIM_MI ))
}

# ============================================================
# 티어 레이블 결정
# ============================================================
get_tier_label() {
    local cu=$1
    if   [[ ${cu} -le 50   ]]; then echo "XS"
    elif [[ ${cu} -le 100  ]]; then echo "S"
    elif [[ ${cu} -le 250  ]]; then echo "M"
    elif [[ ${cu} -le 500  ]]; then echo "L"
    elif [[ ${cu} -le 1000 ]]; then echo "XL"
    elif [[ ${cu} -le 2500 ]]; then echo "2XL"
    else                             echo "3XL"
    fi
}

# ============================================================
# 전체 계산 실행
# ============================================================
log_header "GitLab Workspaces 리소스 계산기 (GitLab 18.9)"
log_info "동시 사용자 수: ${CONCURRENT_USERS}명"

compute_workspace_resources   "${CONCURRENT_USERS}"
compute_agent_resources       "${CONCURRENT_USERS}"
compute_proxy_resources       "${CONCURRENT_USERS}"
compute_ingress_resources     "${CONCURRENT_USERS}"
compute_certmanager_resources
compute_node_configuration    "${CONCURRENT_USERS}"
compute_grand_total

TIER=$(get_tier_label "${CONCURRENT_USERS}")

# ============================================================
# 출력: 리소스 계산 결과 테이블
# ============================================================
log_step "계산 결과: 동시 사용자 ${CONCURRENT_USERS}명 (Tier: ${TIER})"
echo ""

# ── 컴포넌트별 리소스 테이블 ─────────────────────────────
printf "${BOLD}%-30s %10s %10s %12s %12s %8s${NC}\n" \
    "컴포넌트" "CPU Req" "CPU Lim" "Mem Req" "Mem Lim" "Replicas"
divider

# Workspace
printf "%-30s %10s %10s %12s %12s %8s\n" \
    "Workspace (×${CONCURRENT_USERS}개)" \
    "$(m_to_cores ${WS_TOTAL_CPU_REQ_M})" \
    "$(m_to_cores ${WS_TOTAL_CPU_MAX_M})" \
    "$(mib_to_human ${WS_TOTAL_MEM_REQ_MI})" \
    "$(mib_to_human ${WS_TOTAL_MEM_MAX_MI})" \
    "-"

printf "  %-28s %10s %10s %12s %12s %8s\n" \
    "└ 워크스페이스 1개 기준" \
    "$(m_to_cores ${WS_CPU_REQ_M})" \
    "$(m_to_cores ${WS_CPU_MAX_M})" \
    "$(mib_to_human ${WS_MEM_REQ_MI})" \
    "$(mib_to_human ${WS_MEM_MAX_MI})" \
    "-"

divider

# Agent
printf "%-30s %10s %10s %12s %12s %8s\n" \
    "GitLab Agent (합계)" \
    "$(m_to_cores ${AGENT_TOTAL_CPU_REQ_M})" \
    "$(m_to_cores ${AGENT_TOTAL_CPU_LIM_M})" \
    "$(mib_to_human ${AGENT_TOTAL_MEM_REQ_MI})" \
    "$(mib_to_human ${AGENT_TOTAL_MEM_LIM_MI})" \
    "${AGENT_REPLICAS}"

printf "  %-28s %10s %10s %12s %12s %8s\n" \
    "└ 1 replica 기준" \
    "$(m_to_cores ${AGENT_CPU_REQ_M})" \
    "$(m_to_cores ${AGENT_CPU_LIM_M})" \
    "$(mib_to_human ${AGENT_MEM_REQ_MI})" \
    "$(mib_to_human ${AGENT_MEM_LIM_MI})" \
    "-"

# Proxy
printf "%-30s %10s %10s %12s %12s %8s\n" \
    "Workspaces Proxy (합계)" \
    "$(m_to_cores ${PROXY_TOTAL_CPU_REQ_M})" \
    "$(m_to_cores ${PROXY_TOTAL_CPU_LIM_M})" \
    "$(mib_to_human ${PROXY_TOTAL_MEM_REQ_MI})" \
    "$(mib_to_human ${PROXY_TOTAL_MEM_LIM_MI})" \
    "${PROXY_REPLICAS}"

printf "  %-28s %10s %10s %12s %12s %8s\n" \
    "└ 1 replica 기준" \
    "$(m_to_cores ${PROXY_CPU_REQ_M})" \
    "$(m_to_cores ${PROXY_CPU_LIM_M})" \
    "$(mib_to_human ${PROXY_MEM_REQ_MI})" \
    "$(mib_to_human ${PROXY_MEM_LIM_MI})" \
    "-"

# Ingress
printf "%-30s %10s %10s %12s %12s %8s\n" \
    "ingress-nginx (합계)" \
    "$(m_to_cores ${INGRESS_TOTAL_CPU_REQ_M})" \
    "$(m_to_cores ${INGRESS_TOTAL_CPU_LIM_M})" \
    "$(mib_to_human ${INGRESS_TOTAL_MEM_REQ_MI})" \
    "$(mib_to_human ${INGRESS_TOTAL_MEM_LIM_MI})" \
    "${INGRESS_REPLICAS}"

printf "  %-28s %10s %10s %12s %12s %8s\n" \
    "└ 1 replica 기준" \
    "$(m_to_cores ${INGRESS_CPU_REQ_M})" \
    "$(m_to_cores ${INGRESS_CPU_LIM_M})" \
    "$(mib_to_human ${INGRESS_MEM_REQ_MI})" \
    "$(mib_to_human ${INGRESS_MEM_LIM_MI})" \
    "-"

# cert-manager
printf "%-30s %10s %10s %12s %12s %8s\n" \
    "cert-manager (정적)" \
    "$(m_to_cores ${CM_TOTAL_CPU_REQ_M})" \
    "$(m_to_cores ${CM_TOTAL_CPU_LIM_M})" \
    "$(mib_to_human ${CM_TOTAL_MEM_REQ_MI})" \
    "$(mib_to_human ${CM_TOTAL_MEM_LIM_MI})" \
    "3"

divider
printf "${BOLD}%-30s %10s %10s %12s %12s${NC}\n" \
    "★ 전체 합계" \
    "$(m_to_cores ${GRAND_CPU_REQ_M})" \
    "$(m_to_cores ${GRAND_CPU_LIM_M})" \
    "$(mib_to_human ${GRAND_MEM_REQ_MI})" \
    "$(mib_to_human ${GRAND_MEM_LIM_MI})"
printf "%-30s %10s\n" "  스토리지 합계 (PVC)" "${WS_TOTAL_STORAGE_GI} GiB"
divider

# ============================================================
# 출력: 클러스터 노드 구성
# ============================================================
log_step "권장 Kubernetes 클러스터 구성"
echo ""

echo -e "${CYAN}${BOLD}  노드풀 A: 워크스페이스 전용 노드 (taint: workspaces=true)${NC}"
printf "    %-25s %s\n" "노드 타입:"        "${NODE_TYPE_LABEL}"
printf "    %-25s %s\n" "노드 수:"          "${WS_NODES}개 (기본) + 오토스케일 최대 $(( WS_NODES * 2 ))개"
printf "    %-25s %s\n" "노드당 Workspace:" "최대 ${WS_PER_NODE}개 (병목: ${WS_PER_NODE_BOTTLENECK})"
printf "    %-25s %s\n" "오토스케일 버퍼:"  "20% (${SCALE_BUFFER}% 기준 산정)"
echo ""
echo -e "${CYAN}${BOLD}  노드풀 B: 인프라 전용 노드 (system components)${NC}"
printf "    %-25s %s\n" "노드 타입:"  "${INFRA_NODE_CPU} vCPU / ${INFRA_NODE_MEM_GI} GiB"
printf "    %-25s %s\n" "노드 수:"    "${INFRA_NODES}개 (cert-manager, ingress, agent, proxy)"
echo ""
echo -e "${BOLD}  ┌────────────────────────────────────────────────────────────┐${NC}"
printf "${BOLD}  │  전체 클러스터: 워크스페이스 %2d노드 + 인프라 %d노드 = %d노드  │${NC}\n" \
    "${WS_NODES}" "${INFRA_NODES}" "${TOTAL_NODES}"
echo -e "${BOLD}  └────────────────────────────────────────────────────────────┘${NC}"

# ============================================================
# 출력: Agent 쿼터 설정
# ============================================================
log_step "GitLab Agent 쿼터 설정"
echo ""
printf "    %-40s %s\n" "workspaces_quota (에이전트당 최대 WS):"  "${CONCURRENT_USERS}"
printf "    %-40s %s\n" "workspaces_per_user_quota (사용자당):"   "${AGENT_WS_PER_USER_QUOTA}"
printf "    %-40s %s\n" "에이전트 replica 수:"                    "${AGENT_REPLICAS}"

# ============================================================
# 파일 생성: config/resource-tiers/active-tier.yaml
# ============================================================
TIER_DIR="${ROOT_DIR}/config/resource-tiers"
ACTIVE_TIER_FILE="${TIER_DIR}/active-tier.yaml"
mkdir -p "${TIER_DIR}"

log_step "Helm Values 파일 생성: ${ACTIVE_TIER_FILE}"

cat > "${ACTIVE_TIER_FILE}" <<EOF
# ============================================================
# GitLab Workspaces - 리소스 계산 결과
# 동시 사용자: ${CONCURRENT_USERS}명 / Tier: ${TIER}
# 생성 일시: $(date '+%Y-%m-%d %H:%M:%S')
# GitLab 18.9 공식 기준값 적용
# ============================================================

tier: "${TIER}"
concurrent_users: ${CONCURRENT_USERS}

# ────────────────────────────────────────────────────────────
# 1. Workspace 기본/최대 리소스 (agent config.yaml에 적용)
# ────────────────────────────────────────────────────────────
workspace:
  per_workspace:
    default_resources:
      requests:
        cpu: "${WS_CPU_REQ_M}m"
        memory: "${WS_MEM_REQ_MI}Mi"
      limits:
        cpu: "${WS_CPU_LIM_M}m"
        memory: "${WS_MEM_LIM_MI}Mi"
    max_resources:
      requests:
        cpu: "1"
        memory: "1Gi"
      limits:
        cpu: "2"
        memory: "4Gi"
  quotas:
    workspaces_quota: ${CONCURRENT_USERS}
    workspaces_per_user_quota: ${AGENT_WS_PER_USER_QUOTA}
  storage_per_workspace_gi: ${WS_STORAGE_GI}
  total_storage_gi: ${WS_TOTAL_STORAGE_GI}

# ────────────────────────────────────────────────────────────
# 2. GitLab Agent Helm Values
# ────────────────────────────────────────────────────────────
agent:
  replicaCount: ${AGENT_REPLICAS}
  resources:
    requests:
      cpu: "${AGENT_CPU_REQ_M}m"
      memory: "${AGENT_MEM_REQ_MI}Mi"
    limits:
      cpu: "${AGENT_CPU_LIM_M}m"
      memory: "${AGENT_MEM_LIM_MI}Mi"
  # HPA 설정 (에이전트 수평 확장)
  hpa:
    enabled: $([ ${CONCURRENT_USERS} -gt 500 ] && echo "true" || echo "false")
    minReplicas: ${AGENT_REPLICAS}
    maxReplicas: $(( AGENT_REPLICAS * 2 ))
    targetCPUUtilizationPercentage: 70

# ────────────────────────────────────────────────────────────
# 3. Workspaces Proxy Helm Values
# ────────────────────────────────────────────────────────────
proxy:
  replicaCount: ${PROXY_REPLICAS}
  resources:
    requests:
      cpu: "${PROXY_CPU_REQ_M}m"
      memory: "${PROXY_MEM_REQ_MI}Mi"
    limits:
      cpu: "${PROXY_CPU_LIM_M}m"
      memory: "${PROXY_MEM_LIM_MI}Mi"
  hpa:
    enabled: $([ ${CONCURRENT_USERS} -gt 250 ] && echo "true" || echo "false")
    minReplicas: ${PROXY_REPLICAS}
    maxReplicas: $(( PROXY_REPLICAS * 2 ))
    targetCPUUtilizationPercentage: 70

# ────────────────────────────────────────────────────────────
# 4. ingress-nginx Helm Values
# ────────────────────────────────────────────────────────────
ingress_nginx:
  replicaCount: ${INGRESS_REPLICAS}
  resources:
    requests:
      cpu: "${INGRESS_CPU_REQ_M}m"
      memory: "${INGRESS_MEM_REQ_MI}Mi"
    limits:
      cpu: "${INGRESS_CPU_LIM_M}m"
      memory: "${INGRESS_MEM_LIM_MI}Mi"
  hpa:
    enabled: $([ ${CONCURRENT_USERS} -gt 500 ] && echo "true" || echo "false")
    minReplicas: ${INGRESS_REPLICAS}
    maxReplicas: $(( INGRESS_REPLICAS * 2 ))
    targetCPUUtilizationPercentage: 80

# ────────────────────────────────────────────────────────────
# 5. 클러스터 노드 구성
# ────────────────────────────────────────────────────────────
cluster:
  workspace_nodes:
    count: ${WS_NODES}
    type: "${NODE_TYPE_LABEL}"
    cpu_vcpu: ${NODE_CPU}
    memory_gib: ${NODE_MEM_GI}
    max_workspaces_per_node: ${WS_PER_NODE}
    bottleneck: "${WS_PER_NODE_BOTTLENECK}"
    autoscale_max: $(( WS_NODES * 2 ))
  infrastructure_nodes:
    count: ${INFRA_NODES}
    cpu_vcpu: ${INFRA_NODE_CPU}
    memory_gib: ${INFRA_NODE_MEM_GI}
  total_nodes: ${TOTAL_NODES}

# ────────────────────────────────────────────────────────────
# 6. 전체 리소스 합계
# ────────────────────────────────────────────────────────────
grand_total:
  cpu_request: "$(m_to_cores ${GRAND_CPU_REQ_M})"
  cpu_limit: "$(m_to_cores ${GRAND_CPU_LIM_M})"
  memory_request: "$(mib_to_human ${GRAND_MEM_REQ_MI})"
  memory_limit: "$(mib_to_human ${GRAND_MEM_LIM_MI})"
  storage: "${WS_TOTAL_STORAGE_GI} GiB"
EOF

log_success "Tier 파일 생성 완료: ${ACTIVE_TIER_FILE}"

# ============================================================
# 파일 생성: ResourceQuota / LimitRange 매니페스트
# ============================================================
QUOTA_FILE="${TIER_DIR}/k8s-resource-quota-${TIER}.yaml"

cat > "${QUOTA_FILE}" <<EOF
# ============================================================
# Kubernetes ResourceQuota + LimitRange
# GitLab Workspaces 네임스페이스 (Tier: ${TIER}, ${CONCURRENT_USERS} concurrent users)
# ============================================================
---
# ResourceQuota: 전체 네임스페이스 리소스 상한
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gitlab-workspaces-quota
  namespace: "${WORKSPACES_PROXY_NAMESPACE:-gitlab-workspaces}"
  labels:
    app.gitlab.com/component: workspaces
    tier: "${TIER}"
spec:
  hard:
    # CPU: 동시 워크스페이스 × 기본 request
    requests.cpu: "${WS_TOTAL_CPU_REQ_M}m"
    # CPU limit: 동시 워크스페이스 × 최대 limit
    limits.cpu: "${WS_TOTAL_CPU_MAX_M}m"
    # Memory: 동시 워크스페이스 × 기본 request
    requests.memory: "${WS_TOTAL_MEM_REQ_MI}Mi"
    # Memory limit: 동시 워크스페이스 × 최대 limit
    limits.memory: "${WS_TOTAL_MEM_MAX_MI}Mi"
    # PVC 수: 동시 워크스페이스 수
    persistentvolumeclaims: "${CONCURRENT_USERS}"
    # Storage: 동시 워크스페이스 × 10Gi
    requests.storage: "${WS_TOTAL_STORAGE_GI}Gi"
    # Pod 수 (workspace pod + sidecar 고려하여 3배)
    pods: "$(( CONCURRENT_USERS * 3 ))"
---
# LimitRange: 컨테이너별 기본/최대 리소스 (GitLab 18.9 공식 기준)
apiVersion: v1
kind: LimitRange
metadata:
  name: gitlab-workspaces-limitrange
  namespace: "${WORKSPACES_PROXY_NAMESPACE:-gitlab-workspaces}"
  labels:
    app.gitlab.com/component: workspaces
    tier: "${TIER}"
spec:
  limits:
  - type: Container
    # 기본값: devfile에 리소스 미지정 시 자동 적용
    default:
      cpu: "${WS_CPU_LIM_M}m"
      memory: "${WS_MEM_LIM_MI}Mi"
    defaultRequest:
      cpu: "${WS_CPU_REQ_M}m"
      memory: "${WS_MEM_REQ_MI}Mi"
    # GitLab 18.9 최대 허용값 (이 값 이상 설정 불가)
    max:
      cpu: "${WS_CPU_MAX_M}m"
      memory: "${WS_MEM_MAX_MI}Mi"
    # 최소값 (이 값 이하 설정 불가)
    min:
      cpu: "100m"
      memory: "128Mi"
  - type: PersistentVolumeClaim
    max:
      storage: "50Gi"
    min:
      storage: "1Gi"
EOF

log_success "ResourceQuota/LimitRange 생성 완료: ${QUOTA_FILE}"

# ============================================================
# --apply 플래그: Kubernetes에 적용
# ============================================================
if [[ "${APPLY_RESOURCES}" == "--apply" ]]; then
    log_step "Kubernetes 리소스 적용 (--apply 플래그)"
    log_warn "ResourceQuota와 LimitRange를 클러스터에 적용합니다."

    PROXY_NS="${WORKSPACES_PROXY_NAMESPACE:-gitlab-workspaces}"
    kubectl create namespace "${PROXY_NS}" --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f "${QUOTA_FILE}"
    log_success "ResourceQuota / LimitRange 적용 완료"

    log_info "적용된 리소스 확인:"
    kubectl get resourcequota -n "${PROXY_NS}" -o wide
    kubectl get limitrange -n "${PROXY_NS}" -o wide
fi

# ============================================================
# 출력: 설치 스크립트 반영 안내
# ============================================================
log_step "설치 스크립트 적용 방법"
echo ""
log_info "1. .env 파일에 동시 사용자 수 추가:"
log_info "   CONCURRENT_USERS=${CONCURRENT_USERS}"
echo ""
log_info "2. GitLab Agent 설치 시 계산된 값 적용:"
log_info "   bash scripts/02-install-gitlab-agent.sh"
log_info "   (CONCURRENT_USERS 설정 시 리소스 자동 반영)"
echo ""
log_info "3. Workspaces Proxy 설치 시:"
log_info "   bash scripts/03-install-workspaces-proxy.sh"
echo ""
log_info "4. ResourceQuota/LimitRange 적용:"
log_info "   bash scripts/resource-calculator.sh ${CONCURRENT_USERS} --apply"
echo ""
log_info "생성된 파일:"
log_info "  Tier 정의: ${ACTIVE_TIER_FILE}"
log_info "  K8s 매니페스트: ${QUOTA_FILE}"
