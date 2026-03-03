# Local CNPG Testing Guide

Test pg_timers with CloudNativePG on a local Kubernetes cluster using k3d.

## Prerequisites

- Docker Desktop running
- [Nix](https://nixos.org/) installed (the flake provides k3d, kubectl, and helm)

## 1. Enter the Kubernetes shell

```bash
nix develop .#k8s
```

This provides `k3d`, `kubectl`, and `helm` without installing them globally.

## 2. Create the k3d cluster

k3d runs k3s (lightweight Kubernetes) inside Docker containers. The `ImageVolume` feature gate is required for CNPG's extension image mounting (alpha in Kubernetes 1.33).

```bash
k3d cluster create pg-timers-test \
  --image rancher/k3s:v1.33.6-k3s1 \
  --k3s-arg '--kube-apiserver-arg=feature-gates=ImageVolume=true@server:*' \
  --k3s-arg '--kube-controller-manager-arg=feature-gates=ImageVolume=true@server:*' \
  --k3s-arg '--kubelet-arg=feature-gates=ImageVolume=true@server:*'
```

## 3. Install the CNPG operator

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update cnpg
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace --wait
```

## 4. Pull and import base images

k3d uses its own container registry. Images must be imported explicitly.

```bash
docker pull ghcr.io/cloudnative-pg/postgresql:18
k3d image import ghcr.io/cloudnative-pg/postgresql:18 -c pg-timers-test
```

## 5. Build and import the extension image

```bash
docker build -f Dockerfile.cnpg -t ghcr.io/vabatta/pg_timers-cnpg:18-latest .
k3d image import ghcr.io/vabatta/pg_timers-cnpg:18-latest -c pg-timers-test
```

## 6. Deploy the CNPG cluster

```bash
kubectl apply -f examples/cnpg-cluster.yaml
kubectl wait --for=condition=Ready pod \
  -l cnpg.io/cluster=cluster-with-timers --timeout=120s
```

## 7. Test timer scheduling

```bash
kubectl exec -it cluster-with-timers-1 -- psql -U postgres -d app -c "
  SELECT timers.schedule_in('2 seconds', \$\$SELECT 1\$\$);
  SELECT pg_sleep(3);
  SELECT id, status, fire_at, fired_at,
         fired_at - fire_at AS latency
  FROM timers.timers ORDER BY id;
"
```

A successful result shows `status = 1` (fired) with a small `latency` value.

## 8. Check worker logs

```bash
kubectl logs cluster-with-timers-1 -c postgres | grep pg_timers
```

## Rebuilding after code changes

After modifying the extension source code:

```bash
# Rebuild and reimport the image
docker build -f Dockerfile.cnpg -t ghcr.io/vabatta/pg_timers-cnpg:18-latest .
k3d image import ghcr.io/vabatta/pg_timers-cnpg:18-latest -c pg-timers-test

# Restart the pod to pick up the new image
kubectl delete pod -l cnpg.io/cluster=cluster-with-timers
kubectl wait --for=condition=Ready pod \
  -l cnpg.io/cluster=cluster-with-timers --timeout=120s

# Recreate the extension (new .so requires this)
kubectl exec -it cluster-with-timers-1 -- \
  psql -U postgres -d app -c "CREATE EXTENSION IF NOT EXISTS pg_timers;"
```

## Cleanup

```bash
kubectl delete cluster cluster-with-timers
k3d cluster delete pg-timers-test
```
