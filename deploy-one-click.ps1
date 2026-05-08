[CmdletBinding()]
param(
    [string]$ConfigPath = "",
    [string]$SourceRoot = "",
    [string]$UpstreamRepo = "dreamhunter2333/cloudflare_temp_email",
    [string]$UpstreamRef = "main",
    [string]$CacheRoot = (Join-Path $PSScriptRoot ".cache\cloudflare-temp-email"),
    [switch]$RefreshSource,
    [switch]$PrepareOnly,
    [switch]$SkipInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$BundleRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$RepoRoot = $BundleRoot

trap {
    Write-Host ""
    Write-Host "部署已中断。" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    Write-Host "排查建议"
    Write-Host "  1. 先看上面最后一个 ==> 步骤标题，确认卡在哪一步"
    Write-Host "  2. 如果是域名占用，去 Cloudflare 删除旧的 DNS / Pages / Worker 绑定"
    Write-Host "  3. 如果是 Wrangler 登录问题，执行 npx wrangler login"
    Write-Host "  4. 如果只是想先检查配置，可重新运行: pwsh -File .\\deploy-one-click.ps1 -PrepareOnly"
    exit 1
}

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Note {
    param([string]$Message)
    Write-Host " -> $Message" -ForegroundColor DarkGray
}

function Write-WarnLine {
    param([string]$Message)
    Write-Host " !  $Message" -ForegroundColor Yellow
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-ConfigTemplatePath {
    param([string]$TargetConfigPath)

    $minimalJsonc = Join-Path $BundleRoot "one-click.config.minimal.jsonc"
    if (Test-Path $minimalJsonc) {
        return $minimalJsonc
    }

    $exampleJsonc = Join-Path $BundleRoot "one-click.config.example.jsonc"
    if (Test-Path $exampleJsonc) {
        return $exampleJsonc
    }

    return $minimalJsonc
}

function Test-ProjectSourceReady {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return $false
    }

    $required = @(
        "worker\package.json",
        "frontend\package.json",
        "db\schema.sql"
    )

    foreach ($item in $required) {
        if (-not (Test-Path (Join-Path $Path $item))) {
            return $false
        }
    }

    return $true
}

function Find-ProjectSourceRoot {
    param([string]$SearchRoot)

    if ([string]::IsNullOrWhiteSpace($SearchRoot) -or -not (Test-Path $SearchRoot)) {
        return $null
    }

    $candidates = @($SearchRoot)
    $candidates += Get-ChildItem -Path $SearchRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $_.FullName
    }

    foreach ($candidate in $candidates) {
        if (Test-ProjectSourceReady -Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-SourceCacheName {
    param(
        [string]$UpstreamRepo,
        [string]$UpstreamRef
    )
    return (($UpstreamRepo + "-" + $UpstreamRef) -replace '[^a-zA-Z0-9._-]+', '-')
}

function Get-GitHubArchiveUrls {
    param(
        [string]$UpstreamRepo,
        [string]$UpstreamRef
    )

    return @(
        "https://github.com/$UpstreamRepo/archive/refs/heads/$UpstreamRef.zip",
        "https://github.com/$UpstreamRepo/archive/refs/tags/$UpstreamRef.zip",
        "https://github.com/$UpstreamRepo/archive/$UpstreamRef.zip"
    )
}

function Get-RequiredCommand {
    param(
        [string]$Name,
        [string]$Hint
    )
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "找不到命令 '$Name'。$Hint"
    }
}

function Invoke-External {
    param(
        [string[]]$Command,
        [string]$WorkingDirectory = $RepoRoot,
        [switch]$AllowFailure
    )

    Push-Location $WorkingDirectory
    try {
        Write-Note ("运行: " + ($Command -join " "))
        $output = if ($Command.Length -gt 1) {
            & $Command[0] @($Command[1..($Command.Length - 1)]) 2>&1 | Out-String
        } else {
            & $Command[0] 2>&1 | Out-String
        }
        $exitCode = $LASTEXITCODE
        if (-not $AllowFailure -and $exitCode -ne 0) {
            throw "命令失败:`n$($Command -join ' ')`n`n$output"
        }
        return [pscustomobject]@{
            ExitCode = $exitCode
            Output   = $output.Trim()
        }
    } finally {
        Pop-Location
    }
}

function New-RandomSecret {
    param([int]$Length = 48)
    $chars = @()
    $chars += [char[]](48..57)
    $chars += [char[]](65..90)
    $chars += [char[]](97..122)
    return -join (1..$Length | ForEach-Object { $chars | Get-Random })
}

function ConvertTo-TomlArray {
    param([object[]]$Values)
    if ($null -eq $Values -or $Values.Count -eq 0) {
        return "[]"
    }
    $items = $Values | ForEach-Object {
        '"' + (($_.ToString()) -replace '"', '\"') + '"'
    }
    return "[" + ($items -join ", ") + "]"
}

function ConvertTo-TomlBool {
    param([bool]$Value)
    if ($Value) { return "true" }
    return "false"
}

function Save-JsonConfig {
    param(
        [hashtable]$Config,
        [string]$Path
    )
    $json = $Config | ConvertTo-Json -Depth 10
    Set-Content -Path $Path -Value $json -Encoding UTF8
}

function Remove-JsonComments {
    param([string]$Text)

    $builder = New-Object System.Text.StringBuilder
    $inString = $false
    $escape = $false
    $lineComment = $false
    $blockComment = $false

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }

        if ($lineComment) {
            if ($ch -eq "`r" -or $ch -eq "`n") {
                $lineComment = $false
                [void]$builder.Append($ch)
            }
            continue
        }

        if ($blockComment) {
            if ($ch -eq '*' -and $next -eq '/') {
                $blockComment = $false
                $i++
            }
            continue
        }

        if ($inString) {
            [void]$builder.Append($ch)
            if ($escape) {
                $escape = $false
            } elseif ($ch -eq '\') {
                $escape = $true
            } elseif ($ch -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($ch -eq '/' -and $next -eq '/') {
            $lineComment = $true
            $i++
            continue
        }

        if ($ch -eq '/' -and $next -eq '*') {
            $blockComment = $true
            $i++
            continue
        }

        [void]$builder.Append($ch)
        if ($ch -eq '"') {
            $inString = $true
        }
    }

    return $builder.ToString()
}

function Load-ConfigFile {
    param([string]$Path)

    $raw = Get-Content $Path -Raw
    $json = Remove-JsonComments -Text $raw
    return ($json | ConvertFrom-Json -AsHashtable)
}

function Get-OptionalString {
    param(
        [hashtable]$Config,
        [string]$Key,
        [string]$DefaultValue = ""
    )
    if ($Config.ContainsKey($Key) -and $null -ne $Config[$Key]) {
        return [string]$Config[$Key]
    }
    return $DefaultValue
}

function Write-ConfigSummary {
    param(
        [hashtable]$Config,
        [string]$ConfigPath,
        [string]$ResolvedSourceRoot,
        [string]$SourceMode
    )
    Write-Step "本次部署配置"
    Write-Host "  配置文件     : $ConfigPath"
    Write-Host "  源码目录     : $ResolvedSourceRoot"
    Write-Host "  源码来源     : $SourceMode"
    Write-Host "  后端 Worker  : $($Config.backendWorkerName)"
    Write-Host "  前端 Worker  : $($Config.frontendWorkerName)"
    Write-Host "  D1 数据库    : $($Config.databaseName)"
    Write-Host "  KV 命名空间  : $($Config.kvNamespaceName)"
    Write-Host "  收件域名     : $($Config.mailDomain)"
    Write-Host "  前端域名     : $($Config.frontendDomain)"
    Write-Host "  API 域名     : $($Config.apiDomain)"
    Write-Host "  Admin 密码   : $($Config.adminPassword)"
    Write-Note "如已手动填写 frontendDomain / apiDomain，这两个域名会优先生效。"
}

function Download-ProjectSource {
    param(
        [string]$CacheRoot,
        [string]$UpstreamRepo,
        [string]$UpstreamRef
    )

    $cacheName = Get-SourceCacheName -UpstreamRepo $UpstreamRepo -UpstreamRef $UpstreamRef
    $extractRoot = Join-Path $CacheRoot $cacheName
    $zipPath = Join-Path $CacheRoot ($cacheName + ".zip")

    Ensure-Directory -Path $CacheRoot

    if (Test-Path $extractRoot) {
        Remove-Item -Path $extractRoot -Recurse -Force
    }
    if (Test-Path $zipPath) {
        Remove-Item -Path $zipPath -Force
    }

    Write-Step "下载官方源码"
    $downloaded = $false
    foreach ($url in (Get-GitHubArchiveUrls -UpstreamRepo $UpstreamRepo -UpstreamRef $UpstreamRef)) {
        try {
            Write-Note "下载: $url"
            Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -TimeoutSec 180
            $downloaded = $true
            break
        } catch {
            Write-Note "当前地址下载失败，尝试下一个地址"
        }
    }

    if (-not $downloaded) {
        throw "无法下载上游源码。请检查网络，或者手动把官方项目下载好后通过 -SourceRoot 指向源码目录。"
    }

    Ensure-Directory -Path $extractRoot
    Expand-Archive -Path $zipPath -DestinationPath $extractRoot -Force

    $resolved = Find-ProjectSourceRoot -SearchRoot $extractRoot
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw "源码压缩包已下载，但没有找到 worker/frontend/db 目录结构。请检查上游仓库结构是否发生变化。"
    }

    return $resolved
}

function Resolve-ProjectSourceRoot {
    param(
        [string]$ExplicitSourceRoot,
        [string]$WrapperRoot,
        [string]$CacheRoot,
        [string]$UpstreamRepo,
        [string]$UpstreamRef,
        [switch]$RefreshSource
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitSourceRoot)) {
        $resolvedPath = [System.IO.Path]::GetFullPath($ExplicitSourceRoot)
        if (-not (Test-ProjectSourceReady -Path $resolvedPath)) {
            throw "你传入的 -SourceRoot 不完整，必须包含 worker、frontend、db 这些目录。当前路径: $resolvedPath"
        }
        return [pscustomobject]@{
            Root = $resolvedPath
            Mode = "手动指定本地源码"
        }
    }

    if (Test-ProjectSourceReady -Path $WrapperRoot) {
        return [pscustomobject]@{
            Root = $WrapperRoot
            Mode = "当前目录自带源码"
        }
    }

    $cacheName = Get-SourceCacheName -UpstreamRepo $UpstreamRepo -UpstreamRef $UpstreamRef
    $cachePath = Join-Path $CacheRoot $cacheName

    if (-not $RefreshSource) {
        $cachedRoot = Find-ProjectSourceRoot -SearchRoot $cachePath
        if (-not [string]::IsNullOrWhiteSpace($cachedRoot)) {
            return [pscustomobject]@{
                Root = $cachedRoot
                Mode = "缓存源码"
            }
        }
    }

    return [pscustomobject]@{
        Root = (Download-ProjectSource -CacheRoot $CacheRoot -UpstreamRepo $UpstreamRepo -UpstreamRef $UpstreamRef)
        Mode = "刚下载的官方源码"
    }
}

function Ensure-FrontendWorkerFiles {
    param([string]$ProjectRoot)

    $workerRoot = Join-Path $ProjectRoot "frontend-worker"
    $workerSrcRoot = Join-Path $workerRoot "src"

    Ensure-Directory -Path $workerRoot
    Ensure-Directory -Path $workerSrcRoot

    $packageJson = @'
{
  "name": "cloudflare-temp-email-frontend-worker",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "deploy": "wrangler deploy"
  }
}
'@

    $workerJs = @'
export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (!url.pathname.includes(".")) {
      url.pathname = "/index.html";
    }

    return env.ASSETS.fetch(url);
  },
};
'@

    Set-Content -Path (Join-Path $workerRoot "package.json") -Value $packageJson -Encoding UTF8
    Set-Content -Path (Join-Path $workerSrcRoot "worker.js") -Value $workerJs -Encoding UTF8
}

function Ensure-FrontendHeaderPatch {
    param([string]$ProjectRoot)

    $apiRoot = Join-Path $ProjectRoot "frontend\src\api"
    $indexPath = Join-Path $apiRoot "index.js"
    $headersPath = Join-Path $apiRoot "headers.js"

    if (-not (Test-Path $indexPath)) {
        throw "未找到前端 API 文件: $indexPath"
    }

    $headersContent = @'
const INVALID_HEADER_VALUE_CHARS = /[\u0000-\u0008\u000A-\u001F\u007F\r\n]|[^\u0009\u0020-\u007E\u0080-\u00FF]/g

export const sanitizeHeaderValue = (value) => {
  if (value === undefined || value === null) {
    return undefined
  }

  const sanitized = String(value).replace(INVALID_HEADER_VALUE_CHARS, '').trim()
  return sanitized || undefined
}

export const buildRequestHeaders = ({
  lang,
  userJwt,
  userAccessToken,
  auth,
  adminAuth,
  fingerprint,
  jwt,
}) => {
  return {
    'x-lang': sanitizeHeaderValue(lang) || 'zh',
    'x-user-token': sanitizeHeaderValue(userJwt),
    'x-user-access-token': sanitizeHeaderValue(userAccessToken),
    'x-custom-auth': sanitizeHeaderValue(auth),
    'x-admin-auth': sanitizeHeaderValue(adminAuth),
    'x-fingerprint': sanitizeHeaderValue(fingerprint),
    Authorization: sanitizeHeaderValue(jwt) ? `Bearer ${sanitizeHeaderValue(jwt)}` : undefined,
    'Content-Type': 'application/json',
  }
}
'@

    Set-Content -Path $headersPath -Value $headersContent -Encoding UTF8

    $indexContent = Get-Content -Path $indexPath -Raw
    if ($indexContent -match "buildRequestHeaders") {
        return
    }

    $importPattern = "import \{ getFingerprint \} from '\.\./utils/fingerprint'"
    $importReplacement = "import { getFingerprint } from '../utils/fingerprint'`r`nimport { buildRequestHeaders } from './headers'"
    if ($indexContent -match $importPattern) {
        $indexContent = [regex]::Replace($indexContent, $importPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $importReplacement }, 1)
    } else {
        throw "无法自动修补 frontend/src/api/index.js，未找到 getFingerprint 导入语句。"
    }

    $headersPattern = "(?ms)^\s*headers:\s*\{\s*'x-lang': i18n\.global\.locale\.value,\s*'x-user-token': options\.userJwt \|\| userJwt\.value,\s*'x-user-access-token': userSettings\.value\.access_token,\s*'x-custom-auth': auth\.value,\s*'x-admin-auth': adminAuth\.value,\s*'x-fingerprint': fingerprint,\s*'Authorization': ``Bearer \$\{jwt\.value\}``,\s*'Content-Type': 'application/json',\s*\},"

    $headersReplacement = @'
            headers: buildRequestHeaders({
                lang: i18n.global.locale.value,
                userJwt: options.userJwt || userJwt.value,
                userAccessToken: userSettings.value.access_token,
                auth: auth.value,
                adminAuth: adminAuth.value,
                fingerprint,
                jwt: jwt.value,
            }),
'@

    if ($indexContent -match $headersPattern) {
        $indexContent = [regex]::Replace($indexContent, $headersPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $headersReplacement.TrimEnd("`r", "`n") }, 1)
    } else {
        throw "无法自动修补 frontend/src/api/index.js，未找到原始 headers 配置块。"
    }

    Set-Content -Path $indexPath -Value $indexContent -Encoding UTF8
}

function Join-Domain {
    param(
        [string]$Subdomain,
        [string]$RootDomain
    )
    if ([string]::IsNullOrWhiteSpace($Subdomain)) {
        return $RootDomain
    }
    return "$Subdomain.$RootDomain"
}

function Get-SubdomainFromDomain {
    param(
        [string]$Domain,
        [string]$RootDomain,
        [string]$DefaultValue
    )
    if ([string]::IsNullOrWhiteSpace($Domain)) {
        return $DefaultValue
    }
    if ($Domain -eq $RootDomain) {
        return ""
    }
    $suffix = "." + $RootDomain
    if ($Domain.EndsWith($suffix)) {
        return $Domain.Substring(0, $Domain.Length - $suffix.Length)
    }
    return $DefaultValue
}

function Ensure-String {
    param(
        [hashtable]$Config,
        [string]$Key,
        [string]$DefaultValue
    )
    if (-not $Config.ContainsKey($Key) -or [string]::IsNullOrWhiteSpace([string]$Config[$Key])) {
        $Config[$Key] = $DefaultValue
    }
}

function Ensure-Bool {
    param(
        [hashtable]$Config,
        [string]$Key,
        [bool]$DefaultValue
    )
    if (-not $Config.ContainsKey($Key) -or $null -eq $Config[$Key]) {
        $Config[$Key] = $DefaultValue
    } else {
        $Config[$Key] = [bool]$Config[$Key]
    }
}

function Ensure-Array {
    param(
        [hashtable]$Config,
        [string]$Key,
        [object[]]$DefaultValue
    )
    if (-not $Config.ContainsKey($Key) -or $null -eq $Config[$Key]) {
        $Config[$Key] = $DefaultValue
        return
    }
    if ($Config[$Key] -is [System.Collections.IEnumerable] -and -not ($Config[$Key] -is [string])) {
        $Config[$Key] = @($Config[$Key])
    } else {
        $Config[$Key] = $DefaultValue
    }
}

function Get-RegexGroupValue {
    param(
        [string]$InputText,
        [string]$Pattern
    )
    $match = [regex]::Match($InputText, $Pattern)
    if (-not $match.Success) {
        throw "无法从输出中解析需要的值:`n$InputText"
    }
    return $match.Groups[1].Value
}

function Ensure-WranglerLogin {
    $whoami = Invoke-External -Command @("npx", "wrangler", "whoami") -AllowFailure
    if ($whoami.Output -match "not authenticated") {
        Write-Step "Wrangler 未登录，正在打开 Cloudflare 登录"
        Invoke-External -Command @("npx", "wrangler", "login") | Out-Null
        $whoami = Invoke-External -Command @("npx", "wrangler", "whoami") -AllowFailure
        if ($whoami.Output -match "not authenticated") {
            throw "Wrangler 登录失败，请先手动执行: npx wrangler login"
        }
    }
}

function Wait-UrlReady {
    param(
        [string]$Url,
        [string]$ContainsText,
        [int]$MaxAttempts = 15
    )

    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 20
            if ([string]::IsNullOrWhiteSpace($ContainsText) -or $response.Content -like "*$ContainsText*") {
                return $true
            }
        } catch {
            Start-Sleep -Seconds 3
            continue
        }
        Start-Sleep -Seconds 3
    }
    return $false
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $jsoncPath = Join-Path $BundleRoot "one-click.config.jsonc"
    if (Test-Path $jsoncPath) {
        $ConfigPath = $jsoncPath
    } else {
        $ConfigPath = $jsoncPath
    }
}

if (-not (Test-Path $ConfigPath)) {
    $templatePath = Get-ConfigTemplatePath -TargetConfigPath $ConfigPath
    if (Test-Path $templatePath) {
        Copy-Item $templatePath $ConfigPath
        $templateName = [System.IO.Path]::GetFileName($templatePath)
        throw "未找到配置文件:`n$ConfigPath`n已自动复制模板 $templateName 到该位置。请至少填写 projectName、mailDomain、adminPassword 后再重新运行。"
    }
    throw "未找到配置文件: $ConfigPath"
}

Get-RequiredCommand -Name "node" -Hint "请先安装 Node.js 20+。"
Get-RequiredCommand -Name "corepack" -Hint "请确保你的 Node.js 自带 Corepack。"
Get-RequiredCommand -Name "npx" -Hint "请确保 npm / npx 可用。"

$config = Load-ConfigFile -Path $ConfigPath

Ensure-String -Config $config -Key "mailDomain" -DefaultValue ""
if ([string]::IsNullOrWhiteSpace($config.mailDomain)) {
    throw "配置文件里的 mailDomain 不能为空，例如: cnlion.qzz.io"
}

Ensure-String -Config $config -Key "projectName" -DefaultValue (($config.mailDomain -replace '[^a-zA-Z0-9]+', '-') -replace '(^-+|-+$)', '')
Ensure-String -Config $config -Key "frontendSubdomain" -DefaultValue (Get-SubdomainFromDomain -Domain (Get-OptionalString -Config $config -Key "frontendDomain") -RootDomain $config.mailDomain -DefaultValue "mail")
Ensure-String -Config $config -Key "apiSubdomain" -DefaultValue (Get-SubdomainFromDomain -Domain (Get-OptionalString -Config $config -Key "apiDomain") -RootDomain $config.mailDomain -DefaultValue "email-api")
Ensure-String -Config $config -Key "backendWorkerName" -DefaultValue ($config.projectName + "-api")
Ensure-String -Config $config -Key "frontendWorkerName" -DefaultValue ($config.projectName + "-frontend")
Ensure-String -Config $config -Key "databaseName" -DefaultValue ($config.projectName + "-db")
Ensure-String -Config $config -Key "kvNamespaceName" -DefaultValue (($config.projectName -replace '[^a-zA-Z0-9]+', '_').ToUpper() + "_KV")
Ensure-String -Config $config -Key "frontendDomain" -DefaultValue (Join-Domain -Subdomain $config.frontendSubdomain -RootDomain $config.mailDomain)
Ensure-String -Config $config -Key "apiDomain" -DefaultValue (Join-Domain -Subdomain $config.apiSubdomain -RootDomain $config.mailDomain)
Ensure-String -Config $config -Key "title" -DefaultValue ($config.frontendDomain + " temp mail")
Ensure-String -Config $config -Key "defaultLanguage" -DefaultValue "zh"
Ensure-String -Config $config -Key "prefix" -DefaultValue "tmp"
Ensure-String -Config $config -Key "adminPassword" -DefaultValue ""
if ([string]::IsNullOrWhiteSpace($config.adminPassword)) {
    throw "配置文件里的 adminPassword 不能为空，例如: cnlion"
}
Ensure-String -Config $config -Key "jwtSecret" -DefaultValue (New-RandomSecret)
Ensure-String -Config $config -Key "databaseId" -DefaultValue ""
Ensure-String -Config $config -Key "kvId" -DefaultValue ""

if ($config.frontendDomain -eq $config.apiDomain) {
    throw "frontendDomain 和 apiDomain 不能相同。建议分别使用 mail.<你的域名> 与 email-api.<你的域名>。"
}

Ensure-Bool -Config $config -Key "enableUserCreateEmail" -DefaultValue $true
Ensure-Bool -Config $config -Key "disableAnonymousUserCreateEmail" -DefaultValue $true
Ensure-Bool -Config $config -Key "enableUserDeleteEmail" -DefaultValue $false
Ensure-Bool -Config $config -Key "enableAutoReply" -DefaultValue $false

Ensure-String -Config $config -Key "adminUserRole" -DefaultValue "admin"
Ensure-String -Config $config -Key "userDefaultRole" -DefaultValue "vip"
Ensure-Array -Config $config -Key "defaultDomains" -DefaultValue @()
Ensure-Array -Config $config -Key "userRoles" -DefaultValue @()

if ($config.userRoles.Count -eq 0) {
    $config.userRoles = @(
        @{
            domains = @($config.mailDomain)
            role    = "vip"
            prefix  = ""
        },
        @{
            domains = @($config.mailDomain)
            role    = $config.adminUserRole
            prefix  = ""
        }
    )
}

Save-JsonConfig -Config $config -Path $ConfigPath

$resolvedSource = Resolve-ProjectSourceRoot `
    -ExplicitSourceRoot $SourceRoot `
    -WrapperRoot $RepoRoot `
    -CacheRoot $CacheRoot `
    -UpstreamRepo $UpstreamRepo `
    -UpstreamRef $UpstreamRef `
    -RefreshSource:$RefreshSource
$ProjectSourceRoot = $resolvedSource.Root

Ensure-FrontendWorkerFiles -ProjectRoot $ProjectSourceRoot
#Ensure-FrontendHeaderPatch -ProjectRoot $ProjectSourceRoot

Write-ConfigSummary `
    -Config $config `
    -ConfigPath $ConfigPath `
    -ResolvedSourceRoot $ProjectSourceRoot `
    -SourceMode $resolvedSource.Mode

$roleLines = @()
foreach ($role in $config.userRoles) {
    $roleLines += "  { domains = $(ConvertTo-TomlArray @($role.domains)), role = `"$($role.role)`", prefix = `"$($role.prefix)`" },"
}

$backendToml = @"
name = "$($config.backendWorkerName)"
main = "src/worker.ts"
compatibility_date = "2025-04-01"
compatibility_flags = [ "nodejs_compat" ]
keep_vars = true
workers_dev = false
preview_urls = false

routes = [
  { pattern = "$($config.apiDomain)", custom_domain = true },
]

[vars]
DEFAULT_LANG = "$($config.defaultLanguage)"
TITLE = "$($config.title)"
PREFIX = "$($config.prefix)"
DEFAULT_DOMAINS = $(ConvertTo-TomlArray @($config.defaultDomains))
DOMAINS = $(ConvertTo-TomlArray @($config.mailDomain))
JWT_SECRET = "$($config.jwtSecret)"
ADMIN_PASSWORDS = $(ConvertTo-TomlArray @($config.adminPassword))
BLACK_LIST = ""
ADMIN_USER_ROLE = "$($config.adminUserRole)"
USER_DEFAULT_ROLE = "$($config.userDefaultRole)"
USER_ROLES = [
$($roleLines -join "`n")
]
ENABLE_USER_CREATE_EMAIL = $(ConvertTo-TomlBool $config.enableUserCreateEmail)
DISABLE_ANONYMOUS_USER_CREATE_EMAIL = $(ConvertTo-TomlBool $config.disableAnonymousUserCreateEmail)
ENABLE_USER_DELETE_EMAIL = $(ConvertTo-TomlBool $config.enableUserDeleteEmail)
ENABLE_AUTO_REPLY = $(ConvertTo-TomlBool $config.enableAutoReply)
FRONTEND_URL = "https://$($config.frontendDomain)"

[[d1_databases]]
binding = "DB"
database_name = "$($config.databaseName)"
database_id = "$($config.databaseId)"

[[kv_namespaces]]
binding = "KV"
id = "$($config.kvId)"
"@

$frontendWorkerToml = @"
name = "$($config.frontendWorkerName)"
main = "src/worker.js"
compatibility_date = "2025-04-01"
workers_dev = false
preview_urls = false

routes = [
  { pattern = "$($config.frontendDomain)", custom_domain = true },
]

[assets]
directory = "../frontend/dist/"
binding = "ASSETS"
run_worker_first = true
"@

$frontendEnv = @"
VITE_API_BASE=https://$($config.apiDomain)
VITE_CF_WEB_ANALY_TOKEN=
"@

Write-Step "写入本地生成配置"
Set-Content -Path (Join-Path $ProjectSourceRoot "worker\wrangler.toml") -Value $backendToml -Encoding UTF8
Set-Content -Path (Join-Path $ProjectSourceRoot "frontend-worker\wrangler.toml") -Value $frontendWorkerToml -Encoding UTF8
Set-Content -Path (Join-Path $ProjectSourceRoot "frontend\.env.pages") -Value $frontendEnv -Encoding UTF8

if ($PrepareOnly) {
    Write-Step "已完成预生成"
    Write-Host "配置文件: $ConfigPath"
    Write-Host "源码目录: $ProjectSourceRoot"
    Write-Host "后端 Worker: $($config.backendWorkerName)"
    Write-Host "前端 Worker: $($config.frontendWorkerName)"
    Write-Host "收件域名: $($config.mailDomain)"
    Write-Host "前端域名: $($config.frontendDomain)"
    Write-Host "API 域名: $($config.apiDomain)"
    Write-Host ""
    Write-Host "下一步建议"
    Write-Host "  1. 检查 $ProjectSourceRoot\\worker\\wrangler.toml 与 $ProjectSourceRoot\\frontend-worker\\wrangler.toml"
    Write-Host "  2. 确认前端域名和 API 域名都是你自己的域名"
    Write-Host "  3. 确认无误后，再执行不带 -PrepareOnly 的正式部署"
    exit 0
}

Ensure-WranglerLogin

if (-not $SkipInstall) {
    Write-Step "安装依赖"
    Invoke-External -Command @("corepack", "pnpm", "install") -WorkingDirectory (Join-Path $ProjectSourceRoot "worker") | Out-Null
    Invoke-External -Command @("corepack", "pnpm", "install") -WorkingDirectory (Join-Path $ProjectSourceRoot "frontend") | Out-Null
} else {
    Write-Step "跳过依赖安装"
    Write-Note "已按你的要求跳过 pnpm install，脚本将直接使用当前源码目录里的依赖。"
}

if ([string]::IsNullOrWhiteSpace($config.databaseId)) {
    Write-Step "创建 D1 数据库"
    $d1Create = Invoke-External -Command @("npx", "wrangler", "d1", "create", $config.databaseName)
    $config.databaseId = Get-RegexGroupValue -InputText $d1Create.Output -Pattern '"database_id"\s*:\s*"([^"]+)"'
    Save-JsonConfig -Config $config -Path $ConfigPath
}

if ([string]::IsNullOrWhiteSpace($config.kvId)) {
    Write-Step "创建 KV 命名空间"
    $kvCreate = Invoke-External -Command @("npx", "wrangler", "kv", "namespace", "create", $config.kvNamespaceName)
    $config.kvId = Get-RegexGroupValue -InputText $kvCreate.Output -Pattern '"id"\s*:\s*"([^"]+)"'
    Save-JsonConfig -Config $config -Path $ConfigPath
}

Write-Step "刷新生成配置"
$backendToml = $backendToml -replace 'database_id = ""', ('database_id = "' + $config.databaseId + '"')
$backendToml = $backendToml -replace 'id = ""', ('id = "' + $config.kvId + '"')
Set-Content -Path (Join-Path $ProjectSourceRoot "worker\wrangler.toml") -Value $backendToml -Encoding UTF8

Write-Step "初始化 D1 表结构"
Invoke-External -Command @("npx", "wrangler", "d1", "execute", $config.databaseName, "--file=../db/schema.sql", "--remote") -WorkingDirectory (Join-Path $ProjectSourceRoot "worker") | Out-Null

Write-Step "构建前端"
Invoke-External -Command @("corepack", "pnpm", "build:pages") -WorkingDirectory (Join-Path $ProjectSourceRoot "frontend") | Out-Null

Write-Step "部署后端 Worker"
try {
    Invoke-External -Command @("corepack", "pnpm", "run", "deploy") -WorkingDirectory (Join-Path $ProjectSourceRoot "worker") | Out-Null
} catch {
    if ($_.Exception.Message -match "already has externally managed DNS records") {
        throw "API 域名 $($config.apiDomain) 已被旧 DNS / Pages / Worker 绑定占用。请先在 Cloudflare 中清理旧记录后重试。"
    }
    throw
}

Write-Step "部署前端 Worker"
try {
    Invoke-External -Command @("npx", "wrangler", "deploy") -WorkingDirectory (Join-Path $ProjectSourceRoot "frontend-worker") | Out-Null
} catch {
    if ($_.Exception.Message -match "already has externally managed DNS records") {
        throw "前端域名 $($config.frontendDomain) 已被旧 DNS / Pages / Worker 绑定占用。请先在 Cloudflare 中清理旧记录后重试。"
    }
    throw
}

Write-Step "联通性检查"
$apiOk = Wait-UrlReady -Url ("https://" + $config.apiDomain + "/health_check") -ContainsText "OK"
$frontendOk = Wait-UrlReady -Url ("https://" + $config.frontendDomain) -ContainsText "<!DOCTYPE html>"

Write-Host ""
Write-Host "部署完成。" -ForegroundColor Green
Write-Host ""
Write-Host "实际配置"
Write-Host "  源码目录     : $ProjectSourceRoot"
Write-Host "  源码来源     : $($resolvedSource.Mode)"
Write-Host "  后端 Worker : $($config.backendWorkerName)"
Write-Host "  前端 Worker : $($config.frontendWorkerName)"
Write-Host "  D1 数据库   : $($config.databaseName)"
Write-Host "  KV 命名空间 : $($config.kvNamespaceName)"
Write-Host "  收件域名    : $($config.mailDomain)"
Write-Host "  前端域名    : $($config.frontendDomain)"
Write-Host "  API 域名     : $($config.apiDomain)"
Write-Host "  Admin 密码   : $($config.adminPassword)"
Write-Host ""
Write-Host "自动检查"
Write-Host "  API 健康检查 : $apiOk"
Write-Host "  前端打开检查 : $frontendOk"
if (-not $apiOk -or -not $frontendOk) {
    Write-Host ""
    Write-WarnLine "自动检查未全部通过，这通常是自定义域名刚绑定后仍在等待 DNS 生效。"
    if (-not $apiOk) {
        Write-Host "  - 稍后再试: https://$($config.apiDomain)/health_check"
    }
    if (-not $frontendOk) {
        Write-Host "  - 稍后再试: https://$($config.frontendDomain)"
    }
}
Write-Host ""
Write-Host "仍需人工完成"
Write-Host "  1. Cloudflare -> Email Routing -> 为 $($config.mailDomain) 开启收件"
Write-Host "  2. 添加并验证一个目标邮箱"
Write-Host "  3. 创建 Catch-all -> Send to a Worker -> $($config.backendWorkerName)"
Write-Host "  4. 进入 /admin，用上面的 Admin 密码完成后台检查"
Write-Host ""
Write-Host "LinuxDO 风格提醒"
Write-Host "  - 当前默认是禁用匿名建邮箱的严格模式"
Write-Host "  - 如果你希望访客一打开就能直接生成邮箱，把 disableAnonymousUserCreateEmail 改成 false"
Write-Host "  - 如果你要让注册用户自动拿到 vip，请在后台开启用户注册 + 邮箱验证码验证 + 验证邮件发件人"
