param(
    [Parameter()]
    [string]$Environment,

    [Parameter()]
    [string]$AppName,

    [Parameter()]
    [string]$Namespace,

    [Parameter()]
    [string]$GitRepoUrl,

    [Parameter()]
    [string]$GitBranch,

    [Parameter()]
    [string]$HarborImage,

    [Parameter()]
    [string]$WebhookPath,

    [Parameter()]
    [string]$IngressHost = "pruebas.espoch.edu.ec",

    [Parameter()]
    [string]$AppHost,

    [Parameter()]
    [int]$ContainerPort = 3000,

    [Parameter()]
    [Nullable[bool]]$SignImage,

    [Parameter()]
    [string]$OutputDir,

    [Parameter()]
    [string]$DeployManifestPath,

    [Parameter()]
    [switch]$Yes
)

# Configurar codificacion UTF-8
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "   GENERADOR DE MANIFIESTOS TEKTON + K8S (MULTI-ENTORNO)         " -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

# 1. Seleccionar Entorno (dev / prod)
if ([string]::IsNullOrWhiteSpace($Environment)) {
    Write-Host ""
    Write-Host "Seleccione el entorno a desplegar:" -ForegroundColor Yellow
    Write-Host "  [1] dev / test (Desarrollo / Pruebas)" -ForegroundColor White
    Write-Host "  [2] prod       (Produccion)" -ForegroundColor White
    
    while ($true) {
        $opcion = (Read-Host "Ingrese opcion (1 o 2) [Por defecto: 1]").Trim()
        if ($opcion -eq "" -or $opcion -eq "1" -or $opcion.ToLower() -eq "dev" -or $opcion.ToLower() -eq "test") {
            $Environment = "dev"
            break
        } elseif ($opcion -eq "2" -or $opcion.ToLower() -eq "prod" -or $opcion.ToLower() -eq "production") {
            $Environment = "prod"
            break
        } else {
            Write-Host "Opcion invalida. Ingrese 1 para dev o 2 para prod." -ForegroundColor Yellow
        }
    }
} else {
    if ($Environment -eq "prod" -or $Environment -eq "production") {
        $Environment = "prod"
    } else {
        $Environment = "dev"
    }
}

$isProd = ($Environment -eq "prod")
if ($isProd) {
    $envLabel = "PRODUCCION (prod)"
} else {
    $envLabel = "DESARROLLO (dev)"
}
Write-Host "Entorno seleccionado: $envLabel" -ForegroundColor Green

# 2. Solicitar Nombre de la App si no fue enviado por parametro
$wasAppPrompted = $false
if ([string]::IsNullOrWhiteSpace($AppName)) {
    $wasAppPrompted = $true
    while ([string]::IsNullOrWhiteSpace($AppName)) {
        $AppName = (Read-Host "Ingrese el nombre de la App/Componente (ej. evaluaciondocente-backend)").Trim()
        if ([string]::IsNullOrWhiteSpace($AppName)) {
            Write-Host "El nombre de la App no puede estar vacio." -ForegroundColor Yellow
        }
    }
}
$AppName = $AppName.ToLower().Replace("_", "-")

# 3. Calcular Namespace por defecto según entorno
if ($isProd) {
    $defaultNamespace = "$AppName-prod"
} else {
    $defaultNamespace = "$AppName-test"
}

if ([string]::IsNullOrWhiteSpace($Namespace)) {
    if ($wasAppPrompted) {
        $inputNs = (Read-Host "Ingrese el Namespace K8s [Por defecto: $defaultNamespace]").Trim()
        if ([string]::IsNullOrWhiteSpace($inputNs)) {
            $Namespace = $defaultNamespace
        } else {
            $Namespace = $inputNs
        }
    } else {
        $Namespace = $defaultNamespace
    }
}
$sanitizedNamespace = $Namespace.ToLower().Replace("_", "-")

# 4. Solicitar URL del Repositorio Git
while ([string]::IsNullOrWhiteSpace($GitRepoUrl)) {
    $GitRepoUrl = (Read-Host "Ingrese la URL del repositorio Git (ej. https://github.com/desarrolloESPOCH/SW_miApp.git)").Trim()
    if ([string]::IsNullOrWhiteSpace($GitRepoUrl)) {
        Write-Host "La URL del repositorio es obligatoria." -ForegroundColor Yellow
    }
}

# 5. Rama Git por defecto según entorno
if ($isProd) {
    $defaultBranch = "master"
} else {
    $defaultBranch = "dev"
}

if ([string]::IsNullOrWhiteSpace($GitBranch)) {
    if ($wasAppPrompted) {
        $inputBranch = (Read-Host "Rama Git activadora [Por defecto: $defaultBranch]").Trim()
        if ([string]::IsNullOrWhiteSpace($inputBranch)) {
            $GitBranch = $defaultBranch
        } else {
            $GitBranch = $inputBranch
        }
    } else {
        $GitBranch = $defaultBranch
    }
}

# 6. Imagen Harbor por defecto
if ([string]::IsNullOrWhiteSpace($HarborImage)) {
    $HarborImage = "pruebas10.espoch.edu.ec/${sanitizedNamespace}/${AppName}"
}
$RegistryHost = ($HarborImage -split "/")[0]

# 7. Webhook Path por defecto según entorno
if ([string]::IsNullOrWhiteSpace($WebhookPath)) {
    $cleanApp = $AppName.Replace("-", "")
    $WebhookPath = "/listener${cleanApp}-${Environment}"
}
if (-not $WebhookPath.StartsWith("/")) {
    $WebhookPath = "/$WebhookPath"
}

# 8. Host del Ingress de la App (Para usuarios finales)
$cleanAppForHost = $AppName.Replace("-", "")
if ($isProd) {
    $defaultAppHost = "api${cleanAppForHost}.espoch.edu.ec"
} else {
    $defaultAppHost = "apipruebas-${cleanAppForHost}.espoch.edu.ec"
}

if ([string]::IsNullOrWhiteSpace($AppHost)) {
    if ($wasAppPrompted) {
        $inputHost = (Read-Host "Dominio Ingress para la App (Usuarios) [Por defecto: $defaultAppHost]").Trim()
        if ([string]::IsNullOrWhiteSpace($inputHost)) {
            $AppHost = $defaultAppHost
        } else {
            $AppHost = $inputHost
        }
    } else {
        $AppHost = $defaultAppHost
    }
}
# Sanitizar a FQDN puro (remover https://, http://, rutas y barras diagonales)
$AppHost = ($AppHost.Trim() -replace '^https?://', '')
$AppHost = ($AppHost -split '/')[0].Trim()

$IngressHost = ($IngressHost.Trim() -replace '^https?://', '')
$IngressHost = ($IngressHost -split '/')[0].Trim()

# 9. Puerto del contenedor
if ($wasAppPrompted) {
    $inputPort = (Read-Host "Puerto interno del contenedor [Por defecto: $ContainerPort]").Trim()
    if (-not [string]::IsNullOrWhiteSpace($inputPort)) {
        $ContainerPort = [int]$inputPort
    }
}

# 10. Preguntar si desea firmar la imagen con Cosign
if ($null -eq $SignImage) {
    if ($wasAppPrompted) {
        $defaultSignOpt = if ($isProd) { "S" } else { "S" }
        $inputSign = (Read-Host "Desea firmar la imagen con Cosign en Harbor? (S/n) [Por defecto: $defaultSignOpt]").Trim()
        if ($inputSign -eq "" -or $inputSign.ToLower() -eq "s" -or $inputSign.ToLower() -eq "si" -or $inputSign.ToLower() -eq "y" -or $inputSign.ToLower() -eq "yes") {
            $SignImage = $true
        } else {
            $SignImage = $false
        }
    } else {
        $SignImage = $true
    }
}

# 11. Ruta del manifiesto deployment en el repo Git para Write-Back
if ([string]::IsNullOrWhiteSpace($DeployManifestPath)) {
    $DeployManifestPath = "k8s/${Environment}/deployment.yml"
}

# 12. Directorios de salida
if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $currentDir = Get-Item $PSScriptRoot
    if ($currentDir.Parent.Name -eq "scripts_globales") {
        $WorkspaceRoot = $currentDir.Parent.Parent.FullName
    } elseif ($currentDir.Name -eq "scripts_globales") {
        $WorkspaceRoot = $currentDir.Parent.FullName
    } else {
        $WorkspaceRoot = (Get-Location).Path
    }
} else {
    $WorkspaceRoot = (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $WorkspaceRoot "kubernetes\manifests\${AppName}\${Environment}"
}
$K8sAppDir = Join-Path $OutputDir "k8s\${Environment}"

# Nombres normalizados para recursos K8s
$ServiceAccountName = "tekton-triggers-admin"
$RoleName           = "tekton-listener-role"
$BindingName        = "${AppName}-${Environment}-binding"
$TemplateName       = "${AppName}-${Environment}-template"
$ListenerName       = "${AppName}-${Environment}-listener"
$PipelineName       = "${AppName}-${Environment}-pipeline"
$IngressName        = "${AppName}-${Environment}-webhook-ingress"
$ElServiceName      = "el-${ListenerName}"
$CleanGitRepoUrl    = $GitRepoUrl -replace '^https?://', ''

$AppK8sName         = "sw-${AppName}"
$AppSvcName         = "sw-${AppName}-svc"
$AppIngressName     = "sw-${AppName}-ingress"
$AppHpaName         = "sw-${AppName}-hpa"
if ($isProd) {
    $AppReplicas = 4
    $AppMaxReplicas = 8
    $AppCpuReq = "250m"
    $AppMemReq = "512Mi"
    $AppCpuLim = "1000m"
    $AppMemLim = "1Gi"
} else {
    $AppReplicas = 2
    $AppMaxReplicas = 5
    $AppCpuReq = "100m"
    $AppMemReq = "256Mi"
    $AppCpuLim = "500m"
    $AppMemLim = "512Mi"
}

$signLabel = if ($SignImage) { "Habilitada (requiere cosign-secret)" } else { "Deshabilitada" }

# =============================================================================
# RESUMEN PREVIO ANTES DE CONSTRUIR
# =============================================================================
Write-Host ""
Write-Host "=================================================================" -ForegroundColor Magenta
Write-Host "   RESUMEN DE CONFIGURACION ($envLabel)" -ForegroundColor Magenta
Write-Host "=================================================================" -ForegroundColor Magenta
Write-Host "  - Entorno:             $Environment"
Write-Host "  - App / Componente:    $AppName"
Write-Host "  - Namespace K8s:       $sanitizedNamespace"
Write-Host "  - Repositorio Git:     $GitRepoUrl"
Write-Host "  - Rama activadora:     $GitBranch"
Write-Host "  - Imagen en Harbor:    $HarborImage"
Write-Host "  - Firma Cosign:        $signLabel"
Write-Host "  - Webhook Tekton:      https://${IngressHost}${WebhookPath}"
Write-Host "  - Ingress de la App:   https://${AppHost}/ (Puerto: $ContainerPort)"
Write-Host "  - Path Write-Back:     $DeployManifestPath"
Write-Host "  - Salida Tekton:       $OutputDir"
Write-Host "  - Salida App k8s/:     $K8sAppDir"
Write-Host "-----------------------------------------------------------------" -ForegroundColor Gray

# Confirmación antes de generar
if ($wasAppPrompted -and -not $Yes) {
    $confirm = (Read-Host "Desea generar los manifiestos con esta configuracion? (S/n) [Por defecto: S]").Trim()
    if ($confirm -ne "" -and $confirm.ToLower() -ne "s" -and $confirm.ToLower() -ne "si" -and $confirm.ToLower() -ne "y" -and $confirm.ToLower() -ne "yes") {
        Write-Host "Operacion cancelada por el usuario." -ForegroundColor Yellow
        exit 0
    }
}

# Crear directorios de destino
if (-not (Test-Path -Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
if (-not (Test-Path -Path $K8sAppDir)) {
    New-Item -ItemType Directory -Path $K8sAppDir -Force | Out-Null
}

# =============================================================================
# MANIFIESTOS TEKTON CI/CD (CLÚSTER)
# =============================================================================
Write-Host ""
Write-Host "Generando manifiestos Tekton CI/CD..." -ForegroundColor Cyan

# 01-rbac.yaml
$file1 = @"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $ServiceAccountName
  namespace: $sanitizedNamespace
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: $RoleName
  namespace: $sanitizedNamespace
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
  namespace: $sanitizedNamespace
subjects:
  - kind: ServiceAccount
    name: $ServiceAccountName
    namespace: $sanitizedNamespace
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: $RoleName
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tekton-triggers-cel-$sanitizedNamespace
subjects:
  - kind: ServiceAccount
    name: $ServiceAccountName
    namespace: $sanitizedNamespace
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tekton-triggers-eventlistener-clusterroles
"@
[System.IO.File]::WriteAllText((Join-Path $OutputDir "01-rbac.yaml"), $file1.Trim(), [System.Text.Encoding]::UTF8)
Write-Host "  [OK] Generado: 01-rbac.yaml" -ForegroundColor Green

# 02-triggerbinding.yaml
$file2 = @"
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerBinding
metadata:
  name: $BindingName
  namespace: $sanitizedNamespace
spec:
  params:
  - name: gitrevision
    value: `$(body.head_commit.id)
  - name: gitrepositoryurl
    value: `$(body.repository.clone_url)
  - name: repositoryname
    value: `$(body.repository.name)
"@
[System.IO.File]::WriteAllText((Join-Path $OutputDir "02-triggerbinding.yaml"), $file2.Trim(), [System.Text.Encoding]::UTF8)
Write-Host "  [OK] Generado: 02-triggerbinding.yaml" -ForegroundColor Green

# 03-triggertemplate.yaml
$file3 = @"
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerTemplate
metadata:
  name: $TemplateName
  namespace: $sanitizedNamespace
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
      generateName: ${AppName}-${Environment}-run-
      namespace: $sanitizedNamespace
    spec:
      params:
      - name: repo-url
        value: `$(tt.params.gitrepositoryurl)
      - name: revision
        value: `$(tt.params.gitrevision)
      pipelineRef:
        name: $PipelineName
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
"@
[System.IO.File]::WriteAllText((Join-Path $OutputDir "03-triggertemplate.yaml"), $file3.Trim(), [System.Text.Encoding]::UTF8)
Write-Host "  [OK] Generado: 03-triggertemplate.yaml" -ForegroundColor Green

# 04-eventlistener.yaml
$file4 = @"
apiVersion: triggers.tekton.dev/v1beta1
kind: EventListener
metadata:
  name: $ListenerName
  namespace: $sanitizedNamespace
spec:
  serviceAccountName: $ServiceAccountName
  triggers:
  - name: ${Environment}-push-trigger
    interceptors:
    - ref:
        kind: ClusterInterceptor
        name: cel
      params:
      - name: filter
        value: "body.ref == 'refs/heads/$GitBranch' && !body.head_commit.message.contains('[skip ci]')"
    bindings:
    - kind: TriggerBinding
      ref: $BindingName
    template:
      ref: $TemplateName
"@
[System.IO.File]::WriteAllText((Join-Path $OutputDir "04-eventlistener.yaml"), $file4.Trim(), [System.Text.Encoding]::UTF8)
Write-Host "  [OK] Generado: 04-eventlistener.yaml" -ForegroundColor Green

# 05-webhook-ingress.yaml
$file5 = @"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $IngressName
  namespace: $sanitizedNamespace
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - host: $IngressHost
    http:
      paths:
      - path: $WebhookPath
        pathType: Prefix
        backend:
          service:
            name: $ElServiceName
            port:
              number: 8080
"@
[System.IO.File]::WriteAllText((Join-Path $OutputDir "05-webhook-ingress.yaml"), $file5.Trim(), [System.Text.Encoding]::UTF8)
Write-Host "  [OK] Generado: 05-webhook-ingress.yaml" -ForegroundColor Green

# 06-pipeline.yaml
$kanikoAuthJson = "{\`"auths\`":{\`"$RegistryHost\`":{\`"auth\`":\`"`$AUTH\`"}}}"

if ($SignImage) {
    $cosignTaskYaml = @"
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
          echo -n "`$HARBOR_PASSWORD" | cosign login $RegistryHost -u "`$HARBOR_USER" --password-stdin
          echo "`$COSIGN_PRIVATE_KEY" > /tmp/cosign.key
          cosign sign --yes --key /tmp/cosign.key ${HarborImage}:`$(params.revision)
          rm -f /tmp/cosign.key
"@
    $updateManifestRunAfter = "sign-image"
} else {
    $cosignTaskYaml = ""
    $updateManifestRunAfter = "build-and-push"
}

$file6 = @"
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: $PipelineName
  namespace: $sanitizedNamespace
spec:
  params:
  - default: $GitRepoUrl
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
          cd `$(workspaces.output.path)
          # Limpiar archivos previos si el volumen fue reutilizado
          find . -mindepth 1 -not -name "lost+found" -delete

          REPO_URL="`$(params.repo-url)"
          if [ -n "`$GITHUB_TOKEN" ]; then
            REPO_URL=`$(echo "`$REPO_URL" | sed "s#https://#https://x-access-token:`${GITHUB_TOKEN}@#")
          fi

          git init .
          git remote add origin "`$REPO_URL"
          git fetch --depth 1 origin `$(params.revision) || git fetch origin `$(params.revision)
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
          AUTH=`$(echo -n "`$HARBOR_USER:`$HARBOR_PASSWORD" | base64 | tr -d '\n')
          echo "$kanikoAuthJson" > /kaniko/.docker/config.json

          /kaniko/executor \
            --context=`$(workspaces.source.path) \
            --dockerfile=`$(workspaces.source.path)/dockerfile \
            --destination=${HarborImage}:`$(params.revision)
      workspaces:
      - name: source
    workspaces:
    - name: source
      workspace: source-workspace
$cosignTaskYaml
  - name: update-manifest
    runAfter:
    - $updateManifestRunAfter
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
          cd `$(workspaces.source.path)

          # Reemplazar la etiqueta de la imagen en $DeployManifestPath
          sed -i "s|image:.*${AppName}.*|image: ${HarborImage}:`$(params.revision)|g" $DeployManifestPath

          # Configurar usuario Git
          git config user.name "tekton-pipeline[bot]"
          git config user.email "tekton-pipeline[bot]@users.noreply.github.com"

          # Configurar autenticacion remota si existe GITHUB_TOKEN
          if [ -n "`$GITHUB_TOKEN" ]; then
            git remote set-url origin https://x-access-token:`${GITHUB_TOKEN}@$CleanGitRepoUrl
          fi

          git add $DeployManifestPath
          git commit -m "chore(cd): update image tag to `$(params.revision) [skip ci]"
          git push origin HEAD:$GitBranch
      workspaces:
      - name: source
    workspaces:
    - name: source
      workspace: source-workspace
  workspaces:
  - name: source-workspace
  - name: docker-credentials
"@
[System.IO.File]::WriteAllText((Join-Path $OutputDir "06-pipeline.yaml"), $file6.Trim(), [System.Text.Encoding]::UTF8)
Write-Host "  [OK] Generado: 06-pipeline.yaml" -ForegroundColor Green

# =============================================================================
# MANIFIESTOS DE LA APLICACIÓN (CARPETA k8s/ PARA EL REPO DE LA APP Y ARGO CD)
# =============================================================================
Write-Host ""
Write-Host "Generando manifiestos de la aplicacion en: $K8sAppDir" -ForegroundColor Cyan

# k8s/<entorno>/deployment.yml
$fileAppDeployment = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $AppK8sName
  namespace: $sanitizedNamespace
spec:
  replicas: $AppReplicas
  selector:
    matchLabels:
      app: $AppK8sName
  template:
    metadata:
      labels:
        app: $AppK8sName
    spec:
      imagePullSecrets:
        - name: harbor-registry-secret
      containers:
        - name: $AppK8sName
          image: ${HarborImage}:latest
          ports:
            - containerPort: $ContainerPort
          envFrom:
            - secretRef:
                name: backend-env
                optional: true
          resources:
            requests:
              cpu: "$AppCpuReq"
              memory: "$AppMemReq"
            limits:
              cpu: "$AppCpuLim"
              memory: "$AppMemLim"
"@
[System.IO.File]::WriteAllText((Join-Path $K8sAppDir "deployment.yml"), $fileAppDeployment.Trim(), [System.Text.Encoding]::UTF8)
Write-Host "  [OK] Generado: k8s/${Environment}/deployment.yml" -ForegroundColor Green

# k8s/<entorno>/service.yml
$fileAppService = @"
apiVersion: v1
kind: Service
metadata:
  name: $AppSvcName
  namespace: $sanitizedNamespace
spec:
  type: ClusterIP
  selector:
    app: $AppK8sName
  ports:
    - protocol: TCP
      port: 80
      targetPort: $ContainerPort
"@
[System.IO.File]::WriteAllText((Join-Path $K8sAppDir "service.yml"), $fileAppService.Trim(), [System.Text.Encoding]::UTF8)
Write-Host "  [OK] Generado: k8s/${Environment}/service.yml" -ForegroundColor Green

# k8s/<entorno>/ingress.yml
$fileAppIngress = @"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $AppIngressName
  namespace: $sanitizedNamespace
spec:
  ingressClassName: nginx
  rules:
    - host: $AppHost
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: $AppSvcName
                port:
                  number: 80
"@
[System.IO.File]::WriteAllText((Join-Path $K8sAppDir "ingress.yml"), $fileAppIngress.Trim(), [System.Text.Encoding]::UTF8)
Write-Host "  [OK] Generado: k8s/${Environment}/ingress.yml" -ForegroundColor Green

# k8s/<entorno>/hpa.yml
$fileAppHpa = @"
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: $AppHpaName
  namespace: $sanitizedNamespace
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: $AppK8sName
  minReplicas: $AppReplicas
  maxReplicas: $AppMaxReplicas
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 75
"@
[System.IO.File]::WriteAllText((Join-Path $K8sAppDir "hpa.yml"), $fileAppHpa.Trim(), [System.Text.Encoding]::UTF8)
Write-Host "  [OK] Generado: k8s/${Environment}/hpa.yml" -ForegroundColor Green

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "Manifiestos generados exitosamente ($envLabel)" -ForegroundColor Green
Write-Host "  1. Pipeline Tekton (Clúster): $OutputDir" -ForegroundColor White
Write-Host "  2. Manifiestos App (Repo Git): $K8sAppDir" -ForegroundColor White
Write-Host "=================================================================" -ForegroundColor Cyan

Write-Host ""
Write-Host "PASOS SIGUIENTES PARA DESPLEGAR EN $envLabel :" -ForegroundColor White
Write-Host "1. Crear el namespace (si no existe):" -ForegroundColor Gray
Write-Host "   kubectl create namespace $sanitizedNamespace" -ForegroundColor Yellow
Write-Host ""
Write-Host "2. Inyectar secretos en el namespace $sanitizedNamespace :" -ForegroundColor Gray
Write-Host "   - harbor-env (HARBOR_USERNAME, HARBOR_TOKEN)" -ForegroundColor DarkGray
Write-Host "   - github-credentials (token)" -ForegroundColor DarkGray
if ($SignImage) {
    Write-Host "   - cosign-secret (cosign.key, cosign.password)" -ForegroundColor DarkGray
}
Write-Host "   - harbor-registry-secret (Secret tipo docker-registry para los Pods)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "3. Aplicar los manifiestos de Tekton en el clúster (incluye RBAC + ClusterRoleBinding):" -ForegroundColor Gray
Write-Host "   kubectl apply -f `"$OutputDir`"" -ForegroundColor Yellow
Write-Host ""
Write-Host "4. Copiar la carpeta 'k8s/${Environment}' al repositorio de tu App ($GitRepoUrl) y hacer push:" -ForegroundColor Gray
Write-Host "   git add k8s/ && git commit -m 'chore: add k8s manifests' && git push origin $GitBranch" -ForegroundColor Yellow
Write-Host ""
Write-Host "5. Configurar Webhook en GitHub ($GitRepoUrl):" -ForegroundColor Gray
Write-Host "   - Payload URL: https://${IngressHost}${WebhookPath}" -ForegroundColor Green
Write-Host "   - Content Type: application/json" -ForegroundColor Green
Write-Host "   - Events: Just the push event (Rama: $GitBranch)" -ForegroundColor Green
Write-Host ""
Write-Host "6. Crear la Application en Argo CD apuntando al path: k8s/${Environment}" -ForegroundColor Gray
