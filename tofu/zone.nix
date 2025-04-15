{
  pkgs,
  env,
}:
pkgs.writeTextFile {
  name = "zone.tf.json";
  text = builtins.toJSON ([
    {
      terraform = {
        backend = {
          gcs = {
            bucket = "${env.project}-tofu-state";
            prefix = env.name;
          };
        };
      };
    }
    {
      provider = {
        google = [
          {
            project = env.project;
            region = env.region;
          }
        ];
      };
    }
    {
      resource = {
        google_container_cluster = {
          "cluster" = {
            name = env.name;
            location = env.region;
            deletion_protection = false;
            initial_node_count = 1;
            node_config = {
              disk_size_gb = 10;
            };
            workload_identity_config = {
              workload_pool = "${env.project}.svc.id.goog";
            };
            cluster_autoscaling = {
              enabled = true;
              resource_limits = [
                {
                  resource_type = "cpu";
                  minimum = 0;
                  maximum = 16;
                }
                {
                  resource_type = "memory";
                  minimum = 0;
                  maximum = 64;
                }
              ];
            };
            addons_config = {
              gcs_fuse_csi_driver_config = {
                enabled = true;
              };
            };
          };
        };
      };
    }
    {
      resource = {
        google_artifact_registry_repository = {
          "repository" = {
            repository_id = env.name;
            location = env.region;
            format = "DOCKER";
          };
        };
      };
    }
    {
      resource = {
        google_storage_bucket = {
          "trampoline-cache" = {
            name = "${env.project}-${env.name}-trampoline-cache";
            location = env.region;
            uniform_bucket_level_access = true;
            force_destroy = true;
          };
        };
      };
    }
    {
      resource = {
        google_compute_global_address = {
          "ip" = {
            name = "ingress-${env.region}";
          };
        };
      };
    }
    {
      resource = {
        google_dns_managed_zone = {
          "zone" = {
            name = env.name;
            dns_name = "${env.domain}.";
          };
        };
      };
    }
    {
      resource = {
        google_dns_record_set = {
          "ingress" = {
            name = "${env.domain}.";
            type = "A";
            ttl = 300;
            managed_zone = "\${google_dns_managed_zone.zone.name}";
            rrdatas = [ "\${google_compute_global_address.ip.address}" ];
          };
        };
      };
    }
  ]);
}
