param([int]$Port = 8080)
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Host "[preview] http://localhost:$Port/" -ForegroundColor Green
function Send-Resp {
    param($resp, [int]$code=200, [string]$ctype='text/plain', [byte[]]$body)
    $resp.StatusCode = $code; $resp.ContentType = $ctype
    if ($body) { $resp.ContentLength64 = $body.Length; $resp.OutputStream.Write($body,0,$body.Length) }
    $resp.Close()
}
$rng = New-Object System.Random
$mocks = @(
    "Great question! Here is a practical 3-step approach: 1) List your must-take courses first, 2) Keep 1-2 slots open for fun electives, 3) Leave Wednesday afternoon free for clubs. Want help with anything specific?",
    "Nice thinking! Let me break this down: 1) Start with textbook examples for each chapter, 2) Practice past 3 years of final exams, 3) Keep a mistake notebook. Does your professor have a review session coming up?",
    "Good call planning ahead! Here are some campus tips: 1) The student union has free resume workshops every Friday, 2) Career fair is next month - mark your calendar, 3) Join the freshman mentorship program if you have not already. What field are you interested in?",
    "Got it! Based on your question, start small and build consistency. Pick one habit you can do daily - even 15 minutes - and stick with it for two weeks before adding more. Let me know how it goes!"
)
while ($listener.IsListening) {
    try {
        $ctx = $listener.GetContext(); $req = $ctx.Request; $resp = $ctx.Response
        $resp.Headers.Add('Access-Control-Allow-Origin','*')
        $resp.Headers.Add('Access-Control-Allow-Headers','Content-Type')
        $resp.Headers.Add('Access-Control-Allow-Methods','GET,POST,OPTIONS')
        if ($req.HttpMethod -eq 'OPTIONS') { Send-Resp $resp 204; continue }
        if ($req.HttpMethod -eq 'POST' -and $req.Url.AbsolutePath -eq '/.netlify/functions/chat') {
            Start-Sleep -Milliseconds 800
            $reply = $mocks[$rng.Next($mocks.Count)]
            $json = (@{ reply = $reply } | ConvertTo-Json -Compress)
            Send-Resp $resp 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
            continue
        }
        if ($req.HttpMethod -eq 'GET') {
            $urlPath = $req.Url.AbsolutePath.TrimStart('/')
            if ([string]::IsNullOrWhiteSpace($urlPath)) { $urlPath = 'index.html' }
            $file = Join-Path $root $urlPath
            if ((Test-Path $file) -and -not (Get-Item $file).PSIsContainer) {
                $ext = [IO.Path]::GetExtension($file)
                $mime = switch ($ext) {
                    '.html'{'text/html; charset=utf-8'} '.css'{'text/css; charset=utf-8'}
                    '.js'{'application/javascript; charset=utf-8'} '.json'{'application/json'}
                    '.png'{'image/png'} '.jpg'{'image/jpeg'} '.svg'{'image/svg+xml'}
                    default{'application/octet-stream'}
                }
                Send-Resp $resp 200 $mime ([IO.File]::ReadAllBytes($file))
            } else {
                Send-Resp $resp 404 'text/plain' ([Text.Encoding]::UTF8.GetBytes('404'))
            }
            continue
        }
        Send-Resp $resp 405
    } catch {}
}
