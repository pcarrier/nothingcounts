{
  pkgs,
  env,
  mkRepository,
  rev,
}:
let
  cacheReadUrl = "file:///cache?trusted=1";
  cacheWriteUrl = "file:///cache?compression=none";
  resources = [
    {
      apiVersion = "v1";
      kind = "ServiceAccount";
      metadata = {
        name = "trampoline";
      };
    }
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "Role";
      metadata = {
        name = "trampoline";
      };
      rules = [
        {
          apiGroups = [ "*" ];
          resources = [ "*" ];
          verbs = [ "*" ];
        }
      ];
    }
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "RoleBinding";
      metadata = {
        name = "trampoline";
      };
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = "trampoline";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = "trampoline";
        }
      ];
    }
    {
      apiVersion = "v1";
      kind = "Pod";
      metadata = {
        name = "%NAME%";
        annotations = {
          "gke-gcsfuse/volumes" = "true";
        };
      };
      spec = {
        restartPolicy = "Never";
        serviceAccountName = "trampoline";
        nodeSelector = {
          "kubernetes.io/arch" = if env.system == "aarch64-linux" then "arm64" else "amd64";
        };
        containers = [
          {
            name = "trampoline";
            securityContext = {
              privileged = true;
            };
            image = "${mkRepository env "trampoline"}:${rev}";
            command = "%COMMAND%";
            env = [
              {
                name = "IN_KUBERNETES";
                value = "true";
              }
              {
                name = "NIX_CONFIG";
                value = ''
                  build-users-group =
                  substituters = ${cacheReadUrl} https://cache.nixos.org
                '';
              }
              {
                name = "CACHE_URL";
                value = cacheWriteUrl;
              }
            ];
            volumeMounts =
              [
                {
                  name = "trampoline-cache";
                  mountPath = "/cache";
                }
                {
                  name = "tmp";
                  mountPath = "/tmp";
                }
                {
                  name = "var-tmp";
                  mountPath = "/var/tmp";
                }
              ]
              ++ (
                if env.kind == "minikube" then
                  [
                    {
                      name = "docker-socket";
                      mountPath = "/var/run/docker.sock";
                    }
                  ]
                else
                  [ ]
              );
          }
        ];
        volumes =
          [
            (
              {
                name = "trampoline-cache";
              }
              // (
                if env.kind == "minikube" then
                  {
                    hostPath = {
                      path = "/var/cache/trampoline";
                      type = "DirectoryOrCreate";
                    };
                  }
                else
                  {
                    csi = {
                      driver = "gcsfuse.csi.storage.gke.io";
                      volumeAttributes = {
                        mountOptions = "implicit-dirs";
                        bucketName = "${env.project}-${env.name}-trampoline-cache";
                      };
                    };
                  }
              )
            )
            {
              name = "tmp";
              emptyDir = {
                medium = "Memory";
              };
            }
            {
              name = "var-tmp";
              emptyDir = {
                medium = "Memory";
              };
            }
          ]
          ++ (
            if env.kind == "minikube" then
              [
                {
                  name = "docker-socket";
                  hostPath = {
                    path = "/var/run/docker.sock";
                    type = "Socket";
                  };
                }
              ]
            else
              [ ]
          );
      };
    }
  ];
in
pkgs.writeText "trampoline.jsonl" (
  pkgs.lib.concatStringsSep "\n" (map (r: pkgs.lib.generators.toJSON { } r) resources)
)
