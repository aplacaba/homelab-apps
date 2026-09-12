# ── Cloudflare R2: HRIS applicant documents (Active Storage) ────────────────
#
# The bucket is Terraform-managed. Two properties are NOT, because provider
# v5.21 exposes no way to set them (verified against the provider schema):
#
#   * Object versioning — enable it in the R2 dashboard (or the S3 API's
#     PutBucketVersioning) after the bucket exists; there is no versioning
#     attribute on `cloudflare_r2_bucket`.
#   * Noncurrent-version expiry — `cloudflare_r2_bucket_lifecycle` models only
#     object transitions (delete-by-age/date, abort multipart uploads, storage
#     class), so version retention is configured in the dashboard next to
#     versioning, not here.
#
# The one lifecycle rule below is the useful thing this provider *can* express:
# stale multipart uploads (interrupted applicant uploads) are aborted rather
# than billed forever.

resource "cloudflare_r2_bucket" "hris_uploads" {
  account_id = var.cloudflare_account_id
  name       = "tala-hris-uploads"
  # Lowercase per the provider's allowed values ("apac", "eeur", "enam",
  # "weur", "wnam", "oc"); only honoured when the bucket is first created.
  location = "apac"
}

resource "cloudflare_r2_bucket_lifecycle" "hris_uploads" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.hris_uploads.name

  rules = [
    {
      id      = "abort-incomplete-multipart-uploads"
      enabled = true
      conditions = {
        prefix = ""
      }
      abort_multipart_uploads_transition = {
        condition = {
          type    = "Age"
          max_age = 604800 # 7 days
        }
      }
    },
  ]
}
