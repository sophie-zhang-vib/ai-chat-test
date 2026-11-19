# ============================================================
# College-Life Planning Assistant — Backend Proxy
# Pure PowerShell / .NET, zero external dependencies.
# API key is read ONLY from the ZHIPU_API_KEY environment
# variable. It never appears in the frontend, HTML, or any
# response body.
# ============================================================

param(
    [int]$Port = 8000,
    [string]$HostPrefix = 'http://localhost'
)

$ErrorActionPreference = 'Stop'

# ---------- 0. Validate API key at startup ----------
$apiKey = [Environment]::GetEnvironmentVariable('ZHIPU_API_KEY')
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    Write-Host "!!! ZHIPU_API_KEY environment variable is not set. !!!" -ForegroundColor Red
    Write-Host "    Run: `$env:ZHIPU_API_KEY = 'your-key-here'" -ForegroundColor Yellow
    exit 1
}
Write-Host "[OK] ZHIPU_API_KEY loaded from environment variable." -ForegroundColor Green

# ---------- 1. Boot HttpListener ----------
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$prefix = "$HostPrefix`:$Port/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Host "[OK] Server listening on $prefix  (root: $root)" -ForegroundColor Green

# ---------- 2. Helper: send HTTP response ----------
function Send-Response {
    param(
        [System.Net.HttpListenerResponse]$Resp,
        [int]$StatusCode = 200,
        [string]$ContentType = 'text/plain; charset=utf-8',
        [byte[]]$Body = [byte[]]@()
    )
    $Resp.StatusCode = $StatusCode
    $Resp.ContentType = $ContentType
    $Resp.ContentLength64 = $Body.Length
    if ($Body.Length -gt 0) {
        $Resp.OutputStream.Write($Body, 0, $Body.Length)
    }
    $Resp.Close()
}

function Send-Json {
    param(
        [System.Net.HttpListenerResponse]$Resp,
        [int]$StatusCode = 200,
        [object]$Payload
    )
    $json = $Payload | ConvertTo-Json -Depth 10 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    Send-Response -Resp $Resp -StatusCode $StatusCode `
        -ContentType 'application/json; charset=utf-8' -Body $bytes
}

# ---------- 3. Helper: proxy one chat call to Zhipu ----------
function Invoke-ZhipuChat {
    param([string]$UserMessage, [string]$SystemPrompt)

    $body = @{
        model    = 'glm-4-flash'
        messages = @(
            @{ role = 'system'; content = $SystemPrompt },
            @{ role = 'user';   content = $UserMessage }
        )
        stream   = $false
    } | ConvertTo-Json -Depth 10

    $headers = @{
        Authorization = "Bearer $apiKey"
        'Content-Type' = 'application/json'
    }

    try {
        $resp = Invoke-RestMethod `
            -Uri 'https://open.bigmodel.cn/api/paas/v4/chat/completions' `
            -Method Post `
            -Headers $headers `
            -Body $body `
            -TimeoutSec 60
        return $resp
    } catch {
        # If we got a structured error from Zhipu, surface it
        if ($_.Exception.Response -and $_.Exception.Response.GetResponseStream()) {
            $r = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $errBody = $r.ReadToEnd()
            throw "Zhipu API error: $errBody"
        }
        throw
    }
}

# ---------- 4. Main request loop ----------
while ($listener.IsListening) {
    try {
        $ctx = $listener.GetContext()
        $req  = $ctx.Request
        $resp = $ctx.Response

        $resp.Headers.Add('Access-Control-Allow-Origin', '*')
        $resp.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        $resp.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')

        # --- CORS preflight ---
        if ($req.HttpMethod -eq 'OPTIONS') {
            Send-Response -Resp $resp -StatusCode 204
            continue
        }

        # --- API: POST /api/chat ---
        if ($req.HttpMethod -eq 'POST' -and $req.Url.AbsolutePath -eq '/api/chat') {
            try {
                $reader = New-Object System.IO.StreamReader($req.InputStream)
                $rawBody = $reader.ReadToEnd()
                $reader.Close()

                $payload = $rawBody | ConvertFrom-Json
                $userMsg = [string]$payload.message
                $sysMsg  = [string]$payload.system

                if ([string]::IsNullOrWhiteSpace($userMsg)) {
                    Send-Json -Resp $resp -StatusCode 400 `
                        -Payload @{ error = 'message is required' }
                    continue
                }

                if ([string]::IsNullOrWhiteSpace($sysMsg)) {
                    $sysMsg = 'You are a warm, knowledgeable college-life planning assistant. ' +
                              'Give concise, practical, encouraging advice. ' +
                              'Topics: courses, schedules, exams, campus life, clubs, mental well-being, careers.'
                }

                Write-Host "[chat] $(Get-Date -Format HH:mm:ss) user='$userMsg'" -ForegroundColor Cyan

                $zhipu = Invoke-ZhipuChat -UserMessage $userMsg -SystemPrompt $sysMsg

                $content = $zhipu.choices[0].message.content
                Write-Host "[chat] $(Get-Date -Format HH:mm:ss) reply_len=$($content.Length)" -ForegroundColor Green

                Send-Json -Resp $resp -Payload @{ reply = $content }
            } catch {
                Write-Host "[chat] ERROR: $($_.Exception.Message)" -ForegroundColor Red
                Send-Json -Resp $resp -StatusCode 500 `
                    -Payload @{ error = $_.Exception.Message }
            }
            continue
        }

        # --- Static files ---
        if ($req.HttpMethod -eq 'GET') {
            $urlPath = $req.Url.AbsolutePath.TrimStart('/')
            if ([string]::IsNullOrWhiteSpace($urlPath)) { $urlPath = 'index.html' }
            $file = Join-Path $root $urlPath

            if ((Test-Path $file) -and -not (Get-Item $file).PSIsContainer) {
                $ext = [IO.Path]::GetExtension($file)
                $mime = switch ($ext) {
                    '.html' { 'text/html; charset=utf-8' }
                    '.css'  { 'text/css; charset=utf-8' }
                    '.js'   { 'application/javascript; charset=utf-8' }
                    '.json' { 'application/json; charset=utf-8' }
                    '.png'  { 'image/png' }
                    '.jpg'  { 'image/jpeg' }
                    '.svg'  { 'image/svg+xml' }
                    default { 'application/octet-stream' }
                }
                $bytes = [IO.File]::ReadAllBytes($file)
                Send-Response -Resp $resp -ContentType $mime -Body $bytes
            } else {
                Send-Response -Resp $resp -StatusCode 404 `
                    -ContentType 'text/plain' -Body ([Text.Encoding]::UTF8.GetBytes('404 Not Found'))
            }
            continue
        }

        # --- Fallback ---
        Send-Response -Resp $resp -StatusCode 405 `
            -ContentType 'text/plain' -Body ([Text.Encoding]::UTF8.GetBytes('Method Not Allowed'))

    } catch {
        Write-Host "[server] Unhandled: $($_.Exception.Message)" -ForegroundColor Red
    }
}
