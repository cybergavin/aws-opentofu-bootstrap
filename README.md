# AWS OpenTofu Bootstrap

This repository contains a sample **bootstrap process** to initialize AWS accounts for Infrastructure-as-Code (IaC) provisioning using **[OpenTofu](https://opentofu.org/)**, **CloudFormation**, and **GitHub OIDC**.


---

## 🔧 What It Does

- Creates an **S3 bucket** with versioning and encryption for OpenTofu state
- Sets up a **DynamoDB table** for state locking
- Configures **GitHub OIDC** trust for secure, short-lived authentication
- Provisions **IAM roles** for `tofu plan` and `tofu apply` in CI
- Automatically sets up **GitHub environments and variables** for CI workflows

---

## 📁 Repository Structure

```bash
.
├── bootstrap.sh # Wrapper script for executing the bootstrap process
└── bootstrap-aws-provisioning.yml # CloudFormation template that sets up foundational AWS resources
└── README.md        # This README document
```

---

## 📌 Prerequisites

Before running this bootstrap:

- ✅ An **AWS Account** already exists and is accessible
- ✅ You have access to an **SSO-based Administrator role** with full permissions
- ✅ You have both the **AWS CLI** and **GitHub CLI (`gh`)** installed and authenticated
- ✅ The target GitHub repo has already been created.

---

## 🚀 Usage

```bash
./bootstrap.sh <TENANT> <ENVIRONMENT>
Arguments:

TENANT: Logical name for a team or workload (e.g., appx, dataops)

ENVIRONMENT: One of sbx, dev, tst, stg, prd

Example:

```bash
./bootstrap.sh dataops dev
```

The script:

- Uses CloudFormation to:
  - Create the state S3 bucket and DynamoDB table
  - Create GitHub OIDC IAM Identity Provider
  - Create IAM roles
- Uses GitHub CLI to:
  - Create GitHub environments, environment protection rules and variables


🧩 Where This Fits
This is typically the first step in a larger GitOps or platform engineering workflow. Once bootstrapped, teams can start provisioning infrastructure using OpenTofu, backed by GitHub CI/CD pipelines.

📖 Related Blog Post
From Zero to IaC: Bootstrapping AWS Accounts for OpenTofu with CloudFormation & GitHub Actions
