#!/bin/bash
### This script is used to bootstrap the provisioning of AWS resources using OpenTofu and GitHub.
### This bootstrap script does the following:
###### Creates 'starter' environment directory from the sample directory and updates the global.yaml file with the tenant
###### Creates an S3 bucket for storing OpenTofu state files
###### Creates a DynamoDB table for state locking
###### Creates a GitHub OIDC identity provider
###### Creates IAM roles for OpenTofu plan and apply actions
###### Creates GitHub environments for the specified environment
###### Sets GitHub environment and repository-level variables
### Usage: ./bootstrap.sh <ENVIRONMENT>
######################################################################################
set -euo pipefail
# Validate the number of arguments
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <TENANT> <ENVIRONMENT>  [OR] make bootstrap TENANT=<TENANT> ENV=<ENVIRONMENT>"
    echo "<TENANT> = A team or workload for which the AWS Account is used"
    echo "<ENVIRONMENT> = A valid environment such as sbx, dev, tst, stg or prd"
    exit 1
fi

# Validate that the script is being run inside a Git repository
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "Not a git repo"
  exit 1
fi

ORG="contoso"
TENANT="$1"
ENVIRONMENT="$2"
# Set AWS Region
AWS_REGION="us-west-2"
# Set the GitHub username of the required approver
GITHUB_TEAM_SLUG="cloud-and-platform-services"
# Get the repository root directory
REPO_ROOT=$(git rev-parse --show-toplevel)

# Define valid environments
VALID_ENVIRONMENTS=("sbx" "dev" "tst" "stg" "prd")

# Validate environment
if [[ ! " ${VALID_ENVIRONMENTS[@]} " =~ " ${ENVIRONMENT} " ]]; then
    echo "Error: Invalid environment '${ENVIRONMENT}'."
    echo "Valid environments are: ${VALID_ENVIRONMENTS[*]}"
    exit 1
fi
echo "Validated: TENANT=${TENANT}, ENVIRONMENT=${ENVIRONMENT}"

# Create environment directory
SAMPLES_DIR="${REPO_ROOT}/infra/environments/sample"
ENV_DIR="${REPO_ROOT}/infra/environments/${ENVIRONMENT}"
if [[ -d "$ENV_DIR" ]]; then
  echo "Environment '$ENVIRONMENT' already exists at $ENV_DIR"
else
  mkdir -p "$ENV_DIR"
  for file in "$SAMPLES_DIR"/*.sample; do
    cp "$file" "$ENV_DIR/$(basename "$file" .sample)"
  done
fi
echo "Environment directory $ENV_DIR created"

# Update 'tenant' in global.yaml
if grep -q '^tenant:' "${ENV_DIR}/global.yaml"; then
  sed -i "s/^tenant:.*/tenant: \"$TENANT\"/" "${ENV_DIR}/global.yaml"
else
  echo "Missing 'tenant' in ${ENV_DIR}/global.yaml. Exiting..."
  exit 1
fi

# CloudFormation template variables
STATE_BUCKET="${ORG}-s3-${TENANT}-${ENVIRONMENT}-tfstate"
STATE_TABLE="${ORG}-ddbtable-${TENANT}-${ENVIRONMENT}-tfstate"
GITHUB_OIDC_THUMBPRINT=$(openssl s_client -servername token.actions.githubusercontent.com -showcerts -connect token.actions.githubusercontent.com:443 < /dev/null 2>/dev/null \
| openssl x509 -fingerprint -sha1 -noout \
| cut -d= -f2 \
| tr -d ':' \
| tr '[:upper:]' '[:lower:]')
TOFU_PLAN_ROLE_NAME="${ORG}-role-tfplan-${TENANT}-${ENVIRONMENT}"
TOFU_APPLY_ROLE_NAME="${ORG}-role-tfapply-${TENANT}-${ENVIRONMENT}"
# Define variables for setting up GitHub OIDC identity provider and roles
REMOTE_URL=$(git config --get remote.origin.url)
GITHUB_ORG=$(echo "$REMOTE_URL" | sed -E 's|.*github.com[:/]([^/]+)/.*|\1|')
GITHUB_REPO=$(echo "$REMOTE_URL" | sed -E 's|.*/([^/]+)(\.git)?$|\1|' | sed 's|\.git$||')

# Debug Output
cat <<EOF
State Bucket: $STATE_BUCKET
State Table: $STATE_TABLE
GitHub Org: $GITHUB_ORG
GitHub Repo: $GITHUB_REPO
GitHub OIDC Thumbprint: $GITHUB_OIDC_THUMBPRINT
Tofu Plan Role Name: $TOFU_PLAN_ROLE_NAME
Tofu Apply Role Name: $TOFU_APPLY_ROLE_NAME
EOF

echo "Deploying the AWS provisioning cloudformation stack..."
  aws cloudformation deploy \
  --template-file ${REPO_ROOT}/infra-bootstrap/bootstrap-aws-provisioning.yml \
  --stack-name "${ORG}-cf-${TENANT}-${ENVIRONMENT}-tfstate" \
  --parameter-overrides \
  StateBucket="$STATE_BUCKET" \
  StateTable="$STATE_TABLE" \
  GitHubOrganization="$GITHUB_ORG" \
  GitHubRepository="$GITHUB_REPO" \
  GitHubOIDCThumbprint="$GITHUB_OIDC_THUMBPRINT" \
  PlanRoleName="$TOFU_PLAN_ROLE_NAME" \
  ApplyRoleName="$TOFU_APPLY_ROLE_NAME" \
  --capabilities CAPABILITY_NAMED_IAM

# Derived variables
GH_ENVIRONMENT="$ENVIRONMENT"
GH_APPROVAL_ENVIRONMENT="${ENVIRONMENT}-approval"

# Reuse previously extracted values
echo "Retrieving role ARNs from CloudFormation outputs..."
PLAN_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name "${ORG}-cf-${TENANT}-${ENVIRONMENT}-tfstate" \
  --query "Stacks[0].Outputs[?OutputKey=='GitHubActionsPlanRoleArn'].OutputValue" \
  --output text)
echo "Plan Role ARN: $PLAN_ROLE_ARN"

APPLY_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name "${ORG}-cf-${TENANT}-${ENVIRONMENT}-tfstate" \
  --query "Stacks[0].Outputs[?OutputKey=='GitHubActionsApplyRoleArn'].OutputValue" \
  --output text)
echo "Apply Role ARN: $APPLY_ROLE_ARN"

# Create GH environment: <env>
echo "Creating GitHub environment: $GH_ENVIRONMENT"
echo "/repos/${GITHUB_ORG}/${GITHUB_REPO}/environments/${GH_ENVIRONMENT}"
gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "/repos/${GITHUB_ORG}/${GITHUB_REPO}/environments/${GH_ENVIRONMENT}"

# Set variables for <env>
gh variable set ENVIRONMENT --env "$GH_ENVIRONMENT" --repo "$GITHUB_ORG/$GITHUB_REPO" --body "$ENVIRONMENT"
gh variable set AWS_ROLE_TFPLAN --env "$GH_ENVIRONMENT" --repo "$GITHUB_ORG/$GITHUB_REPO" --body "$PLAN_ROLE_ARN"
gh variable set AWS_ROLE_TFAPPLY --env "$GH_ENVIRONMENT" --repo "$GITHUB_ORG/$GITHUB_REPO" --body "$APPLY_ROLE_ARN"

# Grant read permission to the GitHub team for the repository
echo "Granting read permission to the GitHub team: $GITHUB_TEAM_SLUG for repository: $GITHUB_ORG/$GITHUB_REPO"
gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  /orgs/$GITHUB_ORG/teams/$GITHUB_TEAM_SLUG/repos/$GITHUB_ORG/$GITHUB_REPO \
  -f permission=pull

# Create the approval environment
echo "Creating GitHub environment: $GH_APPROVAL_ENVIRONMENT"
GITHUB_TEAM_ID=$(gh api /orgs/$GITHUB_ORG/teams/$GITHUB_TEAM_SLUG --jq '.id')
gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  /repos/$GITHUB_ORG/$GITHUB_REPO/environments/$GH_APPROVAL_ENVIRONMENT \
  --input - <<EOF
{
  "wait_timer": 0,
  "prevent_self_review": false,
  "reviewers": [
    {
      "type": "Team",
      "id": $GITHUB_TEAM_ID
    }
  ]
}
EOF

# Set variables for approval environment
gh variable set ENVIRONMENT --env "$GH_APPROVAL_ENVIRONMENT" --repo "$GITHUB_ORG/$GITHUB_REPO" --body "$ENVIRONMENT"
gh variable set AWS_ROLE_TFPLAN --env "$GH_APPROVAL_ENVIRONMENT" --repo "$GITHUB_ORG/$GITHUB_REPO" --body "$PLAN_ROLE_ARN"
gh variable set AWS_ROLE_TFAPPLY --env "$GH_APPROVAL_ENVIRONMENT" --repo "$GITHUB_ORG/$GITHUB_REPO" --body "$APPLY_ROLE_ARN"

# Set repository-level variable for AWS_DEFAULT_REGION
gh variable set AWS_DEFAULT_REGION --repo "$GITHUB_ORG/$GITHUB_REPO" --body "$AWS_REGION"