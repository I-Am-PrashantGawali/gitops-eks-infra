# gitops-eks-infra

EKS infrastructure repo. Contains CloudFormation stacks that build the AWS infrastructure and Kubernetes manifests for cluster add-ons.

```
gitops-eks-infra/
├── deploy.sh                 # Orchestrates all CloudFormation deploys in order
│
├── 01-vpc.yaml               # VPC, subnets, route tables, NAT
├── 02-iam.yaml               # IAM roles (updated with OIDC after step 6)
├── 03-ecr.yaml               # ECR repositories
├── 04-eks-cluster.yaml       # EKS control plane
├── 05-node-groups.yaml       # Managed node groups
├── 06-oidc-irsa.yaml         # OIDC provider for IRSA
├── 07-alb-controller.yaml    # ALB Controller IAM + config
├── 08-secrets-irsa.yaml      # ECR repos for backend/frontend + ESO IRSA role
│
├── post-deploy-k8s/          # ← ArgoCD (eks-infra app) watches this folder
│   ├── 00-storageclass.yaml
│   ├── 01-cluster-autoscaler.yaml
│   ├── 02-namespace-policies.yaml
│   └── 03-example-ingress.yaml
│
└── dns-tls/                  # DNS + TLS setup (manual / separate pipeline)
    ├── 01-route53-hostedzone.yaml
    ├── 02-cert-manager.yaml
    ├── 03-external-dns.yaml
    └── 04-example-app.yaml
```

## Deploy order

CloudFormation stacks must be deployed in numeric order because each stack exports values consumed by the next:

```
01-vpc → 02-iam → 03-ecr → 04-eks-cluster → 05-node-groups
      → 06-oidc-irsa → 02-iam (re-deploy with OIDC) → 07-alb-controller
      → 08-secrets-irsa
```

`deploy.sh` handles this automatically.

## Usage

```bash
# Full deploy (all stacks)
./deploy.sh prod us-east-1

# Individual stack (manual)
aws cloudformation deploy \
  --stack-name prod-eks-vpc \
  --template-file 01-vpc.yaml \
  --parameter-overrides EnvironmentName=prod \
  --region us-east-1
```

## GitHub Actions

`.github/workflows/deploy-eks-stack.yml` runs on push to `main` or manually.

It:
1. Lints all CloudFormation templates with `cfn-lint`.
2. Runs `deploy.sh` for a full infrastructure deploy (re-runs are idempotent).
3. Applies `post-deploy-k8s/` manifests directly (safety net before ArgoCD is running).

Required GitHub Secrets: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`.

## Relationship to ArgoCD

CloudFormation stacks are deployed by this repo's CI — ArgoCD does **not** manage them.

However, ArgoCD (`eks-infra-app.yaml` in `gitops-argocd`) watches `post-deploy-k8s/`
and keeps those Kubernetes manifests in sync after the cluster exists.

Changes to `post-deploy-k8s/`: commit here → ArgoCD syncs automatically.  
Changes to CloudFormation templates: commit here → CI deploys the stack update.
