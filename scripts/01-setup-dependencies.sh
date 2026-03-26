#!/usr/bin/env bash
# ============================================================
# GitLab Workspaces - 의존성 설치 스크립트
# cert-manager 및 ingress-nginx 설치
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
log_header "의존성 설치: cert-manager & ingress-nginx"
# ============================================================

# ============================================================
log_step "1. Helm 저장소 등록"
# ============================================================

log_info "Jetstack (cert-manager) Helm 저장소 추가..."
helm repo add jetstack https://charts.jetstack.io --force-update
log_success "jetstack 저장소 추가 완료"

log_info "ingress-nginx Helm 저장소 추가..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
log_success "ingress-nginx 저장소 추가 완료"

log_info "GitLab Helm 저장소 추가..."
helm repo add gitlab https://charts.gitlab.io --force-update
log_success "gitlab 저장소 추가 완료"

log_info "Helm 저장소 업데이트..."
helm repo update
log_success "Helm 저장소 업데이트 완료"

divider
log_info "사용 가능한 Helm 저장소:"
helm repo list

# ============================================================
log_step "2. cert-manager 설치"
# ============================================================

CERT_MANAGER_NS="cert-manager"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.14.4}"

log_info "cert-manager 네임스페이스 생성..."
kubectl create namespace "${CERT_MANAGER_NS}" --dry-run=client -o yaml | kubectl apply -f -
log_success "네임스페이스 '${CERT_MANAGER_NS}' 준비 완료"

log_info "cert-manager CRD 설치 확인..."
if kubectl get crd certificates.cert-manager.io &>/dev/null; then
    log_warn "cert-manager CRD가 이미 설치되어 있습니다. 업그레이드를 진행합니다."
    CERT_MANAGER_ACTION="upgrade"
else
    log_info "cert-manager CRD를 새로 설치합니다."
    CERT_MANAGER_ACTION="install"
fi

log_info "cert-manager ${CERT_MANAGER_VERSION} ${CERT_MANAGER_ACTION} 시작..."
helm "${CERT_MANAGER_ACTION}" cert-manager jetstack/cert-manager \
    --namespace "${CERT_MANAGER_NS}" \
    --version "${CERT_MANAGER_VERSION}" \
    --set installCRDs=true \
    --set global.leaderElection.namespace="${CERT_MANAGER_NS}" \
    --set prometheus.enabled=false \
    --wait \
    --timeout 5m \
    --debug 2>&1 | grep -E "STATUS|NOTES|deployed|error|Warning" || true

log_info "cert-manager 파드 상태 확인..."
kubectl rollout status deployment/cert-manager -n "${CERT_MANAGER_NS}" --timeout=3m
kubectl rollout status deployment/cert-manager-webhook -n "${CERT_MANAGER_NS}" --timeout=3m
kubectl rollout status deployment/cert-manager-cainjector -n "${CERT_MANAGER_NS}" --timeout=3m

echo ""
kubectl get pods -n "${CERT_MANAGER_NS}" -o wide
log_success "cert-manager 설치 완료"

# ============================================================
log_step "3. ClusterIssuer 생성 (Let's Encrypt)"
# ============================================================

CERT_ISSUER_NAME="${CERT_ISSUER_NAME:-letsencrypt-prod}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL}"

log_info "ClusterIssuer '${CERT_ISSUER_NAME}' 생성..."
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${CERT_ISSUER_NAME}
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${LETSENCRYPT_EMAIL}
    privateKeySecretRef:
      name: ${CERT_ISSUER_NAME}-key
    solvers:
    - http01:
        ingress:
          class: ${INGRESS_CLASS:-nginx}
EOF

log_info "ClusterIssuer (Staging) 'letsencrypt-staging' 생성 (테스트용)..."
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
      name: letsencrypt-staging-key
    solvers:
    - http01:
        ingress:
          class: ${INGRESS_CLASS:-nginx}
EOF

log_info "ClusterIssuer 상태 확인 (Ready 상태까지 최대 60초 대기)..."
sleep 5
kubectl get clusterissuer -o wide
log_success "ClusterIssuer 생성 완료"

# ============================================================
log_step "4. ingress-nginx 설치"
# ============================================================

INGRESS_NS="ingress-nginx"

log_info "ingress-nginx 이미 설치 여부 확인..."
if helm list -n "${INGRESS_NS}" 2>/dev/null | grep -q "ingress-nginx"; then
    log_warn "ingress-nginx가 이미 설치되어 있습니다. 건너뜁니다."
    log_info "기존 ingress-nginx 상태:"
    kubectl get pods -n "${INGRESS_NS}" 2>/dev/null || true
else
    log_info "ingress-nginx 네임스페이스 생성..."
    kubectl create namespace "${INGRESS_NS}" --dry-run=client -o yaml | kubectl apply -f -

    log_info "ingress-nginx 설치 시작..."
    helm install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace "${INGRESS_NS}" \
        --set controller.replicaCount=2 \
        --set controller.ingressClassResource.name="${INGRESS_CLASS:-nginx}" \
        --set controller.ingressClassResource.enabled=true \
        --set controller.ingressClassResource.default=true \
        --set controller.admissionWebhooks.enabled=true \
        --set controller.metrics.enabled=true \
        --wait \
        --timeout 5m

    log_info "ingress-nginx 파드 상태 확인..."
    kubectl rollout status deployment/ingress-nginx-controller -n "${INGRESS_NS}" --timeout=3m

    echo ""
    kubectl get pods -n "${INGRESS_NS}" -o wide
    log_success "ingress-nginx 설치 완료"
fi

log_info "ingress-nginx LoadBalancer 외부 IP 확인..."
echo "(외부 IP 할당까지 최대 2분 소요될 수 있습니다)"
for i in $(seq 1 12); do
    EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n "${INGRESS_NS}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    EXTERNAL_HOSTNAME=$(kubectl get svc ingress-nginx-controller -n "${INGRESS_NS}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

    if [[ -n "${EXTERNAL_IP}" ]]; then
        log_success "LoadBalancer 외부 IP: ${EXTERNAL_IP}"
        break
    elif [[ -n "${EXTERNAL_HOSTNAME}" ]]; then
        log_success "LoadBalancer 외부 Hostname: ${EXTERNAL_HOSTNAME}"
        EXTERNAL_IP="${EXTERNAL_HOSTNAME}"
        break
    else
        log_info "  IP 할당 대기 중... (${i}/12)"
        sleep 10
    fi
done

if [[ -z "${EXTERNAL_IP:-}" ]]; then
    log_warn "LoadBalancer 외부 IP를 할당받지 못했습니다. 온프레미스 환경의 경우:"
    log_warn "  - MetalLB 또는 다른 LoadBalancer 구현체 설치가 필요합니다"
    log_warn "  - NodePort 방식을 사용하는 경우 노드 IP를 사용하세요"
else
    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "DNS 설정 안내:"
    log_info "  *.${WORKSPACES_DOMAIN}  →  ${EXTERNAL_IP}"
    log_info "  ${WORKSPACES_DOMAIN}    →  ${EXTERNAL_IP}"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

# ============================================================
log_step "완료"
# ============================================================
log_success "의존성 설치 완료!"
log_info "다음 단계: bash ${SCRIPT_DIR}/02-install-gitlab-agent.sh"
