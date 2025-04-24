{
  pkgs,
  env,
}:
let
  services = [
    "artifactregistry"
    "certificatemanager"
    "compute"
    "container"
    "dns"
  ];
  serviceResources = builtins.map (service: {
    resource = {
      google_project_service = {
        "${service}" = {
          project = env.project;
          service = "${service}.googleapis.com";
          disable_dependent_services = true;
        };
      };
    };
  }) services;
in
pkgs.writeTextFile {
  name = "project.tf.json";
  text = builtins.toJSON (
    [
      {
        terraform = {
          backend = {
            gcs = {
              bucket = "${env.project}-tofu-state";
              prefix = "project";
            };
          };
          required_providers = {
            google = {
              source = "hashicorp/google";
              version = "6.31.0";
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
        data = {
          google_project = {
            project = {
              project_id = env.project;
            };
          };
        };
      }
      {
        resource = {
          google_project_iam_member = {
            "trampoline_gcs" = {
              project = env.project;
              role = "roles/storage.admin";
              member = "principal://iam.googleapis.com/projects/\${data.google_project.project.number}/locations/global/workloadIdentityPools/${env.project}.svc.id.goog/subject/ns/default/sa/trampoline";
            };
            "trampoline_registry" = {
              project = env.project;
              role = "roles/artifactregistry.admin";
              member = "principal://iam.googleapis.com/projects/\${data.google_project.project.number}/locations/global/workloadIdentityPools/${env.project}.svc.id.goog/subject/ns/default/sa/trampoline";
            };
          };
        };
      }
    ]
    ++ serviceResources
  );
}
