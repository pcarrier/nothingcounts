{
  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs";
  };
  outputs =
    {
      self,
      flake-utils,
      nixpkgs,
      ...
    }:
    let
      topDomain = "greetings.pcarrier.com";
      rev =
        let
          envBased = builtins.getEnv "REV";
        in
        if envBased == "" then
          self.shortRev or "${self.dirtyShortRev}-${builtins.hashString "sha256" self.narHash}"
        else
          envBased;
      inKubernetes = builtins.getEnv "IN_KUBERNETES" == "true";
      lib = nixpkgs.lib;
      mkRepository =
        env: name:
        if env.kind == "minikube" then
          name
        else
          "${env.region}-docker.pkg.dev/${env.project}/${env.name}/${name}";
    in
    (flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        mkPkgs =
          targetSystem:
          import nixpkgs {
            inherit system;
            crossSystem = {
              config =
                {
                  "aarch64-darwin" = "aarch64-apple-darwin";
                  "aarch64-linux" = "aarch64-unknown-linux-gnu";
                  "x86_64-linux" = "x86_64-unknown-linux-gnu";
                }
                ."${targetSystem}";
            };
          };
        kctl =
          env: "${pkgs.kubectl}/bin/kubectl ${if inKubernetes then "" else "--context ${env.context}"}";
      in
      {
        devShells = {
          default = pkgs.mkShell {
            packages =
              with pkgs;
              let
                gcloud = google-cloud-sdk.withExtraComponents [
                  google-cloud-sdk.components.gke-gcloud-auth-plugin
                ];
              in
              [
                go
                gcloud
                kubectl
              ];
          };
        };
        envPackages = {
          dockerImage =
            env:
            let
              targetPkgs = mkPkgs env.system;
            in
            {
              trampolineBase = pkgs.dockerTools.buildImage {
                name = "trampoline-base";
                copyToRoot = pkgs.buildEnv {
                  name = "trampoline-base-root";
                  paths = with targetPkgs; [
                    coreutils # needed in PATH for gcloud
                    dockerTools.caCertificates
                    dockerTools.fakeNss
                    dockerTools.usrBinEnv
                    bash
                    nix
                  ];
                  pathsToLink = [
                    "/bin"
                    "/etc"
                    "/usr/bin"
                  ];
                };
              };
              trampoline = pkgs.dockerTools.buildImage {
                name = "trampoline";
                fromImage = (self.envPackages.${system}.dockerImage env).trampolineBase;
                copyToRoot = pkgs.buildEnv {
                  name = "trampoline-root";
                  paths = [ ./. ];
                  pathsToLink = [ "/bin" ];
                };
                config = {
                  Env = [
                    "REV=${rev}"
                  ];
                  WorkingDir = ./.;
                };
              };
              greetings = pkgs.dockerTools.buildLayeredImage {
                name = "greetings";
                contents = pkgs.buildEnv {
                  name = "greetings-root";
                  paths = with targetPkgs; [
                    dockerTools.caCertificates
                    self.packages.${system}.greetings
                  ];
                  pathsToLink = [
                    "/bin"
                    "/etc"
                  ];
                };
                config = {
                  Cmd = [ "/bin/greetings" ];
                };
              };
            };
          publishDockerImage =
            {
              env,
              image,
              name,
            }:
            pkgs.writeShellScript "publish-docker-image-${name}" (
              if env.kind == "minikube" then
                if inKubernetes then
                  ''
                    set -xeuo pipefail
                    ${pkgs.skopeo}/bin/skopeo inspect docker-daemon:${mkRepository env name}:${rev} > /dev/null 2>&1 && exit
                    exec ${pkgs.skopeo}/bin/skopeo --insecure-policy copy docker-archive:${image} docker-daemon:${mkRepository env name}:${rev}
                  ''
                else
                  ''
                    set -xeuo pipefail
                    eval $(${pkgs.minikube}/bin/minikube docker-env --shell bash)
                    ${pkgs.skopeo}/bin/skopeo inspect docker-daemon:${mkRepository env name}:${rev} > /dev/null 2>&1 && exit
                    exec ${pkgs.skopeo}/bin/skopeo --insecure-policy copy --dest-cert-dir=$DOCKER_CERT_PATH --dest-daemon-host=$DOCKER_HOST docker-archive:${image} docker-daemon:${mkRepository env name}:${rev}
                  ''
              else
                ''
                  set -xeuo pipefail
                  ${if inKubernetes then "export PATH=${pkgs.google-cloud-sdk}/bin:$PATH" else ""}
                  gcloud auth configure-docker ${env.region}-docker.pkg.dev --quiet
                  ${pkgs.skopeo}/bin/skopeo inspect docker://${mkRepository env name}:${rev} > /dev/null 2>&1 && exit
                  exec ${pkgs.skopeo}/bin/skopeo --insecure-policy copy docker-archive:${image} docker://${mkRepository env name}:${rev}
                ''
            );
          trampoline =
            env:
            pkgs.writeShellScriptBin "trampoline" ''
              set -xeuo pipefail
              ${self.envPackages.${system}.publishDockerImage {
                inherit env;
                image = (self.envPackages.${system}.dockerImage env).trampoline;
                name = "trampoline";
              }}
              NAME=trampoline-$(echo "${rev}" "$@" | ${pkgs.coreutils}/bin/sha256sum | cut -c1-8)
              sed -e "s:\"%COMMAND%\":$(${pkgs.jo}/bin/jo -a "$@"):" -e "s:%NAME%:$NAME:" ${
                import ./k8s/trampoline.jsonl.nix {
                  inherit
                    pkgs
                    env
                    mkRepository
                    rev
                    ;
                }
              } | ${kctl env} apply -f -
              cleanup() {
                status=$?
                ${kctl env} delete pod $NAME
                exit $status
              }
              trap cleanup EXIT
              ${self.packages.${system}.k8stailexit}/bin/tailexit -context ${env.context} -pod $NAME
            '';
          kubeGreetings =
            env:
            pkgs.writeShellScriptBin "kube-greetings" ''
              set -xeuo pipefail
              ${self.envPackages.${system}.publishDockerImages env}/bin/publish-docker-images
              ${kctl env} apply -f ${
                import ./k8s/greetings.jsonl.nix {
                  inherit
                    pkgs
                    env
                    mkRepository
                    rev
                    ;
                }
              }
              ${kctl env} rollout status deployment greetings
            '';
          publishDockerImages =
            env:
            let
              images = with self.envPackages.${system}.dockerImage env; {
                "greetings" = greetings;
              };
            in
            pkgs.writeShellScriptBin "publish-docker-images" ''
              set -xeuo pipefail
              ${builtins.concatStringsSep "\n" (
                builtins.map (
                  name:
                  self.envPackages.${system}.publishDockerImage ({
                    inherit env;
                    image = images.${name};
                    inherit name;
                  })
                ) (builtins.attrNames images)
              )}
            '';
          tofuApply =
            env:
            pkgs.writeShellScriptBin "tofu-apply" ''
              set -xeuo pipefail
              # Check if the bucket exists
              ${pkgs.google-cloud-sdk}/bin/gcloud storage buckets describe \
                gs://${env.project}-tofu-state \
                --project=${env.project} \
                --quiet > /dev/null 2>&1 || \
              ${pkgs.google-cloud-sdk}/bin/gcloud storage buckets create \
                gs://${env.project}-tofu-state \
                --project=${env.project} \
                --uniform-bucket-level-access \
                --public-access-prevention \
                --quiet
              TMPDIR=$(mktemp -d)
              trap 'rm -rf "$TMPDIR"' EXIT
              ${pkgs.coreutils}/bin/install -Dm 0644 ${
                import ./tofu/project.nix {
                  inherit
                    pkgs
                    env
                    ;
                }
              } "$TMPDIR/project/project.tf.json"
              ${pkgs.coreutils}/bin/install -Dm 0644 ${
                import ./tofu/zone.nix {
                  inherit
                    pkgs
                    env
                    ;
                }
              } "$TMPDIR/zone/zone.tf.json"
              ${pkgs.opentofu}/bin/tofu -chdir="$TMPDIR/project" init
              ${pkgs.opentofu}/bin/tofu -chdir="$TMPDIR/project" apply -auto-approve
              ${pkgs.opentofu}/bin/tofu -chdir="$TMPDIR/zone" init
              ${pkgs.opentofu}/bin/tofu -chdir="$TMPDIR/zone" apply -auto-approve
            '';
          tofuDestroy =
            env:
            pkgs.writeShellScriptBin "tofu-destroy" ''
              set -xeuo pipefail
              TMPDIR=$(mktemp -d)
              trap 'rm -rf "$TMPDIR"' EXIT
              ${pkgs.coreutils}/bin/install -Dm 0644 ${
                import ./tofu/zone.nix {
                  inherit
                    pkgs
                    env
                    ;
                }
              } "$TMPDIR/zone.tf.json"
              ${pkgs.opentofu}/bin/tofu -chdir="$TMPDIR" init
              ${pkgs.opentofu}/bin/tofu -chdir="$TMPDIR" destroy -auto-approve
            '';
          config =
            env:
            pkgs.writeShellScriptBin "config" ''
              set -xeuo pipefail
              ${
                if env.kind == "gcloud" then
                  ''
                    ${self.packages.${system}.googleAuth}/bin/google-auth
                    ${self.envPackages.${system}.tofuApply env}/bin/tofu-apply
                    ${pkgs.google-cloud-sdk}/bin/gcloud container clusters get-credentials --project ${env.project} --region ${env.region} ${env.name} --quiet
                  ''
                else if env.kind == "minikube" then
                  ''
                    ${pkgs.minikube}/bin/minikube status > /dev/null 2>&1 || \
                    ${pkgs.minikube}/bin/minikube start \
                      --driver=docker \
                      --static-ip 10.42.42.42 \
                      --memory=max \
                      --cpus=max
                    ${pkgs.minikube}/bin/minikube addons enable ingress
                  ''
                else
                  ""
              }
            '';
          down =
            env:
            pkgs.writeShellScriptBin "down" ''
              set -xeuo pipefail
              ${
                if env.kind == "gcloud" then
                  ''
                    ${self.packages.${system}.googleAuth}/bin/google-auth
                    ${self.envPackages.${system}.tofuDestroy env}/bin/tofu-destroy
                  ''
                else if env.kind == "minikube" then
                  "${pkgs.minikube}/bin/minikube delete"
                else
                  ""
              }
            '';
        };
        packages =
          {
            pass = pkgs.writeShellScriptBin "pass" "";
            fail = pkgs.writeShellScriptBin "fail" "exit 1";
            googleAuth = pkgs.writeShellScriptBin "google-auth" ''
              set -xeuo pipefail
              ${pkgs.google-cloud-sdk}/bin/gcloud auth print-identity-token > /dev/null 2>&1 || \
              ${pkgs.google-cloud-sdk}/bin/gcloud auth login --quiet
              ${pkgs.google-cloud-sdk}/bin/gcloud auth application-default print-access-token > /dev/null 2>&1 || \
              ${pkgs.google-cloud-sdk}/bin/gcloud auth application-default login --quiet
            '';
            greetings = pkgs.buildGoModule {
              name = "greetings";
              src = ./greetings;
              vendorHash = null;
            };
            k8stailexit = pkgs.buildGoModule {
              name = "k8stailexit";
              src = ./k8s/tailexit;
              vendorHash = "sha256-99TquUlreFbu/IP5valj9n+15T1YmMM9Xb+eYlPFbZE=";
            };
          }
          // (
            let
              mkGcloudEnv =
                {
                  project,
                  region,
                  system,
                  dnsName,
                }:
                rec {
                  inherit project region system;
                  context = "gke_${project}_${region}_${region}";
                  name = region;
                  kind = "gcloud";
                  domain = "${dnsName}.${topDomain}";
                };
              environments =
                let
                  minikubeSystem = if system == "aarch64-darwin" then "aarch64-linux" else system;
                in
                [
                  rec {
                    kind = "minikube";
                    name = kind;
                    context = kind;
                    system = minikubeSystem;
                    domain = "minikube.${topDomain}";
                  }
                ]
                ++ (builtins.map (env: mkGcloudEnv env) [
                  {
                    project = "nothingcounts";
                    region = "europe-west9";
                    dnsName = "eu";
                    system = "x86_64-linux";
                  }
                ]);
              mkKubePackages =
                env:
                let
                  envPackages = with self.envPackages.${system}; {
                    config = config;
                    down = down;
                    kube-greetings = kubeGreetings;
                    trampoline = trampoline;
                  };
                in
                lib.mapAttrs' (name: pkg: lib.nameValuePair "${env.name}-${name}" (pkg env)) envPackages;
            in
            builtins.foldl' (acc: env: acc // mkKubePackages env) { } environments
          );
      }
    ));
}
