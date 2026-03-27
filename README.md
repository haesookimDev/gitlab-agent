# GitLab Workspaces 설치 가이드

기존 Kubernetes 환경에 설치된 GitLab에서 **Workspaces** 기능을 활성화하기 위한
환경 확인, 설정, 설치 스크립트 모음입니다.

> **대상 버전**: GitLab **18.9** / Kubernetes **1.33+**

## 아키텍처 개요

```
┌─────────────────────────────────────────────────────────────────────┐
│                          Kubernetes Cluster                          │
│                                                                      │
│  ┌─────────────────────┐    ┌──────────────────────────────────┐    │
│  │   gitlab-agent (ns) │    │  GitLab Agent for Kubernetes     │    │
│  │  ┌───────────────┐  │◄───┤  - GitLab 버전과 동일 차트 버전  │    │
│  │  │  agentk pod   │  │    │  - KAS(wss://)로 GitLab에 연결   │    │
│  │  └───────────────┘  │    └──────────────────────────────────┘    │
│  └─────────────────────┘                     ▲                      │
│                                              │ wss://               │
│  ┌─────────────────────────────────┐         │                      │
│  │   gitlab-workspaces (ns)        │  ┌──────┴──────────────────┐  │
│  │                                 │  │  GitLab 18.9 Instance    │  │
│  │  ┌──────────────────────────┐   │  │  (Premium / Ultimate)    │  │
│  │  │  Workspaces Proxy 0.1.25+│◄──┤  │  KAS 활성화 필수         │  │
│  │  │  /auth/callback (신규)   │   │  └─────────────────────────┘  │
│  │  └──────────────────────────┘   │                               │
│  │                                 │  ┌──────────────────────────┐  │
│  │  ┌─────────┐  ┌─────────┐       │  │  cert-manager v1.17+     │  │
│  │  │Workspace│  │Workspace│       │  │  ClusterIssuer (ACME)    │  │
│  │  │   #1    │  │   #2    │       │  └──────────────────────────┘  │
│  │  └─────────┘  └─────────┘       │                               │
│  └─────────────────────────────────┘  ┌──────────────────────────┐  │
│                                       │  ingress-nginx            │  │
│                                       │  *.workspaces.example.com │  │
│                                       └──────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

## 사전 요구사항

| 항목 | 요구사항 | 비고 |
|------|---------|------|
| GitLab 버전 | **18.0 이상** | |
| GitLab 라이선스 | **Premium / Ultimate** | Workspaces 기능 |
| Kubernetes 버전 | **1.33 이상** | GitLab 18.x 지원 범위 |
| Helm 버전 | **3.14 이상** | |
| 기본 StorageClass | **필수** | Workspace PVC 동적 프로비저닝 |
| GitLab KAS | **활성화 필수** | Admin > Settings > Kubernetes |
| CLI 도구 | `kubectl`, `helm`, `curl`, `jq`, `openssl` | |

## 파일 구조

```
gitlab-agent/
├── .env.example                               # 환경 변수 템플릿
├── config/
│   ├── agent-config.yaml                      # GitLab Agent 설정 (remote_development)
│   ├── workspaces-proxy-values.yaml           # Workspaces Proxy Helm Values
│   └── devfile-example.yaml                   # 프로젝트 .devfile.yaml 예제
└── scripts/
    ├── lib/logging.sh                         # 컬러/타임스탬프 공통 로그 유틸리티
    ├── 00-check-prerequisites.sh              # 사전 요구사항 점검
    ├── 01-setup-dependencies.sh               # cert-manager, ingress-nginx 설치
    ├── 02-install-gitlab-agent.sh             # GitLab Agent 설치
    ├── 03-install-workspaces-proxy.sh         # Workspaces Proxy 설치
    ├── 04-configure-gitlab-workspaces.sh      # GitLab 설정 확인
    ├── 05-verify-installation.sh              # 전체 검증
    └── install-all.sh                         # 전체 자동화 실행
```

## 빠른 시작

### 1단계: 환경 변수 설정

```bash
cp .env.example .env
vi .env
```

필수 설정값:

```bash
GITLAB_URL="https://gitlab.example.com"
GITLAB_TOKEN="glpat-xxxxxxxxxxxx"          # Admin 권한 필요
GITLAB_PROJECT_PATH="group/project"
GITLAB_AGENT_NAME="workspaces-agent"
WORKSPACES_DOMAIN="workspaces.example.com"
WORKSPACES_PROXY_DOMAIN="auth.workspaces.example.com"
LETSENCRYPT_EMAIL="admin@example.com"
```

### 2단계: 사전 요구사항 점검

```bash
bash scripts/00-check-prerequisites.sh
```

### 3단계: 전체 자동 설치

```bash
bash scripts/install-all.sh
```

또는 단계별 실행:

```bash
bash scripts/01-setup-dependencies.sh      # cert-manager, ingress-nginx
bash scripts/02-install-gitlab-agent.sh    # GitLab Agent
bash scripts/03-install-workspaces-proxy.sh # Workspaces Proxy
bash scripts/04-configure-gitlab-workspaces.sh # GitLab 설정 확인
bash scripts/05-verify-installation.sh     # 최종 검증
```

특정 단계 건너뛰기 (이미 설치된 경우):

```bash
SKIP_DEPS=true bash scripts/install-all.sh
```

## 주요 컴포넌트 버전 (GitLab 18.9)

| 컴포넌트 | 버전 | 비고 |
|---------|------|------|
| cert-manager | v1.17.2 | Helm chart: jetstack/cert-manager |
| ingress-nginx | 최신 안정 버전 | |
| GitLab Agent | GitLab 버전 자동 매핑 | 스크립트에서 자동 선택 |
| Workspaces Proxy | **0.1.25+** | 0.1.23 미만은 보안 취약점 |

## GitLab 18.0+ 주요 변경사항

### 1. OAuth Redirect URI 변경
```
이전: https://auth.workspaces.example.com/oauth/callback
현재: https://auth.workspaces.example.com/auth/callback
```

### 2. `shared_namespace` 옵션 추가 (agent-config.yaml)
```yaml
remote_development:
  enabled: true
  dns_zone: "workspaces.example.com"
  shared_namespace: "gitlab-workspaces"   # 18.0+ 신규
```

### 3. Workspaces Proxy Helm 저장소 변경
```bash
# 신규 저장소 (별도 GitLab 패키지 레지스트리)
helm repo add gitlab-workspaces-proxy \
  https://gitlab.com/api/v4/projects/gitlab-org%2Fworkspaces%2Fgitlab-workspaces-proxy/packages/helm/devel
```

### 4. MR에서 바로 Workspace 생성
- Merge Request 페이지 → **"Open in Workspace"** 버튼으로 MR 브랜치로 자동 설정된 Workspace 생성

### 5. 기본 devfile 지원
- 프로젝트에 `.devfile.yaml`이 없어도 GitLab 기본 devfile로 Workspace 생성 가능

## GitLab Admin 수동 설정

### KAS 활성화 (Self-hosted)

`gitlab.rb`:
```ruby
gitlab_kas['enable'] = true
gitlab_kas['listen_address'] = '0.0.0.0:8150'
```

### Remote Development 활성화

```
Admin Area > Settings > General > Remote Development > Enable remote development
```

## 에이전트 config.yaml

GitLab 프로젝트에 업로드 필요:

**경로**: `.gitlab/agents/<AGENT_NAME>/config.yaml`

```yaml
remote_development:
  enabled: true
  dns_zone: "workspaces.example.com"
  # GitLab 18.0+: 공유 네임스페이스 (선택)
  # shared_namespace: "gitlab-workspaces"
```

## devfile 명명 규칙 (GitLab Workspaces 제약사항)

| 항목 | 제약 |
|------|------|
| 컴포넌트/커맨드 이름 | `gl-`, `gl_`, `GL-`, `GL_` 로 **시작 불가** |
| postStart 이벤트 이름 | **반드시 `gl-` 로 시작** |
| 환경변수 키 | `gl-`, `gl_`, `GL-`, `GL_` 로 **시작 불가** |
| 지원 컴포넌트 | `container`, `volume` 만 지원 |
| 미지원 | `parent`, `projects`, `starterProjects` |

## Workspace 생성

1. 프로젝트 루트에 `.devfile.yaml` 추가 (`config/devfile-example.yaml` 참고)
2. `https://gitlab.example.com/-/remote_development/workspaces/new` 접속
3. 에이전트 선택 → 프로젝트 선택 → 생성
4. 또는 **MR 페이지 → "Open in Workspace"** (GitLab 18.0+)

## 문제 해결

### 에이전트가 GitLab에 연결되지 않는 경우

```bash
# 에이전트 로그 실시간 확인
kubectl logs -n gitlab-agent -l app=gitlab-agent -f

# KAS 주소 확인
curl -s https://gitlab.example.com/api/v4/metadata | jq '.kas'
```

### TLS 인증서가 발급되지 않는 경우

```bash
kubectl describe certificate -n gitlab-workspaces
kubectl describe clusterissuer letsencrypt-prod
kubectl logs -n cert-manager deployment/cert-manager -f
```

### Workspaces Proxy 오류

```bash
# 로그 확인
kubectl logs -n gitlab-workspaces deployment/gitlab-workspaces-proxy -f

# OAuth redirect_uri 확인
# GitLab Admin > Applications > GitLab Workspaces Proxy
# Redirect URI: https://auth.workspaces.example.com/auth/callback
```

## 설치 로그

모든 스크립트 실행 로그는 `scripts/logs/` 에 타임스탬프로 자동 저장됩니다.

```bash
ls -lt scripts/logs/
```
