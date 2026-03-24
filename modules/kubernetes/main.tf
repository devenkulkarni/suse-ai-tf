## Add the namespace for deploying SUSE AI Stack:
resource "kubernetes_namespace_v1" "suse_ai_ns" {
  depends_on = [null_resource.validate_kubernetes_connection]
  metadata {
    name = var.suse_ai_namespace
  }
}

## Add the secret for accessing the application-collection registry:
resource "kubernetes_secret_v1" "suse-appco-registry" {
  depends_on = [kubernetes_namespace_v1.suse_ai_ns]
  metadata {
    name      = var.registry_secretname
    namespace = var.suse_ai_namespace
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${var.registry_name}" = {
          username = var.registry_username,
          password = var.registry_password,
          auth     = base64encode("${var.registry_username}:${var.registry_password}")
        }
      }
    })
  }
}

## Add NVIDIA-GPU-OPERATOR using helm:
resource "helm_release" "nvidia_gpu_operator" {
  name       = "nvidia-gpu-operator"
  namespace  = var.gpu_operator_ns
  repository = "https://helm.ngc.nvidia.com/nvidia"
  chart      = "gpu-operator"

  create_namespace = true
  depends_on       = [null_resource.validate_kubernetes_connection]

  values = [file("${path.module}/nvidia-gpu-operator-values.yaml")]
}

## Add cert-manager using helm:
resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  namespace  = var.suse_ai_namespace
  repository = "oci://${var.registry_name}/charts"
  chart      = "cert-manager"
  timeout    = 600
  version    = "1.19.3"
  
  repository_username = var.registry_username
  repository_password = var.registry_password

  create_namespace = true
  depends_on       = [kubernetes_secret_v1.suse-appco-registry, null_resource.validate_kubernetes_connection, helm_release.nvidia_gpu_operator]

  set = [{
    name  = "crds.enabled"
    value = "true"
    },
    {
      name  = "global.imagePullSecrets[0].name"
      value = kubernetes_secret_v1.suse-appco-registry.metadata[0].name
    },
    {
      name  = "config.apiVersion"
      value = "controller.config.cert-manager.io/v1alpha1"
    },
    {
      name  = "config.kind"
      value = "ControllerConfiguration"
    },
    {
      name  = "config.enableGatewayAPI"
      value = "true"
    }
  ]
}

## Add label to node for GPU assignment:
resource "null_resource" "label_node" {
  depends_on = [null_resource.validate_kubernetes_connection]

  provisioner "remote-exec" {
    inline = [
      "NODE_NAME=$(sudo /var/lib/rancher/rke2/bin/kubectl get nodes --kubeconfig /etc/rancher/rke2/rke2.yaml -o jsonpath='{.items[0].metadata.name}') && sudo /var/lib/rancher/rke2/bin/kubectl label node $NODE_NAME accelerator=nvidia-gpu --kubeconfig /etc/rancher/rke2/rke2.yaml --overwrite"
    ]

    connection {
      type        = "ssh"
      user        = var.ssh_username
      private_key = var.ssh_private_key_content
      host        = var.instance_public_ip
    }
  }
}

## Add traefik with gateway API:
resource "null_resource" "configure_traefik" {
  depends_on = [helm_release.cert_manager]

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      sudo tee /var/lib/rancher/rke2/server/manifests/rke2-traefik-config.yaml > /dev/null <<EOF
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-traefik
  namespace: kube-system
spec:
  valuesContent: |-
    gateway:
      enabled: false
    ports:
      web:
        port: 80
        expose:
          default: true
        exposedPort: 80
        protocol: TCP
      websecure:
        port: 443
        expose:
          default: true
        exposedPort: 443
        protocol: TCP
        tls:
          enabled: true
        mode: Passthrough
    providers:
      kubernetesGateway:
        enabled: true
EOF
      EOT
    ]
    connection {
      type        = "ssh"
      user        = var.ssh_username
      private_key = var.ssh_private_key_content
      host        = var.instance_public_ip
    }
  }
}

## 2. Wait for Traefik to restart with new settings
resource "null_resource" "wait_for_traefik" {
  depends_on = [null_resource.configure_traefik]

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for Traefik pods to restart with new config...'",
      "sudo /var/lib/rancher/rke2/bin/kubectl rollout status daemonset rke2-traefik -n kube-system --kubeconfig /etc/rancher/rke2/rke2.yaml --timeout=300s"
    ]
    connection {
      type        = "ssh"
      user        = var.ssh_username
      private_key = var.ssh_private_key_content
      host        = var.instance_public_ip
    }
  }
}

resource "null_resource" "suse_ai_gateway_init" {
  depends_on = [helm_release.cert_manager, null_resource.wait_for_traefik]

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      # Create the manifest file
      cat <<EOF > gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: suse-ai-gateway
  namespace: ${var.suse_ai_namespace}
spec:
  gatewayClassName: traefik
  listeners:
  - name: web
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
EOF

      # Apply the manifest using the absolute path to kubectl
      echo "Applying initial HTTP Gateway..."
      sudo /var/lib/rancher/rke2/bin/kubectl apply --kubeconfig /etc/rancher/rke2/rke2.yaml -f gateway.yaml
      EOT
    ]

    connection {
      type        = "ssh"
      user        = var.ssh_username
      private_key = var.ssh_private_key_content
      host        = var.instance_public_ip
    }
  }
}

## 1. Create a ClusterIssuer for Cert-Manager (Self-Signed or Let's Encrypt)
resource "null_resource" "cert_manager_issuer" {
  depends_on = [helm_release.cert_manager]

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      cat <<EOF > issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-cert-issuer
spec:
  acme:
    server: ${var.letsencrypt_acme_server}
    privateKeySecretRef:
      name: letsencrypt-secret
    solvers:
    - http01:
        gatewayHTTPRoute:
          podTemplate:
            spec:
              imagePullSecrets:
              - name: ${var.registry_secretname}
          parentRefs:
          - name: suse-ai-gateway
            namespace: ${var.suse_ai_namespace}
EOF
      echo "Applying issuer.yaml...."
      sudo /var/lib/rancher/rke2/bin/kubectl apply --kubeconfig /etc/rancher/rke2/rke2.yaml -f issuer.yaml
      EOT
    ]

    connection {
      type        = "ssh"
      user        = var.ssh_username
      private_key = var.ssh_private_key_content
      host        = var.instance_public_ip
    }
  }
}

## 2. Create the Certificate (Produces the secret: suse-ai-tls)
resource "null_resource" "suse_ai_cert" {
  depends_on = [null_resource.cert_manager_issuer, null_resource.suse_ai_gateway_init]

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      cat <<EOF > certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: suse-ai-stack-cert
  namespace: ${var.suse_ai_namespace}
spec:
  secretName: suse-ai-tls
  issuerRef:
    name: letsencrypt-cert-issuer
    kind: ClusterIssuer
  commonName: suse-ai.${var.instance_public_ip}.sslip.io
  dnsNames:
  - suse-ai.${var.instance_public_ip}.sslip.io
EOF
      echo "Applying certificate.yaml..."
      sudo /var/lib/rancher/rke2/bin/kubectl apply --kubeconfig /etc/rancher/rke2/rke2.yaml -f certificate.yaml
      EOT
    ]

    connection {
      type        = "ssh"
      user        = var.ssh_username
      private_key = var.ssh_private_key_content
      host        = var.instance_public_ip
    }
  }
}

resource "null_resource" "suse_ai_gateway_secure" {
  depends_on = [null_resource.suse_ai_cert, null_resource.suse_ai_gateway_init]

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      cat <<EOF > gateway-secure.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: suse-ai-gateway
  namespace: ${var.suse_ai_namespace}
spec:
  gatewayClassName: traefik
  listeners:
  - name: web
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
  - name: websecure
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
      - name: suse-ai-tls
    allowedRoutes:
      namespaces:
        from: All
EOF
      echo "Modifying gateway to add HTTPS support"
      sudo /var/lib/rancher/rke2/bin/kubectl apply --kubeconfig /etc/rancher/rke2/rke2.yaml -f gateway-secure.yaml
      EOT
    ]
   
    connection {
      type        = "ssh"
      user        = var.ssh_username
      private_key = var.ssh_private_key_content
      host        = var.instance_public_ip
    }
  }
}

## Adding SUSE-AI-DEPLOYER using helm to deploy SUSE AI components:
resource "helm_release" "suse_ai_deployer" {
  name             = "suse-ai"
  namespace        = "suse-ai"
  repository       = "oci://${var.registry_name}/charts"
  chart            = "suse-ai-deployer"
  version          = var.deployer_chart_version
  create_namespace = true
  timeout          = 1200
  depends_on       = [kubernetes_secret_v1.suse-appco-registry, null_resource.validate_kubernetes_connection, helm_release.cert_manager, helm_release.nvidia_gpu_operator, null_resource.suse_ai_gateway_init, null_resource.suse_ai_gateway_secure]

  values = [file("${path.module}/custom_suseai_deployer_values.yaml")]
}

## 4. Create HTTPRoute for Open-WebUI
resource "null_resource" "open_webui_httproute" {
  depends_on = [helm_release.suse_ai_deployer, null_resource.suse_ai_gateway_init, null_resource.suse_ai_gateway_secure]

  provisioner "remote-exec" {
    inline = [
      # 1. Wait for the Gateway to be accepted by the controller
      "echo 'Waiting for suse-ai-gateway to be Accepted...'",
      "sudo /var/lib/rancher/rke2/bin/kubectl wait --kubeconfig /etc/rancher/rke2/rke2.yaml --for=condition=Accepted gateway/suse-ai-gateway -n ${var.suse_ai_namespace} --timeout=300s",

      # 2. Create the HTTPRoute manifest
      <<-EOT
      cat <<EOF > openwebui-route.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: open-webui
  namespace: ${var.suse_ai_namespace}
spec:
  hostnames:
  - suse-ai.${var.instance_public_ip}.sslip.io
  parentRefs:
  - name: suse-ai-gateway
    namespace: ${var.suse_ai_namespace}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: open-webui
      port: 80
EOF
      EOT
      ,
      # 3. Apply the route
      "echo 'Applying HTTPROUTE for openwebui....'",
      "sudo /var/lib/rancher/rke2/bin/kubectl apply --kubeconfig /etc/rancher/rke2/rke2.yaml -f openwebui-route.yaml"
    ]

    connection {
      type        = "ssh"
      user        = var.ssh_username
      private_key = var.ssh_private_key_content
      host        = var.instance_public_ip
    }
  }
}
