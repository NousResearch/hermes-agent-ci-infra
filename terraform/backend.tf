# Shared, versioned state. The bucket is bootstrapped once with gcloud because
# Terraform cannot use a backend bucket before that backend exists.
terraform {
  backend "gcs" {
    bucket = "hermes-agent-github-actions-tfstate"
    prefix = "terraform/state"
  }
}
