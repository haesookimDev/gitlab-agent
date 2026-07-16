export AIGW_IMAGE=my-ai-gateway:18.2.1
export GITLAB_URL=https://gitlab.example.com

docker run -d --name gitlab-aigw \
  --restart unless-stopped \
  -p 5052:5052 -p 50052:50052 \
  \
  -e AIGW_GITLAB_URL=${GITLAB_URL} \
  -e AIGW_GITLAB_API_URL=${GITLAB_URL}/api/v4/ \
  \
  # ── offline license 전용 ──
  -e AIGW_CUSTOMER_PORTAL_URL=${GITLAB_URL} \
  -e DUO_WORKFLOW_AUTH__OIDC_CUSTOMER_PORTAL_URL=${GITLAB_URL} \
  \
  # ── Agent Platform / JWT ──
  -e DUO_WORKFLOW_AUTH__ENABLED=true \
  -e AIGW_SELF_SIGNED_JWT__SIGNING_KEY="$(cat aigw_signing.key)" \
  -e AIGW_SELF_SIGNED_JWT__VALIDATION_KEY="$(cat aigw_validation.key)" \
  -e DUO_WORKFLOW_SELF_SIGNED_JWT__SIGNING_KEY="$(cat duo_workflow_jwt.key)" \
  -e DUO_WORKFLOW_SELF_SIGNED_JWT__VALIDATION_KEY="$(cat duo_workflow_validation.key)" \
  \
  ${AIGW_IMAGE}