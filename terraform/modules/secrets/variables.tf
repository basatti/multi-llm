variable "env" {
  type = string
}

variable "secret_names" {
  description = "Secret key -> description. Shells only; values are set out-of-band."
  type        = map(string)
}
