# Introduction

For DigitalOcean's K8s challenge, I chose to install [vcluster](https://www.vcluster.com), which is like namespaces on steroids. From the cluster's perspective, it's a pod. Under the hood, it's k3s (you can also run full k8s if you wish), and once inside it, you have full control over your virtual cluster. It's a StatefulSet with a PVC, so it should handle node failure fine.

_Insert Xzibit meme here._

# HOWTO

## Prerequisites

After you have your DO account set up, get an API key. Next, store it safely - I chose SOPS. Turns out there's a Terraform provider for it so you can use them in code, how lovely.

```
❯ sops --encrypt --in-place --pgp $(gpg --list-keys | grep -E "([0-9]+[A-Z]+).*|([A-Z]+[0-9]+).*" | tail -1) api.json && mv api.json api.enc.json
```

Now, try something new and use Pulumi and Python to declare your infrastructure. Then, get a 500 no matter what you do when you try to stand it up, with no further verbosity apparently possible. Give up, and return to the land of Terraform.

Great Success.

## Terragrunt

I did go a little out of my comfort zone here and included Terragrunt usage, which I'm familiar with, but was never great at. If you aren't familiar, it's a wrapper around Terraform that lets you do more modular things. For example, if you wanted to have separate `dev` and `prod` environments in code, but not using Terraform Workspaces, you'll wind up with a lot of duplicated code. Not only is this annoying, it can introduce inadvertent drift by forgetting to copy something over.

### Examples

With Terragrunt, I can instead do this:

```
./dev/terragrunt.hcl

include {
    path=find_in_parent_folders()
}

terraform {
    source = "..//."
}

./dev/terraform.tfvars

env = "dev"

./variables.tf

# Variables for all environments

./main.tf

# Resource instantiation for all environments
```

### Apply

Then, when I want to apply, I run `terragrunt apply` from within `dev` or `prod`, and whatever changes I've made locally with its `tfvars` file are applied. You do have to be a bit creative with some variables, but judicious use of `locals` usually fixes that.

```
locals {
    cluster_name = "sgarland-${var.env}-cluster"
    pool_name = "${local.cluster_name}-pool"
    k8s_version = replace(var.k8s_version, ".", "_")
    tags = [
        "${local.cluster_name}",
        "v${local.k8s_version}",
        var.region
    ]
}
```

Once the infra is up, we can move on.

## Kubeconfig

Get the .kubeconfig - you need the cluster ID, which the Terraform will output (or you can get from DigitalOcean's dashboard).

```
curl -H "Content-Type: application/json" -H "Authorization: Bearer $(sops --decrypt ./api.enc.json | jq -r '.api_token')" "https://api.digitalocean.com/v2/kubernetes/clusters/$CLUSTER_ID/kubeconfig" > ./kubeconfig
```

Huzzah, nodes!

```
❯ kubectl --kubeconfig=./kubeconfig get nodes
NAME                              STATUS   ROLES    AGE   VERSION
sgarland-dev-cluster-pool-ub4u5   Ready    <none>   12m   v1.21.5
sgarland-dev-cluster-pool-ub4uh   Ready    <none>   11m   v1.21.5
sgarland-dev-cluster-pool-ub4uk   Ready    <none>   12m   v1.21.5
```

I aliased the above:  `alias kk="kubectl --kubeconfig=/Users/sgarland/git/k8s-do-vcluster/kubeconfig"`

## Application Deployment

A coworker wrote a [fun script](https://github.com/sontek/snowmachine) that prints ASCII (technically Unicode, but "Unicode Art" doesn't have the same ring to it) snowflakes in your terminal. Sure, why not? More fun than Hello, World.

```
❯ kk create namespace snowmachine
namespace/snowmachine created
```

I cloned the repo and made a quick and terrible Dockerfile out of it, then pushed it to my Dockerhub repo as `stephangarland/snowmachine`.

```
FROM python:3.8-slim-bullseye
RUN pip3 install snowmachine
CMD ["snowmachine"]
```

A quick Deployment YAML:

```
apiVersion: apps/v1
kind: Deployment
metadata:
  name: snowmachine
  labels:
    app: snowmachine
spec:
  replicas: 1
  selector:
    matchLabels:
      app: snowmachine
  template:
    metadata:
      labels:
        app: snowmachine
    spec:
      containers:
      - name: snowmachine
        image: stephangarland/snowmachine:latest
        imagePullPolicy: Always
```

```
❯ kk apply -f ./snowmachine.yaml -n snowmachine
deployment.apps/snowmachine created

❯ kk attach -n snowmachine $(kk get pods -n snowmachine -o jsonpath='{.items[*].metadata.name}')
```


Snow! Sort of. It's a single vertical line of flakes:

```
❂


❂


❅


❃

❃
```

### Psuedo-TTY allocation

Some fiddling around locally showed that the `-t` (allocate a psuedo-TTY) option needs to be passed, probably because the script is calling `shutil` to get rows and columns. To do this, you have to add the `tty` and `stdin` options to the Container spec, like this:

```
spec:
  containers:
  - name: snowmachine
    image: stephangarland/snowmachine:latest
    imagePullPolicy: Always
    tty: true
    stdin: true
```

And then call `kubectl attach` with `-t`. Unfortunately, it wasn't meant to be:

```
  File "/usr/local/lib/python3.8/site-packages/snowmachine/__init__.py", line 174, in random_printer
    col = random.choice(range(1, int(columns)))
  File "/usr/local/lib/python3.8/random.py", line 290, in choice
    raise IndexError('Cannot choose from an empty sequence') from None
IndexError: Cannot choose from an empty sequence
```

It works locally in Docker, not so much in DigitalOcean K8s.

To prove my dedication to getting this to work, I also tried the Bash script from the same repo; weirdly, that worked about 1/5 times, with this line in the `while` loop being the culprit: `i=$(($RANDOM % $COLUMNS))`. Also, when it did work, it seemed to trap or ignore SIGINT, so the only way out was to kill the terminal. I thought a line of snow was better than occasional success that also captures your terminal, so I went back to the Python version.

## Vcluster

### Installation

Apparently, it's shockingly difficult to get a cluster's CIDR, so they suggest deliberately deploying an invalid service, and reading the error message. I will say that `kubectl cluster-info-dump` has the IP, but not the mask. In any case, this _does_ work:

```
echo '{"apiVersion":"v1","kind":"Service","metadata":{"name":"tst"},"spec":{"clusterIP":"1.1.1.1","ports":[{"port":443}]}}' | kk apply -f - 2>&1 | sed 's/.*valid IPs is //'
```

#### Loadbalancer

First, let's get a LB set up. vcluster's CLI does this for you with the `--expose` flag, but that hides the underlying YAML.

```
---
apiVersion: v1
kind: Service
metadata:
  name: vcluster-loadbalancer
  namespace: host-vcluster-1
spec:
  selector:
    app: vcluster
    release: vcluster-dev
  ports:
    - name: https
      port: 443
      targetPort: 8443
      protocol: TCP
  type: LoadBalancer
```

And here's the result:

```
❯ kk apply -f vcluster-lb.yaml -n host-vcluster-1
service/vcluster-loadbalancer created

❯ kk get svc -n host-vcluster-1
NAME                    TYPE           CLUSTER-IP       EXTERNAL-IP      PORT(S)         AGE
vcluster-loadbalancer   LoadBalancer   10.245.182.250   157.230.65.136   443:31313/TCP   5m37s

```

Now, save that external IP to a file we can add to the vcluster creation.

```
❯ cat << EOF >> vcluster-values.yaml
syncer:
  extraArgs:
  - --tls-san="$(kk get svc -n host-vcluster-1 -o jsonpath='{.items[*].status.loadBalancer.ingress[*].ip}')"
EOF
```

#### Vcluster

One bug/feature I found was that vcluster expects your `.kubeconfig` to reside at `~/.kube/config` - if you have it saved elsewhere, it will fail (or install a vcluster in your work's cluster, depending on if you're authenticated at the moment). Move your normal config somewhere else and link the one created here to that default location.

```
❯ vcluster create vcluster-dev -n host-vcluster-1 -f ./vcluster-values.yaml
[info]   execute command: helm upgrade vcluster-dev vcluster --repo https://charts.loft.sh --version 0.5.0-beta.0 --kubeconfig /var/folders/wy/4cw0pm5x7xb8ws9rf4bdpwb40000gn/T/431524753 --namespace host-vcluster-1 --install --repository-config='' --values /var/folders/wy/4cw0pm5x7xb8ws9rf4bdpwb40000gn/T/3066317214 --values ./vcluster-values.yaml
[done] √ Successfully created virtual cluster vcluster-dev in namespace host-vcluster-1. Use 'vcluster connect vcluster-dev --namespace host-vcluster-1' to access the virtual cluster
```

Hooray, there's our virtual cluster as a pod!

```
❯ kk get pods -n host-vcluster-1
NAME                                                    READY   STATUS    RESTARTS   AGE
coredns-5b9d5f9f77-qv7lz-x-kube-system-x-vcluster-dev   1/1     Running   0          24m
vcluster-dev-0                                          2/2     Running   0          25m
```

Now, connect to the vcluster to get its kubeconfig. I've also renamed it and aliased it to `kdev` to easily differentiate.

```
❯ vcluster connect vcluster-dev -n host-vcluster-1 --server="https://$(kk get svc -n host-vcluster-1 -o jsonpath='{.items[*].status.loadBalancer.ingress[*].ip}')"
[done] √ Virtual cluster kube config written to: ./kubeconfig.yaml. You can access the cluster via `kubectl --kubeconfig ./kubeconfig.yaml get namespaces`

❯ mv kubeconfig.yaml vcluster-kubeconfig

❯ alias kdev=kubectl --kubeconfig=/Users/sgarland/git/k8s-do-vcluster/vcluster-kubeconfig
```

Test out the new kubeconfig:
```
❯ kdev get namespaces
NAME              STATUS   AGE
default           Active   13m
kube-system       Active   13m
kube-public       Active   13m
kube-node-lease   Active   13m
```

### K8s upgrade

Let's upgrade the vcluster's k8s version, and then test our application to make sure it works.

For posterity, here are the current versions of the physical cluster and virtual cluster:

```
❯ kk version -o json | jq -r '.serverVersion.gitVersion'
v1.20.11

❯ kdev version -o json | jq -r '.serverVersion.gitVersion'
v1.20.11+k3s2
```

In order to upgrade the vcluster, we need to modify its definition with the k3s image version specified as desired - in this case, `v1.21.5-k3s2`. Now, we could have just built the cluster with `kubectl apply` rather than using the vcluster CLI tool, but since we didn't, and vcluster defines a StatefulSet, we have to patch it.

```
❯ kk patch statefulset vcluster-dev -n host-vcluster-1 --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/image", "value":"rancher/k3s:v1.21.5-k3s2"}]'

statefulset.apps/vcluster-dev patched
```

```
❯ kk get pods -n host-vcluster-1
NAME                                                    READY   STATUS        RESTARTS   AGE
coredns-5b9d5f9f77-qv7lz-x-kube-system-x-vcluster-dev   1/1     Running       0          45m
vcluster-dev-0                                          0/2     ContainerCreating   0          45m
```

Check the versions again:

```
❯ kk version -o json | jq -r '.serverVersion.gitVersion'
v1.20.11
❯ kdev version -o json | jq -r '.serverVersion.gitVersion'
v1.21.5+k3s2
```

#### Application testing

```
❯ kdev create namespace snowmachine
namespace/snowmachine created

❯ kdev apply -f ./snowmachine.yaml -n snowmachine
deployment.apps/snowmachine created
```

```
❯ kdev attach -n snowmachine $(kdev get pods -n snowmachine -o jsonpath='{.items[*].metadata.name}')


❂


❂


❅


❃

❃
```

I'll save you the read, but suffice to say, the same problem existed as before when trying to allocate a psuedo TTY.

## Demonstrating resource separation

Remember, `kk` is looking at the host cluster, and `kdev` at the vcluster. Here, we can see that there's a namespace on the host cluster, and both clusters have a namespace for our snowmachine app, since they're deployed to both. Finally, the host cluster can see that app running as a pod. This is done because the vclusters don't have a scheduler, and instead rely on resources in the vcluster being synchronized to the host for scheduling.

```
❯ kk get namespaces
NAME              STATUS   AGE
default           Active   94m
host-vcluster-1   Active   79m
kube-node-lease   Active   94m
kube-public       Active   94m
kube-system       Active   94m
snowmachine       Active   84m

❯ kdev get namespaces
NAME              STATUS   AGE
default           Active   63m
kube-system       Active   63m
kube-public       Active   63m
kube-node-lease   Active   63m
snowmachine       Active   5m8s

❯ kk get pods -n host-vcluster-1
NAME                                                      READY   STATUS    RESTARTS   AGE
coredns-6ff7df994d-8zn8g-x-kube-system-x-vcluster-dev     1/1     Running   0          6m44s
snowmachine-f5f76cb4-f2wqs-x-snowmachine-x-vcluster-dev   1/1     Running   0          5m9s
vcluster-dev-0                                            2/2     Running   0          7m17s
```

## HULK SMASH

```
❯ terragrunt destroy
Do you really want to destroy all resources?
  Terraform will destroy all your managed infrastructure, as shown above.
  There is no undo. Only 'yes' will be accepted to confirm.

  Enter a value: yes

digitalocean_kubernetes_cluster.k8s_cluster: Destroying... [id=b637e1a4-f2ed-40a2-8e21-7e1a38a0cf41]
digitalocean_kubernetes_cluster.k8s_cluster: Destruction complete after 1s

Destroy complete! Resources: 1 destroyed.
```

Don't forget to manually clean up anything created with `kubectl`, like the Load Balancer. Also, of course, it is possible to instantiate it with Terra{form,grunt} if you'd rather do it that way.

# Conclusion

I think it's an interesting project, and one that has some merits. I personally foresee myself using this in my soon-to-exist home cluster, to have a separated dev cluster. Time will tell if it's more useful than a namespace, but it's fun to play with if nothing else.
