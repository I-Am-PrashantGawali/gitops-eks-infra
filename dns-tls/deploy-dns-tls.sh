#!/usr/bin/env bash
# =============================================================================
# deploy-dns-tls.sh  —  Set up Route53 + External DNS + cert-manager + Let's Encrypt
#
# Usage:
#   ./deploy-dns-tls.sh <domain> <email> [environment] [region]
#
# Example:
#   ./deploy-dns-tls.sh example.com admin@example.com prod us-east-1
# =============================================================================
set -euo pipefail

DOMAIN="${1:?Usage: ./deploy-dns-tls.sh <domain> <email> [env] [region]}"
EMAIL="${2:?Usage: ./deploy-dns-tls.sh <domain> <email> [env] [region]}"
ENV="${3:-prod}"
REGION="${4:-us-east-1}"

echo "============================================================"
echo " DNS + TLS Setup"
echo " Domain      : ${DOMAIN}"
echo " Email       : ${EMAIL}"
echo " Environment : ${ENV}"
echo " Region      : ${REGION}"
echo "============================================================"

# ── STEP 1: Get OIDC values from existing stacks ───────────────────────────
OIDC_ARN=$(aws cloudformation describe-stacks \
  --stack-name ${ENV}-eks-oidc --region ${REGION} \
  --query 'Stacks[0].Outputs[?OutputKey==`OIDCProviderArn`].OutputValue' \
  --output text)

OIDC_URL=$(aws cloudformation describe-stacks \
  --stack-name ${ENV}-eks-oidc --region ${REGION} \
  --query 'Stacks[0].Outputs[?OutputKey==`OIDCProviderUrl`].OutputValue' \
  --output text)

echo " OIDC ARN: ${OIDC_ARN}"
echo " OIDC URL: ${OIDC_URL}"

# ── STEP 2: Deploy Route53 hosted zone + IRSA roles ───────────────────────
echo ""
echo "──────────────────────────────────────────────────────────"
echo " Deploying Route53 hosted zone and IRSA roles"
echo "──────────────────────────────────────────────────────────"

aws cloudformation deploy \
  --stack-name ${ENV}-eks-dns \
  --template-file 01-route53-hostedzone.yaml \
  --parameter-overrides \
      EnvironmentName=${ENV} \
      DomainName=${DOMAIN} \
      OIDCProviderArn=${OIDC_ARN} \
      OIDCProviderUrl=${OIDC_URL} \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ${REGION}

# ── STEP 3: Get outputs ────────────────────────────────────────────────────
HOSTED_ZONE_ID=$(aws cloudformation describe-stacks \
  --stack-name ${ENV}-eks-dns --region ${REGION} \
  --query 'Stacks[0].Outputs[?OutputKey==`HostedZoneId`].OutputValue' \
  --output text)

NS_RECORDS=$(aws cloudformation describe-stacks \
  --stack-name ${ENV}-eks-dns --region ${REGION} \
  --query 'Stacks[0].Outputs[?OutputKey==`NameServers`].OutputValue' \
  --output text)

EXTERNAL_DNS_ROLE=$(aws cloudformation describe-stacks \
  --stack-name ${ENV}-eks-dns --region ${REGION} \
  --query 'Stacks[0].Outputs[?OutputKey==`ExternalDNSRoleArn`].OutputValue' \
  --output text)

CERT_MANAGER_ROLE=$(aws cloudformation describe-stacks \
  --stack-name ${ENV}-eks-dns --region ${REGION} \
  --query 'Stacks[0].Outputs[?OutputKey==`CertManagerRoleArn`].OutputValue' \
  --output text)

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ACTION REQUIRED — Update your domain registrar NS       ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Domain        : ${DOMAIN}"
echo "║  Nameservers   : ${NS_RECORDS}"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Go to your registrar (GoDaddy/Namecheap/etc) and       ║"
echo "║  replace the NS records with the above.                  ║"
echo "║  DNS propagation takes 5-30 min. cert-manager DNS-01     ║"
echo "║  challenge will fail until NS records are live.          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
read -p " Press ENTER once you have updated the NS records (or Ctrl+C to pause and do it later)..."

# ── STEP 4: Install cert-manager via Helm ─────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────"
echo " Installing cert-manager"
echo "──────────────────────────────────────────────────────────"

helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo update

kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager \
  --version v1.16.2 \
  --set crds.enabled=true \
  --set serviceAccount.create=false \
  --set serviceAccount.name=cert-manager \
  --wait

echo " ✓ cert-manager installed"

# ── STEP 5: Apply cert-manager ServiceAccount + ClusterIssuers ────────────
echo ""
echo "──────────────────────────────────────────────────────────"
echo " Applying ClusterIssuers (staging + prod)"
echo "──────────────────────────────────────────────────────────"

sed \
  -e "s|REPLACE_CERT_MANAGER_ROLE_ARN|${CERT_MANAGER_ROLE}|g" \
  -e "s|REPLACE_YOUR_EMAIL|${EMAIL}|g" \
  -e "s|REPLACE_REGION|${REGION}|g" \
  -e "s|REPLACE_HOSTED_ZONE_ID|${HOSTED_ZONE_ID}|g" \
  02-cert-manager.yaml | kubectl apply -f -

echo " ✓ ClusterIssuers created"

# ── STEP 6: Install External DNS ──────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────"
echo " Installing External DNS"
echo "──────────────────────────────────────────────────────────"

sed \
  -e "s|REPLACE_EXTERNAL_DNS_ROLE_ARN|${EXTERNAL_DNS_ROLE}|g" \
  -e "s|REPLACE_DOMAIN_NAME|${DOMAIN}|g" \
  -e "s|REPLACE_HOSTED_ZONE_ID|${HOSTED_ZONE_ID}|g" \
  -e "s|REPLACE_REGION|${REGION}|g" \
  03-external-dns.yaml | kubectl apply -f -

echo " ✓ External DNS deployed"

# ── STEP 7: Verify everything is running ──────────────────────────────────
echo ""
echo " Waiting for cert-manager pods..."
kubectl wait pods -n cert-manager --for=condition=Ready --all --timeout=120s

echo " Waiting for external-dns pod..."
kubectl wait pods -n external-dns --for=condition=Ready --all --timeout=60s

echo ""
echo "============================================================"
echo " ✓ DNS + TLS setup complete!"
echo ""
echo " Hosted Zone ID : ${HOSTED_ZONE_ID}"
echo " Domain         : ${DOMAIN}"
echo " Cert Manager   : $(kubectl get pods -n cert-manager --no-headers | wc -l) pods running"
echo " External DNS   : $(kubectl get pods -n external-dns --no-headers | wc -l) pods running"
echo ""
echo " Next: deploy your app"
echo ""
echo "   # Substitute your domain in the example manifest"
echo "   sed 's|REPLACE_DOMAIN_NAME|myapp.${DOMAIN}|g' \\"
echo "     04-example-app.yaml | kubectl apply -f -"
echo ""
echo " Test staging cert first, then switch ClusterIssuer to"
echo " letsencrypt-prod in 04-example-app.yaml."
echo "============================================================"
