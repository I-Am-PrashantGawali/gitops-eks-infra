#!/usr/bin/env bash
# =============================================================================
# deploy.sh  —  Deploy the full EKS stack in order
#
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh [environment] [region]
#
# Example:
#   ./deploy.sh prod us-east-1
# =============================================================================
set -euo pipefail

ENV="${1:-prod}"
REGION="${2:-us-east-1}"
STACK_PREFIX="${ENV}-eks"

echo "============================================================"
echo " Deploying production EKS infrastructure"
echo " Environment : ${ENV}"
echo " Region      : ${REGION}"
echo "============================================================"

# ── Helper ──────────────────────────────────────────────────────────────────
deploy_stack() {
  local stack_name="$1"
  local template="$2"
  shift 2
  local params=("$@")

  echo ""
  echo "──────────────────────────────────────────────────────────"
  echo " Deploying stack: ${stack_name}"
  echo "──────────────────────────────────────────────────────────"

  aws cloudformation deploy \
    --stack-name "${stack_name}" \
    --template-file "${template}" \
    --parameter-overrides EnvironmentName="${ENV}" "${params[@]}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "${REGION}" \
    --no-fail-on-empty-changeset

  echo " ✓ ${stack_name} deployed"
}

# ── STEP 1: VPC ─────────────────────────────────────────────────────────────
deploy_stack "${STACK_PREFIX}-vpc" "01-vpc.yaml"

# ── STEP 2: IAM (no OIDC yet) ────────────────────────────────────────────────
deploy_stack "${STACK_PREFIX}-iam" "02-iam.yaml"

# ── STEP 3: ECR ──────────────────────────────────────────────────────────────
deploy_stack "${STACK_PREFIX}-ecr" "03-ecr.yaml" \
  "AppName=my-app"

# ── STEP 4: EKS Cluster ───────────────────────────────────────────────────────
# Reuse an existing KMS key alias if present, otherwise create one.
KMS_ALIAS="alias/${ENV}-eks-secrets"
KMS_KEY_ARN=$(aws kms describe-key --key-id "${KMS_ALIAS}" \
  --region "${REGION}" \
  --query 'KeyMetadata.Arn' \
  --output text 2>/dev/null || echo "")

if [ -z "${KMS_KEY_ARN}" ]; then
  KMS_KEY_ARN=$(aws kms create-key \
    --description "${ENV}-eks-secrets-key" \
    --region "${REGION}" \
    --query 'KeyMetadata.Arn' \
    --output text)
  aws kms create-alias \
    --alias-name "${KMS_ALIAS}" \
    --target-key-id "${KMS_KEY_ARN}" \
    --region "${REGION}"
  echo " Created KMS Key: ${KMS_KEY_ARN}"
else
  echo " Reusing KMS Key: ${KMS_KEY_ARN}"
fi

# If the cluster stack is in ROLLBACK_COMPLETE, delete it before re-creating.
CLUSTER_STACK_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_PREFIX}-cluster" \
  --region "${REGION}" \
  --query 'Stacks[0].StackStatus' \
  --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [ "${CLUSTER_STACK_STATUS}" = "ROLLBACK_COMPLETE" ]; then
  echo " Cluster stack is in ROLLBACK_COMPLETE — deleting before re-create..."
  aws cloudformation delete-stack \
    --stack-name "${STACK_PREFIX}-cluster" \
    --region "${REGION}"
  aws cloudformation wait stack-delete-complete \
    --stack-name "${STACK_PREFIX}-cluster" \
    --region "${REGION}"
  echo " Deleted. Proceeding with fresh create."
fi

deploy_stack "${STACK_PREFIX}-cluster" "04-eks-cluster.yaml" \
  "SecretsKMSKeyArn=${KMS_KEY_ARN}"

# ── STEP 5: Node Groups ────────────────────────────────────────────────────
deploy_stack "${STACK_PREFIX}-nodegroups" "05-node-groups.yaml"

# Wait for nodes to register
echo ""
echo " Waiting for nodes to become Ready..."
aws eks update-kubeconfig \
  --name "${ENV}-eks-cluster" \
  --region "${REGION}"

kubectl wait nodes \
  --for=condition=Ready \
  --all \
  --timeout=300s || echo "Some nodes not Ready yet — continuing"

# ── STEP 6: OIDC Provider ──────────── ─────────────────────────────────────
deploy_stack "${STACK_PREFIX}-oidc" "06-oidc-irsa.yaml"

# Retrieve OIDC values
OIDC_ARN=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_PREFIX}-oidc" \
  --region "${REGION}" \
  --query 'Stacks[0].Outputs[?OutputKey==`OIDCProviderArn`].OutputValue' \
  --output text)

OIDC_URL=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_PREFIX}-oidc" \
  --region "${REGION}" \
  --query 'Stacks[0].Outputs[?OutputKey==`OIDCProviderUrl`].OutputValue' \
  --output text)

echo " OIDC ARN : ${OIDC_ARN}"
echo " OIDC URL : ${OIDC_URL}"

# ── STEP 7: Update IAM stack with OIDC (IRSA roles) ───────────────────────
deploy_stack "${STACK_PREFIX}-iam" "02-iam.yaml" \
  "OIDCProviderArn=${OIDC_ARN}" \
  "OIDCProviderUrl=${OIDC_URL}"

# ── STEP 8: ALB Controller config ─────────────────────────────────────────
deploy_stack "${STACK_PREFIX}-alb-config" "07-alb-controller.yaml"

# ── STEP 9: Install ALB Controller via Helm ───────────────────────────────
echo ""
echo " Installing AWS Load Balancer Controller via Helm..."
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update

# Retrieve ALB controller values directly (avoid /tmp Git Bash path issues)
ALB_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_PREFIX}-iam" \
  --region "${REGION}" \
  --query 'Stacks[0].Outputs[?OutputKey==`ALBControllerRoleArn`].OutputValue' \
  --output text)

VPC_ID=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_PREFIX}-vpc" \
  --region "${REGION}" \
  --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' \
  --output text)

echo " ALB Role ARN : ${ALB_ROLE_ARN}"
echo " VPC ID       : ${VPC_ID}"

helm upgrade --install aws-load-balancer-controller \
  eks/aws-load-balancer-controller \
  -n kube-system \
  --version 1.8.1 \
  --set clusterName="${ENV}-eks-cluster" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${ALB_ROLE_ARN}" \
  --set region="${REGION}" \
  --set vpcId="${VPC_ID}" \
  --set replicaCount=2 \
  --set "tolerations[0].key=CriticalAddonsOnly" \
  --set "tolerations[0].operator=Exists" \
  --set "tolerations[0].effect=NoSchedule" \
  --wait

echo ""
echo "============================================================"
echo " ✓ EKS cluster deployment complete!"
echo ""
echo " Cluster : ${ENV}-eks-cluster"
echo " Region  : ${REGION}"
echo ""
echo " Next steps:"
echo "  1. Install Cluster Autoscaler (see README)"
echo "  2. Configure StorageClass for EBS gp3"
echo "  3. Set up Prometheus + Grafana"
echo "  4. Configure RBAC and namespace policies"
echo "============================================================"
