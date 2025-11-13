#!/usr/bin/env bash
set -eo pipefail

CLUSTER_NAME=${CLUSTER_NAME:-k8s-lab}
CONFIG_FILE=cluster-config.yaml

# 1. Skapa cluster-config.yaml om den inte finns
if [[ ! -f "$CONFIG_FILE" ]]; then
cat <<EOF > "$CONFIG_FILE"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 30000  # Grafana NodePort
    hostPort: 3000
    protocol: TCP
  - containerPort: 30090  # Prometheus NodePort
    hostPort: 9090
    protocol: TCP
EOF
fi

# 2. Rensa gammalt kluster (idempotent)
if kind get clusters | grep -q "^${CLUSTER_NAME}\$"; then
  echo "♻️  Rensar gammalt kluster ${CLUSTER_NAME}..."
  kind delete cluster --name "$CLUSTER_NAME"
fi

# 3. Skapa nytt kluster
echo "Skapar nytt kind-kluster..."
kind create cluster --name "$CLUSTER_NAME" --config "$CONFIG_FILE"

# 4. Vänta tills klustret är ready
kubectl wait --for=condition=Ready nodes --all --timeout=300s

# 5. Installera NGINX-ingress
echo "Installerar NGINX-ingress..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s

# 6. Installera Prometheus & Grafana via Helm
echo "Lägger till Prometheus-community repo..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

echo "Installerar kube-prometheus-stack..."
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort=30000 \
  --set prometheus.service.type=NodePort \
  --set prometheus.service.nodePort=30090 \
  --wait

# 7. Skriv ut info
echo "  Done"
echo "   Grafana:  http://localhost:3000  (admin/prom-operator)"
echo "   Prometheus: http://localhost:9090"
