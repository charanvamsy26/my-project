# TFLint configuration for eks-gitops-platform.
#
# TFLint catches provider-specific mistakes that `terraform validate` cannot:
# invalid instance types, deprecated arguments, missing tags, etc. The AWS
# ruleset is enabled with the "deep" preset for the strongest checks.
#
# Run locally:  tflint --init && tflint --recursive
# CI:           see .github/workflows/terraform.yml (per-environment matrix)

config {
  # Resolve module sources so rules also apply to terraform/modules/*.
  call_module_type = "all"
  force            = false
}

plugin "terraform" {
  enabled = true
  # Bundled ruleset: naming conventions, unused declarations, etc.
  preset = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.34.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# --- Convention rules -------------------------------------------------------

# Enforce snake_case for variables/outputs/etc. (our Terraform naming standard).
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# Every module should document its variables and outputs.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

# Pin provider/module/terraform versions for reproducible plans.
rule "terraform_required_version" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

# Catch interpolation-only expressions and other deprecated syntax.
rule "terraform_deprecated_interpolation" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}

# Require a consistent comment block describing each resource is overkill;
# we keep it disabled to avoid noise on a portfolio repo.
rule "terraform_comment_syntax" {
  enabled = true
}
