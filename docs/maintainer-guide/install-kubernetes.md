---
author: Martin Weise
---

## TL;DR

To install DBRepo in your existing cluster, download the
sample [
`values.yaml`](https://github.com/DBRepo-Project/dbrepo/blob/main/helm/dbrepo/values.yaml)
for your deployment and update the variables, especially `hostname` and `ingress`.

```shell
helm upgrade --install dbrepo \
  -n dbrepo \
  "oci://ghcr.io/dbrepo-project/helm/dbrepo" \
  --values ./values.yaml \
  --version "1.14.1" \
  --create-namespace \
  --cleanup-on-fail
```

## Prerequisites

!!! info

     * Kubernetes 1.30+ (tested on 1.31.5)
     * PV provisioner support in the underlying infrastructure
     * An ingress controller (the chart defaults to the `nginx` ingress class)
     * A TLS certificate for `hostname`

### Ingress and TLS

DBRepo must be served over HTTPS. The chart generates every public URL as `https://<hostname>` and has no option for
plain HTTP. The Gateway Service does not terminate TLS itself, so TLS has to be terminated at the ingress (or at a
load balancer in front of it).

Enable the ingress in your `values.yaml` and store the certificate (keys `tls.crt` and `tls.key`) in the secret named
by `ingress.tls.secretName` in the release namespace:

```yaml
hostname: dbrepo.example.com
ingress:
  enabled: true
  className: nginx
  tls:
    enabled: true
    secretName: ingress-cert
```

### Resource Quota

By default, the chart runs most services with 2-3 replicas and the Data Database and Metadata Database as 3-node
Galera clusters with the `xlarge` resource preset. With the default `values.yaml`, your cluster needs to meet the
following `ResourceQuota`:

```yaml
requests.cpu: 23000m
requests.ephemeral-storage: 3072Mi
secrets: '50'
<storageClass>.storageclass.storage.k8s.io/persistentvolumeclaims: '25'
<storageClass>.storageclass.storage.k8s.io/requests.storage: 170Gi
persistentvolumeclaims: '25'
requests.memory: 42496Mi
pods: '50'
requests.storage: 170Gi
limits.memory: 64896Mi
configmaps: '20'
services: '45'
```

For a smaller cluster, lower the `replicaCount` and `resourcesPreset` values in your `values.yaml`.

## Uninstall

Remove DBRepo by stopping and removing all pods and persistent volume claims:

```shell
helm uninstall \
  dbrepo \
  -n dbrepo
kubectl -n dbrepo \
  delete \
  pvc \
  --all
```

!!! danger "Further configuration is highly recommended"

    The default `values.yaml` contains default passwords and secrets. Change them before you make the deployment
    publicly available. Please visit the [configuration](configuration/) page in the next step to complete the
    installation.
