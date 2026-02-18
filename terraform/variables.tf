variable "subscription_id" {
  type = string
  sensitive = true
}

variable "location" {
  type    = string
  default = "EastUS2"
}

variable "gh_repo" {
  type = string
}

variable "FOUNDRY_WORKFLOW_ENDPOINT" {
  type = string
}

variable "FOUNDRY_WORKFLOW_NAME" {
  type = string
}

variable "FOUNDRY_WORKFLOW_VERSION" {
  type = string
}

variable "FOUNDRY_RESOURCE_ID" {
  type = string
}