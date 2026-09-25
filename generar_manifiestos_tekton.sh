#!/usr/bin/env bash
# =============================================================================
# GENERADOR DE MANIFIESTOS TEKTON + K8S (MULTI-ENTORNO: DEV / PROD)
# Clúster ESPOCH K3s - Líneas de Fábrica CI/CD
# =============================================================================

set -euo pipefail

# Colores para salida de terminal
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# Variables por defecto
ENVIRONMENT=""
APP_NAME=""
NAMESPACE=""
GIT_REPO_URL=""
GIT_BRANCH=""
HARBOR_IMAGE=""
WEBHOOK_PATH=""
INGRESS_HOST="pruebas.espoch.edu.ec"
APP_HOST=""
CONTAINER_PORT="3000"
SIGN_IMAGE=""
OUTPUT_DIR=""
DEPLOY_MANIFEST_PATH=""
AUTO_CONFIRM=0

# Procesar argumentos de línea de comandos si se proporcionaron
while getopts "e:a:n:g:b:h:w:i:p:c:s:o:d:y" opt; do
  case ${opt} in
    e) ENVIRONMENT="$OPTARG" ;;
    a) APP_NAME="$OPTARG" ;;
    n) NAMESPACE="$OPTARG" ;;
    g) GIT_REPO_URL="$OPTARG" ;;
    b) GIT_BRANCH="$OPTARG" ;;
    h) HARBOR_IMAGE="$OPTARG" ;;
    w) WEBHOOK_PATH="$OPTARG" ;;
    i) INGRESS_HOST="$OPTARG" ;;
    p) APP_HOST="$OPTARG" ;;
    c) CONTAINER_PORT="$OPTARG" ;;
    s) SIGN_IMAGE="$OPTARG" ;;
    o) OUTPUT_DIR="$OPTARG" ;;
    d) DEPLOY_MANIFEST_PATH="$OPTARG" ;;
    y) AUTO_CONFIRM=1 ;;
    \?) echo "Uso: $0 [-e dev|prod] [-a app_name] [-n namespace] [-g git_url] [-b branch] [-p app_host] [-s true|false] [-o out_dir] [-y]" >&2; exit 1 ;;
  esac
done

echo -e "${CYAN}=================================================================${NC}"
echo -e "${CYAN}   GENERADOR DE MANIFIESTOS TEKTON + K8S (LINUX BASH)            ${NC}"
echo -e "${CYAN}=================================================================${NC}"

# 1. Seleccionar Entorno (dev / prod)
if [ -z "$ENVIRONMENT" ]; then
    echo -e "\n${YELLOW}Seleccione el entorno a desplegar:${NC}"
    echo -e "  [1] dev / test (Desarrollo / Pruebas)"
    echo -e "  [2] prod       (Produccion)"
    read -rp "Ingrese opcion (1 o 2) [Por defecto: 1]: " env_input
    env_input="${env_input:-1}"
    if [ "$env_input" = "2" ] || [ "$env_input" = "prod" ] || [ "$env_input" = "production" ]; then
        ENVIRONMENT="prod"
    else
        ENVIRONMENT="dev"
    fi
else
    if [ "$ENVIRONMENT" = "prod" ] || [ "$ENVIRONMENT" = "production" ]; then
        ENVIRONMENT="prod"
    else
        ENVIRONMENT="dev"
    fi
fi

if [ "$ENVIRONMENT" = "prod" ]; then
    ENV_LABEL="PRODUCCION (prod)"
else
    ENV_LABEL="DESARROLLO (dev)"
fi
echo -e "${GREEN}Entorno seleccionado: ${ENV_LABEL}${NC}"

# 2. Solicitar Nombre de la App
WAS_APP_PROMPTED=0
if [ -z "$APP_NAME" ]; then
    WAS_APP_PROMPTED=1
    while [ -z "$APP_NAME" ]; do
        read -rp "Ingrese el nombre de la App/Componente (ej. evaluaciondocente-backend): " APP_NAME
        APP_NAME=$(echo "$APP_NAME" | tr -d ' ' | tr '[:upper:]' '[:lower:]' | tr '_' '-')
        if [ -z "$APP_NAME" ]; then
            echo -e "${YELLOW}El nombre de la App no puede estar vacio.${NC}"
        fi
    done
fi
APP_NAME=$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-')

# 3. Namespace según entorno
if [ "$ENVIRONMENT" = "prod" ]; then
    DEFAULT_NAMESPACE="${APP_NAME}-prod"
else
    DEFAULT_NAMESPACE="${APP_NAME}-test"
fi

if [ -z "$NAMESPACE" ]; then
    if [ "$WAS_APP_PROMPTED" -eq 1 ]; then
        read -rp "Ingrese el Namespace K8s [Por defecto: ${DEFAULT_NAMESPACE}]: " input_ns
        NAMESPACE="${input_ns:-$DEFAULT_NAMESPACE}"
    else
        NAMESPACE="$DEFAULT_NAMESPACE"
    fi
fi
NAMESPACE=$(echo "$NAMESPACE" | tr '[:upper:]' '[:lower:]' | tr '_' '-')

# 4. URL del Repositorio Git
while [ -z "$GIT_REPO_URL" ]; do
    read -rp "Ingrese la URL del repositorio Git (ej. https://github.com/desarrolloESPOCH/SW_miApp.git): " GIT_REPO_URL
    GIT_REPO_URL=$(echo "$GIT_REPO_URL" | tr -d ' ')
    if [ -z "$GIT_REPO_URL" ]; then
        echo -e "${YELLOW}La URL del repositorio es obligatoria.${NC}"
    fi
done

# 5. Rama Git activadora
if [ "$ENVIRONMENT" = "prod" ]; then
    DEFAULT_BRANCH="master"
else
    DEFAULT_BRANCH="dev"
fi

if [ -z "$GIT_BRANCH" ]; then
    if [ "$WAS_APP_PROMPTED" -eq 1 ]; then
        read -rp "Rama Git activadora [Por defecto: ${DEFAULT_BRANCH}]: " input_branch
        GIT_BRANCH="${input_branch:-$DEFAULT_BRANCH}"
    else
        GIT_BRANCH="$DEFAULT_BRANCH"
    fi
fi

# 6. Imagen Harbor por defecto
if [ -z "$HARBOR_IMAGE" ]; then
    HARBOR_IMAGE="pruebas10.espoch.edu.ec/${NAMESPACE}/${APP_NAME}"
fi
REGISTRY_HOST=$(echo "$HARBOR_IMAGE" | cut -d'/' -f1)

# 7. Webhook Path por defecto
if [ -z "$WEBHOOK_PATH" ]; then
    CLEAN_APP=$(echo "$APP_NAME" | tr -d '-')
    WEBHOOK_PATH="/listener${CLEAN_APP}-${ENVIRONMENT}"
fi
[[ "$WEBHOOK_PATH" != /* ]] && WEBHOOK_PATH="/${WEBHOOK_PATH}"

# 8. Host Ingress de la App (Para usuarios)
CLEAN_APP_HOST=$(echo "$APP_NAME" | tr -d '-')
if [ "$ENVIRONMENT" = "prod" ]; then
    DEFAULT_APP_HOST="api${CLEAN_APP_HOST}.espoch.edu.ec"
else
    DEFAULT_APP_HOST="apipruebas-${CLEAN_APP_HOST}.espoch.edu.ec"
fi

if [ -z "$APP_HOST" ]; then
    if [ "$WAS_APP_PROMPTED" -eq 1 ]; then
        read -rp "Dominio Ingress para la App (Usuarios) [Por defecto: ${DEFAULT_APP_HOST}]: " input_app_host
        APP_HOST="${input_app_host:-$DEFAULT_APP_HOST}"
    else
        APP_HOST="$DEFAULT_APP_HOST"
    fi
fi
# Sanitizar a FQDN puro (remover https://, http://, rutas y barras diagonales)
APP_HOST=$(echo "$APP_HOST" | sed -E 's#^https?://##' | cut -d'/' -f1 | tr -d ' ')
INGRESS_HOST=$(echo "$INGRESS_HOST" | sed -E 's#^https?://##' | cut -d'/' -f1 | tr -d ' ')

# 9. Puerto del contenedor
if [ "$WAS_APP_PROMPTED" -eq 1 ]; then
    read -rp "Puerto interno del contenedor [Por defecto: ${CONTAINER_PORT}]: " input_port
    CONTAINER_PORT="${input_port:-$CONTAINER_PORT}"
fi

# 10. Preguntar si desea firmar la imagen con Cosign
if [ -z "$SIGN_IMAGE" ]; then
    if [ "$WAS_APP_PROMPTED" -eq 1 ]; then
        read -rp "Desea firmar la imagen con Cosign en Harbor? (S/n) [Por defecto: S]: " input_sign
        input_sign="${input_sign:-S}"
        if [ "$input_sign" = "S" ] || [ "$input_sign" = "s" ] || [ "$input_sign" = "si" ] || [ "$input_sign" = "SI" ] || [ "$input_sign" = "y" ] || [ "$input_sign" = "Y" ]; then
            SIGN_IMAGE="true"
        else
            SIGN_IMAGE="false"
        fi
    else
        SIGN_IMAGE="true"
    fi
else
    if [ "$SIGN_IMAGE" = "s" ] || [ "$SIGN_IMAGE" = "S" ] || [ "$SIGN_IMAGE" = "si" ] || [ "$SIGN_IMAGE" = "SI" ] || [ "$SIGN_IMAGE" = "true" ] || [ "$SIGN_IMAGE" = "1" ] || [ "$SIGN_IMAGE" = "yes" ] || [ "$SIGN_IMAGE" = "y" ]; then
        SIGN_IMAGE="true"
    else
        SIGN_IMAGE="false"
    fi
fi

if [ "$SIGN_IMAGE" = "true" ]; then
    SIGN_LABEL="Habilitada (requiere cosign-secret)"
else
    SIGN_LABEL="Deshabilitada (sin cosign)"
fi

# 11. Ruta Write-Back en el repositorio
if [ -z "$DEPLOY_MANIFEST_PATH" ]; then
    DEPLOY_MANIFEST_PATH="k8s/${ENVIRONMENT}/deployment.yml"
fi

# 12. Directorios de salida
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PARENT_DIR="$(basename "$SCRIPT_DIR")"
    if [ "$PARENT_DIR" = "generador_lineas_fabrica" ] || [ "$PARENT_DIR" = "generador_cicd" ]; then
        WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
    elif [ "$PARENT_DIR" = "scripts_globales" ]; then
        WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
    else
        WORKSPACE_ROOT="$(pwd)"
    fi
else
    WORKSPACE_ROOT="$(pwd)"
fi

if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="${WORKSPACE_ROOT}/kubernetes/manifests/${APP_NAME}/${ENVIRONMENT}"
fi

K8S_APP_DIR="${OUTPUT_DIR}/k8s/${ENVIRONMENT}"

# Nombres estandarizados
SERVICE_ACCOUNT_NAME="tekton-triggers-admin"
ROLE_NAME="tekton-listener-role"
BINDING_NAME="${APP_NAME}-${ENVIRONMENT}-binding"
TEMPLATE_NAME="${APP_NAME}-${ENVIRONMENT}-template"
LISTENER_NAME="${APP_NAME}-${ENVIRONMENT}-listener"
PIPELINE_NAME="${APP_NAME}-${ENVIRONMENT}-pipeline"
INGRESS_NAME="${APP_NAME}-${ENVIRONMENT}-webhook-ingress"
EL_SERVICE_NAME="el-${LISTENER_NAME}"
CLEAN_GIT_REPO_URL=$(echo "$GIT_REPO_URL" | sed -E 's#^https?://##')

APP_K8S_NAME="sw-${APP_NAME}"
APP_SVC_NAME="sw-${APP_NAME}-svc"
APP_INGRESS_NAME="sw-${APP_NAME}-ingress"
APP_HPA_NAME="sw-${APP_NAME}-hpa"

if [ "$ENVIRONMENT" = "prod" ]; then
    APP_REPLICAS=4
    APP_MAX_REPLICAS=8
    APP_CPU_REQ="250m"
    APP_MEM_REQ="512Mi"
    APP_CPU_LIM="1000m"
    APP_MEM_LIM="1Gi"
else
    APP_REPLICAS=2
    APP_MAX_REPLICAS=5
    APP_CPU_REQ="100m"
    APP_MEM_REQ="256Mi"
    APP_CPU_LIM="500m"
    APP_MEM_LIM="512Mi"
fi

# =============================================================================
# RESUMEN PREVIO ANTES DE CONSTRUIR
# =============================================================================
echo -e "\n${MAGENTA}=================================================================${NC}"
echo -e "${MAGENTA}📋 RESUMEN DE CONFIGURACION (${ENV_LABEL})${NC}"
echo -e "${MAGENTA}=================================================================${NC}"
echo -e "  - Entorno:             ${ENVIRONMENT}"
echo -e "  - App / Componente:    ${APP_NAME}"
echo -e "  - Namespace K8s:       ${NAMESPACE}"
echo -e "  - Repositorio Git:     ${GIT_REPO_URL}"
echo -e "  - Rama activadora:     ${GIT_BRANCH}"
echo -e "  - Imagen en Harbor:    ${HARBOR_IMAGE}"
echo -e "  - Firma Cosign:        ${SIGN_LABEL}"
echo -e "  - Webhook Tekton:      https://${INGRESS_HOST}${WEBHOOK_PATH}"
echo -e "  - Ingress de la App:   https://${APP_HOST}/ (Puerto: ${CONTAINER_PORT})"
echo -e "  - Path Write-Back:     ${DEPLOY_MANIFEST_PATH}"
echo -e "  - Salida Tekton:       ${OUTPUT_DIR}"
echo -e "  - Salida App k8s/:     ${K8S_APP_DIR}"
echo -e "${GRAY}-----------------------------------------------------------------${NC}"

# Confirmación antes de generar
if [ "$WAS_APP_PROMPTED" -eq 1 ] && [ "$AUTO_CONFIRM" -eq 0 ]; then
    read -rp "Desea generar los manifiestos con esta configuracion? (S/n) [Por defecto: S]: " confirm
    confirm="${confirm:-S}"
    if [ "$confirm" != "S" ] && [ "$confirm" != "s" ] && [ "$confirm" != "si" ] && [ "$confirm" != "SI" ] && [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo -e "${YELLOW}Operacion cancelada por el usuario.${NC}"
        exit 0
    fi
fi

mkdir -p "$OUTPUT_DIR"
mkdir -p "$K8S_APP_DIR"

# =============================================================================
# MANIFIESTOS TEKTON CI/CD (CLÚSTER)
# =============================================================================
echo -e "\n${CYAN}Generando manifiestos Tekton CI/CD...${NC}"

# 01-rbac.yaml
cat <<EOF > "${OUTPUT_DIR}/01-rbac.yaml"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SERVICE_ACCOUNT_NAME}
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${ROLE_NAME}
  namespace: ${NAMESPACE}
rules:
  - apiGroups: ["triggers.tekton.dev"]
    resources: ["eventlisteners", "triggerbindings", "triggertemplates", "interceptors", "clusterinterceptors", "clustertriggerbindings", "triggers"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["tekton.dev"]
    resources: ["pipelineruns", "pipelines"]
    verbs: ["create", "get", "list", "watch"]
  - apiGroups: [""]
    resources: ["configmaps", "serviceaccounts", "secrets"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tekton-listener-binding
  namespace: ${NAMESPACE}
subjects:
  - kind: ServiceAccount
    name: ${SERVICE_ACCOUNT_NAME}
    namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${ROLE_NAME}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tekton-triggers-cel-${NAMESPACE}
subjects:
  - kind: ServiceAccount
    name: ${SERVICE_ACCOUNT_NAME}
    namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tekton-triggers-eventlistener-clusterroles
EOF
echo -e "  ${GREEN}[OK] Generado: 01-rbac.yaml${NC}"

# 02-triggerbinding.yaml
cat <<EOF > "${OUTPUT_DIR}/02-triggerbinding.yaml"
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerBinding
metadata:
  name: ${BINDING_NAME}
  namespace: ${NAMESPACE}
spec:
  params:
  - name: gitrevision
    value: \$(body.head_commit.id)
  - name: gitrepositoryurl
    value: \$(body.repository.clone_url)
  - name: repositoryname
    value: \$(body.repository.name)
EOF
echo -e "  ${GREEN}[OK] Generado: 02-triggerbinding.yaml${NC}"

# 03-triggertemplate.yaml
cat <<EOF > "${OUTPUT_DIR}/03-triggertemplate.yaml"
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerTemplate
metadata:
  name: ${TEMPLATE_NAME}
  namespace: ${NAMESPACE}
spec:
  params:
  - description: The git revision
    name: gitrevision
  - description: The git repository url
    name: gitrepositoryurl
  - description: The name of the repository (to determine which image to build)
    name: repositoryname
  resourceTemplates:
  - apiVersion: tekton.dev/v1
    kind: PipelineRun
    metadata:
      generateName: ${APP_NAME}-${ENVIRONMENT}-run-
      namespace: ${NAMESPACE}
    spec:
      params:
      - name: repo-url
        value: \$(tt.params.gitrepositoryurl)
      - name: revision
        value: \$(tt.params.gitrevision)
      pipelineRef:
        name: ${PIPELINE_NAME}
      workspaces:
      - name: source-workspace
        volumeClaimTemplate:
          spec:
            accessModes:
            - ReadWriteOnce
            resources:
              requests:
                storage: 1Gi
      - name: docker-credentials
        secret:
          secretName: harbor-env
EOF
echo -e "  ${GREEN}[OK] Generado: 03-triggertemplate.yaml${NC}"

# 04-eventlistener.yaml
cat <<EOF > "${OUTPUT_DIR}/04-eventlistener.yaml"
apiVersion: triggers.tekton.dev/v1beta1
kind: EventListener
metadata:
  name: ${LISTENER_NAME}
  namespace: ${NAMESPACE}
spec:
  serviceAccountName: ${SERVICE_ACCOUNT_NAME}
  triggers:
  - name: ${ENVIRONMENT}-push-trigger
    interceptors:
    - ref:
        kind: ClusterInterceptor
        name: cel
      params:
      - name: filter
        value: "body.ref == 'refs/heads/${GIT_BRANCH}' && !body.head_commit.message.contains('[skip ci]')"
    bindings:
    - kind: TriggerBinding
      ref: ${BINDING_NAME}
    template:
      ref: ${TEMPLATE_NAME}
EOF
echo -e "  ${GREEN}[OK] Generado: 04-eventlistener.yaml${NC}"

# 05-webhook-ingress.yaml
cat <<EOF > "${OUTPUT_DIR}/05-webhook-ingress.yaml"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${INGRESS_NAME}
  namespace: ${NAMESPACE}
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - host: ${INGRESS_HOST}
    http:
      paths:
      - path: ${WEBHOOK_PATH}
        pathType: Prefix
        backend:
          service:
            name: ${EL_SERVICE_NAME}
            port:
              number: 8080
EOF
echo -e "  ${GREEN}[OK] Generado: 05-webhook-ingress.yaml${NC}"

# 06-pipeline.yaml
cat <<EOF > "${OUTPUT_DIR}/06-pipeline.yaml"
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: ${PIPELINE_NAME}
  namespace: ${NAMESPACE}
spec:
  params:
  - default: ${GIT_REPO_URL}
    name: repo-url
    type: string
  - description: Commit SHA o rama a compilar
    name: revision
    type: string
  tasks:
  - name: fetch-repository
    taskSpec:
      metadata: {}
      spec: null
      steps:
      - computeResources: {}
        env:
        - name: GITHUB_TOKEN
          valueFrom:
            secretKeyRef:
              key: token
              name: github-credentials
              optional: true
        image: alpine/git:latest
        name: clone-repo
        script: |
          #!/bin/sh
          set -e
          cd \$(workspaces.output.path)
          # Limpiar archivos previos si el volumen fue reutilizado
          find . -mindepth 1 -not -name "lost+found" -delete

          REPO_URL="\$(params.repo-url)"
          if [ -n "\$GITHUB_TOKEN" ]; then
            REPO_URL=\$(echo "\$REPO_URL" | sed "s#https://#https://x-access-token:\${GITHUB_TOKEN}@#")
          fi

          git init .
          git remote add origin "\$REPO_URL"
          git fetch --depth 1 origin \$(params.revision) || git fetch origin \$(params.revision)
          git checkout FETCH_HEAD
      workspaces:
      - name: output
    workspaces:
    - name: output
      workspace: source-workspace
  - name: build-and-push
    runAfter:
    - fetch-repository
    taskSpec:
      metadata: {}
      spec: null
      steps:
      - computeResources: {}
        env:
        - name: HARBOR_USER
          valueFrom:
            secretKeyRef:
              key: HARBOR_USERNAME
              name: harbor-env
        - name: HARBOR_PASSWORD
          valueFrom:
            secretKeyRef:
              key: HARBOR_TOKEN
              name: harbor-env
        image: gcr.io/kaniko-project/executor:debug
        name: build-and-push
        script: |
          #!/busybox/sh
          set -e
          mkdir -p /kaniko/.docker
          AUTH=\$(echo -n "\$HARBOR_USER:\$HARBOR_PASSWORD" | base64 | tr -d '\n')
          echo "{\"auths\":{\"${REGISTRY_HOST}\":{\"auth\":\"\$AUTH\"}}}" > /kaniko/.docker/config.json

          /kaniko/executor \\
            --context=\$(workspaces.source.path) \\
            --dockerfile=\$(workspaces.source.path)/dockerfile \\
            --destination=${HARBOR_IMAGE}:\$(params.revision)
      workspaces:
      - name: source
    workspaces:
    - name: source
      workspace: source-workspace
EOF

if [ "$SIGN_IMAGE" = "true" ]; then
cat <<EOF >> "${OUTPUT_DIR}/06-pipeline.yaml"
  - name: sign-image
    runAfter:
    - build-and-push
    taskSpec:
      metadata: {}
      spec: null
      steps:
      - computeResources: {}
        env:
        - name: HARBOR_USER
          valueFrom:
            secretKeyRef:
              key: HARBOR_USERNAME
              name: harbor-env
        - name: HARBOR_PASSWORD
          valueFrom:
            secretKeyRef:
              key: HARBOR_TOKEN
              name: harbor-env
        - name: COSIGN_PRIVATE_KEY
          valueFrom:
            secretKeyRef:
              key: cosign.key
              name: cosign-secret
        - name: COSIGN_PASSWORD
          valueFrom:
            secretKeyRef:
              key: cosign.password
              name: cosign-secret
        image: bitnami/cosign:latest
        name: cosign-sign
        script: |
          #!/bin/sh
          set -e
          export DOCKER_CONFIG=/tmp/.docker
          mkdir -p /tmp/.docker
          echo -n "\$HARBOR_PASSWORD" | cosign login ${REGISTRY_HOST} -u "\$HARBOR_USER" --password-stdin
          echo "\$COSIGN_PRIVATE_KEY" > /tmp/cosign.key
          cosign sign --yes --key /tmp/cosign.key ${HARBOR_IMAGE}:\$(params.revision)
          rm -f /tmp/cosign.key
EOF
    UPDATE_MANIFEST_RUN_AFTER="sign-image"
else
    UPDATE_MANIFEST_RUN_AFTER="build-and-push"
fi

cat <<EOF >> "${OUTPUT_DIR}/06-pipeline.yaml"
  - name: update-manifest
    runAfter:
    - ${UPDATE_MANIFEST_RUN_AFTER}
    taskSpec:
      metadata: {}
      spec: null
      steps:
      - computeResources: {}
        env:
        - name: GITHUB_TOKEN
          valueFrom:
            secretKeyRef:
              key: token
              name: github-credentials
              optional: true
        image: alpine/git:latest
        name: update-yaml-and-push
        script: |
          #!/bin/sh
          cd \$(workspaces.source.path)

          # Reemplazar la etiqueta de la imagen en ${DEPLOY_MANIFEST_PATH}
          sed -i "s|image:.*${APP_NAME}.*|image: ${HARBOR_IMAGE}:\$(params.revision)|g" ${DEPLOY_MANIFEST_PATH}

          # Configurar usuario Git
          git config user.name "tekton-pipeline[bot]"
          git config user.email "tekton-pipeline[bot]@users.noreply.github.com"

          # Configurar autenticacion remota si existe GITHUB_TOKEN
          if [ -n "\$GITHUB_TOKEN" ]; then
            git remote set-url origin https://x-access-token:\${GITHUB_TOKEN}@${CLEAN_GIT_REPO_URL}
          fi

          git add ${DEPLOY_MANIFEST_PATH}
          git commit -m "chore(cd): update image tag to \$(params.revision) [skip ci]"
          git push origin HEAD:${GIT_BRANCH}
      workspaces:
      - name: source
    workspaces:
    - name: source
      workspace: source-workspace
  workspaces:
  - name: source-workspace
  - name: docker-credentials
EOF
echo -e "  ${GREEN}[OK] Generado: 06-pipeline.yaml${NC}"

# =============================================================================
# MANIFIESTOS DE LA APLICACIÓN (CARPETA k8s/ PARA EL REPO DE LA APP Y ARGO CD)
# =============================================================================
echo -e "\n${CYAN}Generando manifiestos de la aplicacion en: ${K8S_APP_DIR}...${NC}"

# k8s/<entorno>/deployment.yml
cat <<EOF > "${K8S_APP_DIR}/deployment.yml"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_K8S_NAME}
  namespace: ${NAMESPACE}
spec:
  replicas: ${APP_REPLICAS}
  selector:
    matchLabels:
      app: ${APP_K8S_NAME}
  template:
    metadata:
      labels:
        app: ${APP_K8S_NAME}
    spec:
      imagePullSecrets:
        - name: harbor-registry-secret
      containers:
        - name: ${APP_K8S_NAME}
          image: ${HARBOR_IMAGE}:latest
          ports:
            - containerPort: ${CONTAINER_PORT}
          envFrom:
            - secretRef:
                name: backend-env
                optional: true
          resources:
            requests:
              cpu: "${APP_CPU_REQ}"
              memory: "${APP_MEM_REQ}"
            limits:
              cpu: "${APP_CPU_LIM}"
              memory: "${APP_MEM_LIM}"
EOF
echo -e "  ${GREEN}[OK] Generado: k8s/${ENVIRONMENT}/deployment.yml${NC}"

# k8s/<entorno>/service.yml
cat <<EOF > "${K8S_APP_DIR}/service.yml"
apiVersion: v1
kind: Service
metadata:
  name: ${APP_SVC_NAME}
  namespace: ${NAMESPACE}
spec:
  type: ClusterIP
  selector:
    app: ${APP_K8S_NAME}
  ports:
    - protocol: TCP
      port: 80
      targetPort: ${CONTAINER_PORT}
EOF
echo -e "  ${GREEN}[OK] Generado: k8s/${ENVIRONMENT}/service.yml${NC}"

# k8s/<entorno>/ingress.yml
cat <<EOF > "${K8S_APP_DIR}/ingress.yml"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${APP_INGRESS_NAME}
  namespace: ${NAMESPACE}
spec:
  ingressClassName: nginx
  rules:
    - host: ${APP_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${APP_SVC_NAME}
                port:
                  number: 80
EOF
echo -e "  ${GREEN}[OK] Generado: k8s/${ENVIRONMENT}/ingress.yml${NC}"

# k8s/<entorno>/hpa.yml
cat <<EOF > "${K8S_APP_DIR}/hpa.yml"
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${APP_HPA_NAME}
  namespace: ${NAMESPACE}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${APP_K8S_NAME}
  minReplicas: ${APP_REPLICAS}
  maxReplicas: ${APP_MAX_REPLICAS}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 75
EOF
echo -e "  ${GREEN}[OK] Generado: k8s/${ENVIRONMENT}/hpa.yml${NC}"

echo -e "\n${CYAN}=================================================================${NC}"
echo -e "${GREEN}Manifiestos generados exitosamente (${ENV_LABEL})${NC}"
echo -e "  1. Pipeline Tekton (Clúster): ${OUTPUT_DIR}"
echo -e "  2. Manifiestos App (Repo Git): ${K8S_APP_DIR}"
echo -e "${CYAN}=================================================================${NC}"

echo -e "\n${YELLOW}PASOS SIGUIENTES PARA DESPLEGAR EN ${ENV_LABEL}:${NC}"
echo -e "${GRAY}1. Crear el namespace (si no existe):${NC}"
echo -e "   kubectl create namespace ${NAMESPACE}"
echo -e "\n${GRAY}2. Inyectar secretos en el namespace ${NAMESPACE}:${NC}"
echo -e "   - harbor-env (HARBOR_USERNAME, HARBOR_TOKEN)"
echo -e "   - github-credentials (token)"
if [ "$SIGN_IMAGE" = "true" ]; then
    echo -e "   - cosign-secret (cosign.key, cosign.password)"
fi
echo -e "   - harbor-registry-secret (Secret tipo docker-registry para los Pods)"
echo -e "\n${GRAY}3. Aplicar los manifiestos de Tekton en el clúster (incluye RBAC + ClusterRoleBinding):${NC}"
echo -e "   kubectl apply -f \"${OUTPUT_DIR}\""
echo -e "\n${GRAY}4. Copiar la carpeta 'k8s/${ENVIRONMENT}' al repositorio de tu App (${GIT_REPO_URL}) y hacer push:${NC}"
echo -e "   git add k8s/ && git commit -m 'chore: add k8s manifests' && git push origin ${GIT_BRANCH}"
echo -e "\n${GRAY}5. Configurar Webhook en GitHub (${GIT_REPO_URL}):${NC}"
echo -e "   - ${GREEN}Payload URL:${NC}  https://${INGRESS_HOST}${WEBHOOK_PATH}"
echo -e "   - ${GREEN}Content Type:${NC} application/json"
echo -e "   - ${GREEN}Events:${NC}       Just the push event (Rama: ${GIT_BRANCH})"
echo -e "\n${GRAY}6. Crear la Application en Argo CD apuntando al path: k8s/${ENVIRONMENT}${NC}"
