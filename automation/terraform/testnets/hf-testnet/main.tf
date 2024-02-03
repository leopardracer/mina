terraform {
  required_version = ">= 0.14.0"
  backend "s3" {
    key     = "terraform-hf-testnet.tfstate"
    encrypt = true
    region  = "us-west-2"
    bucket  = "o1labs-terraform-state"
    acl     = "bucket-owner-full-control"
  }
}

provider "aws" {
  region = "us-west-2"
}

provider "google" {
  alias   = "google-us-east4"
  project = "o1labs-192920"
  region  = "us-east4"
  zone    = "us-east4-b"
}

provider "google" {
  alias   = "google-us-east1"
  project = "o1labs-192920"
  region  = "us-east1"
  zone    = "us-east1-b"
}

provider "google" {
  alias   = "google-us-central1"
  project = "o1labs-192920"
  region  = "us-central1"
  zone    = "us-central1-c"
}


variable "whale_count" {
  type = number

  description = "Number of online whales for the network to run"
  default     = 0
}

variable "fish_count" {
  type = number

  description = "Number of online fish for the network to run"
  default     = 0
}

variable "seed_count" {
  default = 3
}

locals {
  testnet_name                    = "hf-testnet"
  mina_image                      = "gcr.io/o1labs-192920/mina-daemon:1.4.0-c980ba8-bullseye-mainnet"
  mina_archive_image              = "gcr.io/o1labs-192920/mina-archive:1.4.0-c980ba8-bullseye"
  seed_region                     = "us-east1"
  seed_zone                       = "us-east1-b"
  make_report_discord_webhook_url = ""
  make_report_accounts            = ""
}

module "hf-testnet" {
  providers = { google.gke = google.google-us-east1 }
  source    = "../../modules/o1-testnet"

  artifact_path = abspath(path.module)

  cluster_name   = "coda-infra-east"
  cluster_region = "us-east1"
  k8s_context    = "gke_o1labs-192920_us-east1_coda-infra-east"
  testnet_name   = local.testnet_name

  mina_image                  = local.mina_image
  mina_archive_image          = local.mina_archive_image
  watchdog_image              = "gcr.io/o1labs-192920/watchdog:0.4.12"
  use_embedded_runtime_config = true

  block_producer_key_pass = "naughty blue worm"

  archive_node_count            = 2
  mina_archive_schema           = "create_schema.sql"
  mina_archive_schema_aux_files = ["https://raw.githubusercontent.com/MinaProtocol/mina/46a00e9bd0db591da68326f7b2a8d190660733fc/src/app/archive/create_schema.sql"]

  archive_configs = [
    {
      name              = "archive-1"
      enableLocalDaemon = true
      enablePostgresDB  = true
      postgresHost      = "archive-1-postgresql"
    },
    {
      name              = "archive-2"
      enableLocalDaemon = true
      enablePostgresDB  = true
      postgresHost      = "archive-1-postgresql"
    }
  ]

  log_level           = "Info"
  log_txn_pool_gossip = false

  snark_coordinators = []

  whales = [
    for i in range(var.whale_count) : {
      duplicates = 1
    }
  ]

  fishes = [
    for i in range(var.fish_count) : {
      duplicates = 1
    }
  ]
  seed_count       = var.seed_count
  plain_node_count = 0

  upload_blocks_to_gcloud         = true
  restart_nodes                   = false
  restart_nodes_every_mins        = "60"
  make_reports                    = true
  make_report_every_mins          = "5"
  make_report_discord_webhook_url = local.make_report_discord_webhook_url
  make_report_accounts            = local.make_report_accounts
  seed_peers_url                  = "https://storage.googleapis.com/mina-seed-lists/hf-testnet_seeds.txt"
}

