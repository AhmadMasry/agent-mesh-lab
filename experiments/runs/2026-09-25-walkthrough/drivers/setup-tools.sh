LAB_TOOLS="${TMPDIR:-/tmp}/agent-mesh-lab-tools"
ISTIOCTL_ASSET=istioctl-1.31.1-osx-arm64.tar.gz
mkdir -p "$LAB_TOOLS/helm/config" "$LAB_TOOLS/helm/cache/repository"
curl -fsSL -o "$LAB_TOOLS/$ISTIOCTL_ASSET" "https://github.com/istio/istio/releases/download/1.31.1/$ISTIOCTL_ASSET"
curl -fsSL -o "$LAB_TOOLS/$ISTIOCTL_ASSET.sha256" "https://github.com/istio/istio/releases/download/1.31.1/$ISTIOCTL_ASSET.sha256"
want=$(cut -d' ' -f1 "$LAB_TOOLS/$ISTIOCTL_ASSET.sha256")
got=$(shasum -a 256 "$LAB_TOOLS/$ISTIOCTL_ASSET" | cut -d' ' -f1)
[ -n "$want" ] && [ "$want" = "$got" ] && echo "checksum ok: $got" && tar -xzf "$LAB_TOOLS/$ISTIOCTL_ASSET" -C "$LAB_TOOLS"
export PATH="$LAB_TOOLS:$PATH"
: > "$LAB_TOOLS/helm/config/repositories.yaml"
export HELM_REPOSITORY_CONFIG="$LAB_TOOLS/helm/config/repositories.yaml"
export HELM_REPOSITORY_CACHE="$LAB_TOOLS/helm/cache/repository"
export HELM_CACHE_HOME="$LAB_TOOLS/helm/cache"
istioctl version --remote=false
