# TFLint configuration. `tflint --init` downloads the AWS ruleset from GitHub
# (set GITHUB_TOKEN in CI to avoid API rate limits).
config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "all"
}

plugin "aws" {
  enabled = true
  version = "0.38.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
