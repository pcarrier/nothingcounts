# A highly reproducible GKE project

- Create a Google Cloud project, attach billing to it, get ready to deal with quotas…
- Install [`nix`](https://nixos.org/) however you prefer (eg through [Determinate Nix](https://docs.determinate.systems/getting-started/individuals)), install [`direnv`](https://direnv.net/), [hook it to your shell](https://direnv.net/docs/hook.html).
- Clone this repository, `direnv allow`.
- Tweak `topDomain =` and `project =` in [`flake.nix`](flake.nix).
- Run `up` to run in a local `minikube` cluster (Docker must be available).
- Run `up europe-west9` to deploy to `europe-west9`. You'll have to log into Google a couple of times.
- Set up DNS. `eu.greetings.pcarrier.com NS ns-cloud-b1.googledomains.com` and `minikube.greetings.pcarrier.com A 10.42.42.42`.
- Wait for the certificate to provision…
- Production! `curl https://eu.greetings.pcarrier.com/Pierre` → `Hello, Pierre! Our IP is 34.163.236.240, which is registered to Google LLC via AS396982 in France`
- Had your fun? What came `up` can go `down`. `down europe-west9` to release cloud resources.

## Scope

This is an illustration of maximal Nix and the trampoline technique in preparation for an article. We intentionally left out:

- Any kind of CI/CD.
- Requesting and limiting Kubernetes resources. We run cheap!
- Fine-grained access control. Trampolines can do a lot more than they strictly need to.
- Multiple regions and architectures, though we've structured for them.
- A useful workload…

## Feedback

Still a Nix beginner. Feedback is truly appreciated.
