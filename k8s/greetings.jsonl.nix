{
  pkgs,
  env,
  mkRepository,
  rev,
}:
let
  name = "greetings";
  cacheReadUrl = "file:///cache?trusted=1";
  cacheWriteUrl = "file:///cache?compression=none";
  resources = [
    (
      if env.kind == "gcloud" then
        {
          apiVersion = "networking.gke.io/v1";
          kind = "ManagedCertificate";
          metadata = {
            name = "managed-cert";
          };
          spec = {
            domains = [ env.domain ];
          };
        }
      else
        null
    )
    (
      if env.kind == "gcloud" then
        {
          apiVersion = "cloud.google.com/v1";
          kind = "BackendConfig";
          metadata = {
            name = name;
          };
          spec = {
            healthCheck = {
              checkIntervalSec = 2;
              timeoutSec = 1;
              healthyThreshold = 2;
              unhealthyThreshold = 3;
              type = "HTTP";
              requestPath = "/healthz";
              port = 8080;
            };
          };
        }
      else
        null
    )
    {
      apiVersion = "apps/v1";
      kind = "Deployment";
      metadata = {
        name = name;
      };
      spec = {
        replicas = 3;
        strategy = {
          type = "RollingUpdate";
          rollingUpdate = {
            maxUnavailable = 0;
            maxSurge = "100%";
          };
        };
        selector = {
          matchLabels = {
            app = name;
          };
        };
        template = {
          metadata = {
            labels = {
              app = name;
            };
          };
          spec = {
            nodeSelector = {
              "kubernetes.io/arch" = if env.system == "aarch64-linux" then "arm64" else "amd64";
            };
            containers = [
              {
                name = name;
                image = "${mkRepository env name}:${rev}";
                ports = [
                  {
                    containerPort = 8080;
                  }
                ];
                readinessProbe = {
                  httpGet = {
                    path = "/healthz";
                    port = 8080;
                  };
                  initialDelaySeconds = 1;
                  periodSeconds = 1;
                  timeoutSeconds = 1;
                  successThreshold = 1;
                  failureThreshold = 1;
                };
              }
            ];
          };
        };
      };
    }
    {
      apiVersion = "v1";
      kind = "Service";
      metadata = {
        name = name;
        annotations =
          if env.kind == "gcloud" then
            {
              "cloud.google.com/backend-config" = pkgs.lib.generators.toJSON { } { default = name; };
            }
          else
            { };
      };
      spec = {
        ports = [
          {
            port = 8080;
          }
        ];
        selector = {
          app = name;
        };
      };
    }
    {
      apiVersion = "networking.k8s.io/v1";
      kind = "Ingress";
      metadata = {
        name = name;
        annotations =
          if env.kind == "gcloud" then
            {
              "kubernetes.io/ingress.class" = "gce";
              "networking.gke.io/managed-certificates" = "managed-cert";
              "kubernetes.io/ingress.global-static-ip-name" = "ingress-${env.region}";
            }
          else
            { };
      };
      spec = {
        ingressClassName = if env.kind == "minikube" then "nginx" else null;
        defaultBackend = {
          service = {
            name = name;
            port = {
              number = 8080;
            };
          };
        };
      };
    }
    {
      apiVersion = "policy/v1";
      kind = "PodDisruptionBudget";
      metadata = {
        name = name;
      };
      spec = {
        minAvailable = 2;
        selector = {
          matchLabels = {
            app = name;
          };
        };
      };
    }
  ];
in
pkgs.writeText "${name}.jsonl" (
  pkgs.lib.concatStringsSep "\n" (
    map (r: pkgs.lib.generators.toJSON { } r) (pkgs.lib.filter (x: x != null) resources)
  )
)
