# GitLab Workspaces 설치 가이드

기존 Kubernetes 환경에 설치된 GitLab에서 **Workspaces** 기능을 활성화하기 위한 환경 확인, 설정, 설치 스크립트 모음입니다.

## 아키텍처 개요

```
┌─────────────────────────────────────────────────────────────────┐
│                        Kubernetes Cluster                        │
│                                                                  │
│  ┌──────────────────┐    ┌─────────────────────────────────┐    │
│  │   gitlab-agent   │◄───┤   GitLab Agent for Kubernetes   │    │
│  │   (namespace)    │    │   (KAS: Kubernetes Agent Server) │    │
│  └──────────────────┘    └─────────────────────────────────┘    │
│                                         ▲                        │
│  ┌──────────────────┐                   │ wss://                 │
│  │ gitlab-workspaces│    ┌──────────────┴──────────────────┐    │
│  │   (namespace)    │    │         GitLab Instance          │    │
│  │                  │    │    (gitlab.example.com)          │    │
│  │ ┌──────────────┐ │    └─────────────────────────────────┘    │
│  │ │  Workspaces  │ │                                            │
│  │ │    Proxy     │◄├─── ingress-nginx                          │
│  │ └──────────────┘ │                                            │
│  │                  │    ┌──────────────────────────────────┐   │
│  │ ┌──────────────┐ │    │         cert-manager             │   │
│  │ │  Workspace 1 │ │    │   (TLS 인증서 자동 발급)          │   │
│  │ │  Workspace 2 │ │    └──────────────────────────────────┘   │
│  │ └──────────────┘ │                                            │
│  └──────────────────┘                                            │
└─────────────────────────────────────────────────────────────────┘
```

## 사전 요구사항

| 항목 | 요구사항 |
|------|---------|
| GitLab 버전 | 16.0 이상 |
| GitLab 라이선스 | Premium 또는 Ultimate |
| Kubernetes 버전 | 1.23 이상 |
| 필수 CLI 도구 | `kubectl`, `helm`, `curl`, `jq`, `openssl` |

## 설치 구조

```
gitlab-agent/
├── .env.example              # 환경 변수 템플릿
├── config/
│   ├── agent-config.yaml     # GitLab Agent 설정 (Workspaces 활성화)
│   ├── workspaces-proxy-values.yaml  # Workspaces Proxy Helm Values
│   └── devfile-example.yaml  # 프로젝트 개발 환경 정의 예제
└── scripts/
    ├── lib/
    │   └── logging.sh        # 공통 로깅 유틸리티
    ├── 00-check-prerequisites.sh    # 사전 요구사항 점검
    ├── 01-setup-dependencies.sh     # cert-manager, ingress-nginx 설치
    ├── 02-install-gitlab-agent.sh   # GitLab Agent 설치
    ├── 03-install-workspaces-proxy.sh  # Workspaces Proxy 설치
    ├── 04-configure-gitlab-workspaces.sh  # GitLab 인스턴스 설정
    ├── 05-verify-installation.sh    # 설치 검증
    └── install-all.sh        # 전체 설치 자동화
```

## 설치 방법

### 1단계: 환경 변수 설정

```bash
cp .env.example .env
# .env 파일을 편집하여 실제 값을 입력하세요
vi .env
```

필수 설정값:

```bash
GITLAB_URL="https://gitlab.example.com"      # GitLab URL
GITLAB_TOKEN="glpat-xxxx"                    # Admin 권한 Personal Access Token
GITLAB_PROJECT_PATH="group/project"          # 에이전트를 등록할 프로젝트
GITLAB_AGENT_NAME="workspaces-agent"         # 에이전트 이름
WORKSPACES_DOMAIN="workspaces.example.com"   # Workspaces 도메인
LETSENCRYPT_EMAIL="admin@example.com"        # Let's Encrypt 이메일
```

### 2단계: 사전 요구사항 점검

```bash
bash scripts/00-check-prerequisites.sh
```

점검 항목:
- CLI 도구 설치 여부 (`kubectl`, `helm`, `curl`, `jq`)
- Kubernetes 클러스터 연결 및 버전
- GitLab API 연결 및 버전
- GitLab 라이선스 (Premium/Ultimate)
- GitLab KAS 활성화 여부
- cert-manager, ingress-nginx 기존 설치 여부

### 3단계: 전체 자동 설치

```bash
bash scripts/install-all.sh
```

또는 단계별 실행:

```bash
# 의존성 설치 (cert-manager, ingress-nginx)
bash scripts/01-setup-dependencies.sh

# GitLab Agent 설치
bash scripts/02-install-gitlab-agent.sh

# Workspaces Proxy 설치
bash scripts/03-install-workspaces-proxy.sh

# GitLab 설정 적용
bash scripts/04-configure-gitlab-workspaces.sh

# 설치 검증
bash scripts/05-verify-installation.sh
```

## GitLab Admin 수동 설정

자동화 스크립트 외에 GitLab 관리자 패널에서 다음을 확인하세요:

### KAS (Kubernetes Agent Server) 활성화

```
Admin Area > Settings > Kubernetes > Agent Server > Enable
```

또는 `gitlab.rb` (Self-hosted):
```ruby
gitlab_kas['enable'] = true
gitlab_kas['listen_address'] = '0.0.0.0:8150'
```

### Workspaces 기능 활성화

```
Admin Area > Settings > General > Remote Development > Enable remote development
```

## 에이전트 설정 파일

GitLab 프로젝트에 에이전트 설정 파일을 추가해야 합니다:

**경로**: `.gitlab/agents/<AGENT_NAME>/config.yaml`

```yaml
remote_development:
  enabled: true
  dns_zone: "workspaces.example.com"
  gitlab_url: "https://gitlab.example.com"
```

## Workspace 생성

설치 완료 후 Workspace 생성 방법:

1. GitLab 프로젝트에 `.devfile.yaml` 파일 추가 (`config/devfile-example.yaml` 참고)
2. `https://gitlab.example.com/-/remote_development/workspaces/new` 접속
3. 클러스터 에이전트와 프로젝트 선택
4. Workspace 생성 버튼 클릭

## 문제 해결

### 에이전트가 GitLab에 연결되지 않는 경우

```bash
# 에이전트 로그 확인
kubectl logs -n gitlab-agent -l app=gitlab-agent -f

# KAS 주소 확인
curl -s https://gitlab.example.com/api/v4/metadata | jq '.kas'
```

### TLS 인증서가 발급되지 않는 경우

```bash
# Certificate 상태 확인
kubectl describe certificate -n gitlab-workspaces

# ClusterIssuer 상태 확인
kubectl describe clusterissuer letsencrypt-prod

# cert-manager 로그 확인
kubectl logs -n cert-manager deployment/cert-manager -f
```

### Workspace가 생성되지 않는 경우

```bash
# Workspaces Proxy 로그 확인
kubectl logs -n gitlab-workspaces deployment/gitlab-workspaces-proxy -f

# 에이전트 설정 파일 확인
# GitLab 프로젝트 > .gitlab/agents/<name>/config.yaml
# remote_development.enabled: true 확인
```

## 설치 로그

모든 스크립트 실행 로그는 `scripts/logs/` 디렉토리에 타임스탬프로 저장됩니다.

```bash
ls -la scripts/logs/
```
