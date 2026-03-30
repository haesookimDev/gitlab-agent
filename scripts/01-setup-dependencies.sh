#!/usr/bin/env bash
# ============================================================
# GitLab Workspaces - 의존성 설치 스크립트
# 대상: GitLab 18.9 / Kubernetes 1.33+
# ============================================================
# 설치 항목:
#   1. Helm 저장소 등록 (jetstack, ingress-nginx, gitlab, workspaces-proxy)
#   2. cert-manager v1.17.x 설치 + ClusterIssuer 생성
#   3. ingress-nginx 설치
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
log_header "의존성 설치: cert-manager & ingress-nginx (GitLab 18.9)"
# ============================================================

# ============================================================
log_step "1. Helm 저장소 등록"
# ============================================================

declare -A HELM_REPOS=(
    ["jetstack"]="https://charts.jetstack.io"
    ["ingress-nginx"]="https://kubernetes.github.io/ingress-nginx"
    ["gitlab"]="https://charts.gitlab.io"
)

for name in "${!HELM_REPOS[@]}"; do
    url="${HELM_REPOS[$name]}"
    log_info "Helm repo 추가: ${name} → ${url}"
    helm repo add "${name}" "${url}" --force-update
    log_success "${name} 저장소 등록 완료"
done

# GitLab Workspaces Proxy 전용 저장소 (gitlab.com 별도 패키지 레지스트리)
PROXY_REPO_URL="https://gitlab.com/api/v4/projects/gitlab-org%2Fworkspaces%2Fgitlab-workspaces-proxy/packages/helm/devel"
log_info "Helm repo 추가: gitlab-workspaces-proxy → ${PROXY_REPO_URL}"
helm repo add gitlab-workspaces-proxy "${PROXY_REPO_URL}" --force-update
log_success "gitlab-workspaces-proxy 저장소 등록 완료"

log_info "Helm 저장소 인덱스 업데이트..."
helm repo update
log_success "Helm 저장소 업데이트 완료"

divider
log_info "등록된 Helm 저장소 목록:"
helm repo list
divider

# ============================================================
log_step "2. cert-manager 설치"
# ============================================================

CERT_MANAGER_NS="cert-manager"
CM_VERSION="${CERT_MANAGER_VERSION:-v1.17.2}"

log_info "cert-manager 네임스페이스 생성 (idempotent)..."
kubectl create namespace "${CERT_MANAGER_NS}" --dry-run=client -o yaml | kubectl apply -f -

# CRD 설치 방식: Helm installCRDs (Kubernetes 1.22+ 기본 방식)
log_info "cert-manager CRD 설치 여부 확인..."
if kubectl get crd certificates.cert-manager.io &>/dev/null; then
    log_info "  기존 CRD 발견 → Helm upgrade 진행"
    HELM_CM_ACTION="upgrade"
else
    log_info "  신규 설치"
    HELM_CM_ACTION="install"
fi

log_info "cert-manager ${CM_VERSION} ${HELM_CM_ACTION} 시작..."
helm "${HELM_CM_ACTION}" cert-manager jetstack/cert-manager \
    --namespace "${CERT_MANAGER_NS}" \
    --version "${CM_VERSION}" \
    --set crds.enabled=true \
    --set global.leaderElection.namespace="${CERT_MANAGER_NS}" \
    --set prometheus.enabled=false \
    --set webhook.timeoutSeconds=30 \
    --wait \
    --timeout 5m \
    2>&1 | grep -E "STATUS|NOTES|deployed|Error|Warning|NAME:" || true

log_info "cert-manager 파드 Rollout 대기..."
for deploy in cert-manager cert-manager-webhook cert-manager-cainjector; do
    log_info "  Rollout 확인: ${deploy}"
    kubectl rollout status deployment/"${deploy}" \
        -n "${CERT_MANAGER_NS}" --timeout=3m
done

echo ""
kubectl get pods -n "${CERT_MANAGER_NS}" -o wide
log_success "cert-manager ${CM_VERSION} 설치 완료"

# ============================================================
log_step "3. ClusterIssuer 생성 (Let's Encrypt)"
# ============================================================

log_info "cert-manager webhook 안정화 대기 (10초)..."
sleep 10

log_info "ClusterIssuer '${CERT_ISSUER_NAME}' (Production) 생성..."
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${CERT_ISSUER_NAME}
  annotations:
    # GitLab Workspaces에서 사용하는 ClusterIssuer
    app.gitlab.com/component: workspaces
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${LETSENCRYPT_EMAIL}
    privateKeySecretRef:
      name: ${CERT_ISSUER_NAME}-acme-key
    solvers:
    - http01:
        ingress:
          ingressClassName: ${INGRESS_CLASS:-nginx}
EOF

log_info "ClusterIssuer 'letsencrypt-staging' (Staging - 테스트용) 생성..."
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${LETSENCRYPT_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging-acme-key
    solvers:
    - http01:
        ingress:
          ingressClassName: ${INGRESS_CLASS:-nginx}
EOF

sleep 5
log_info "ClusterIssuer 상태 확인:"
kubectl get clusterissuer -o wide
log_success "ClusterIssuer 생성 완료"

# ============================================================
log_step "4. ingress-nginx 설치"
# ============================================================

INGRESS_NS="ingress-nginx"

# ── 리소스 계산기로 ingress 리소스 산정 ───────────────────────
CONCURRENT_USERS="${CONCURRENT_USERS:-100}"
source "${SCRIPT_DIR}/resource-calculator.sh" "${CONCURRENT_USERS}" 2>/dev/null || true
# 계산기 미실행 시 기본값
INGRESS_REPLICAS="${INGRESS_REPLICAS:-2}"
INGRESS_CPU_REQ_M="${INGRESS_CPU_REQ_M:-200}"
INGRESS_CPU_LIM_M="${INGRESS_CPU_LIM_M:-1000}"
INGRESS_MEM_REQ_MI="${INGRESS_MEM_REQ_MI:-256}"
INGRESS_MEM_LIM_MI="${INGRESS_MEM_LIM_MI:-512}"
log_info "ingress-nginx 리소스 (동시 사용자: ${CONCURRENT_USERS}명): replicas=${INGRESS_REPLICAS}, CPU=${INGRESS_CPU_REQ_M}m, Mem=${INGRESS_MEM_REQ_MI}Mi"

if helm list -n "${INGRESS_NS}" 2>/dev/null | grep -q "ingress-nginx"; then
    log_warn "ingress-nginx 이미 설치됨 - 건너뜁니다"
    kubectl get pods -n "${INGRESS_NS}" 2>/dev/null || true
else
    log_info "ingress-nginx 네임스페이스 생성..."
    kubectl create namespace "${INGRESS_NS}" --dry-run=client -o yaml | kubectl apply -f -

    log_info "ingress-nginx 설치 시작 (replicas: ${INGRESS_REPLICAS})..."
    helm install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace "${INGRESS_NS}" \
        --set controller.replicaCount="${INGRESS_REPLICAS}" \
        --set controller.ingressClassResource.name="${INGRESS_CLASS:-nginx}" \
        --set controller.ingressClassResource.enabled=true \
        --set controller.ingressClassResource.default=true \
        --set controller.ingressClassResource.controllerValue="k8s.io/ingress-nginx" \
        --set controller.admissionWebhooks.enabled=true \
        --set controller.metrics.enabled=false \
        --set controller.config.proxy-body-size="0" \
        --set controller.config.proxy-read-timeout="3600" \
        --set controller.config.proxy-send-timeout="3600" \
        --set controller.resources.requests.cpu="${INGRESS_CPU_REQ_M}m" \
        --set controller.resources.requests.memory="${INGRESS_MEM_REQ_MI}Mi" \
        --set controller.resources.limits.cpu="${INGRESS_CPU_LIM_M}m" \
        --set controller.resources.limits.memory="${INGRESS_MEM_LIM_MI}Mi" \
        --wait \
        --timeout 5m

    kubectl rollout status deployment/ingress-nginx-controller \
        -n "${INGRESS_NS}" --timeout=3m

    echo ""
    kubectl get pods -n "${INGRESS_NS}" -o wide
    log_success "ingress-nginx 설치 완료"
fi

# LoadBalancer IP 대기
log_info "ingress-nginx LoadBalancer 외부 IP 대기 (최대 120초)..."
for i in $(seq 1 12); do
    LB_IP=$(kubectl get svc ingress-nginx-controller -n "${INGRESS_NS}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    LB_HOST=$(kubectl get svc ingress-nginx-controller -n "${INGRESS_NS}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

    if [[ -n "${LB_IP}" ]]; then
        log_success "LoadBalancer IP: ${LB_IP}"
        break
    elif [[ -n "${LB_HOST}" ]]; then
        LB_IP="${LB_HOST}"
        log_success "LoadBalancer Hostname: ${LB_HOST}"
        break
    fi
    log_info "  IP 대기 중... (${i}/12)"
    sleep 10
done

if [[ -z "${LB_IP:-}" ]]; then
    log_warn "LoadBalancer IP 미할당"
    log_warn "  온프레미스 환경: MetalLB 등 LoadBalancer 구현체 필요"
    log_warn "  클라우드 환경: 클라우드 제공자의 LB가 준비될 때까지 대기 필요"
else
    echo ""
    divider
    log_info "DNS 설정 필요 항목:"
    log_info "  *.${WORKSPACES_DOMAIN}        →  ${LB_IP}"
    log_info "  ${WORKSPACES_PROXY_DOMAIN}    →  ${LB_IP}"
    divider
    # LoadBalancer IP를 파일로 저장 (후속 스크립트에서 참조)
    echo "${LB_IP}" > /tmp/lb-external-ip
fi

# ============================================================
log_step "완료"
# ============================================================
log_success "의존성 설치 완료!"
log_info "  다음: bash ${SCRIPT_DIR}/02-install-gitlab-agent.sh"
