# HTTPS for the shared ALB. The lab *uses* a certificate but deliberately
# does not *own* one.
#
# Why: the certificate covers the whole domain, and any domain that hosts
# something besides this lab will have other things using it -- a CloudFront
# distribution, another load balancer. ACM refuses to delete a certificate
# that is in use, so `terraform destroy` stalls with ResourceInUseException
# and the teardown never finishes. The alternative failure is worse: the
# delete succeeds and takes HTTPS down for something that was never part of
# the lab. Certificates are free, so there is nothing to gain by managing
# their lifecycle here.
#
# scripts/setup.sh's preflight guarantees a suitable ISSUED certificate
# exists -- requesting and DNS-validating one the first time, outside
# Terraform -- and passes its ARN in as TF_VAR_acm_certificate_arn. The
# data source below is the fallback for a plain `terraform apply`.

data "aws_acm_certificate" "lab" {
  count = var.acm_certificate_arn == "" ? 1 : 0

  domain      = "*.${var.dns_zone_name}"
  statuses    = ["ISSUED"]
  most_recent = true
}

locals {
  acm_certificate_arn = (
    var.acm_certificate_arn != ""
    ? var.acm_certificate_arn
    : data.aws_acm_certificate.lab[0].arn
  )
}
