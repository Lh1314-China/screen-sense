<#
  cdp.ps1 - minimal Chrome DevTools Protocol helpers (PowerShell 5.1 / .NET Framework)

  Why PowerShell: the screen-sense daemon already runs here, and .NET has a
  built-in ClientWebSocket, so there is no extra dependency.

  Requires the target browser to be started with --remote-debugging-port=<port>.
#>

function Get-CdpPages {
    param([int]$Port = 9222, [int]$TimeoutMs = 1500)

    $script:CdpLastError = ""
    $wc = New-Object System.Net.WebClient
    $wc.Proxy = $null
    try {
        $json = $wc.DownloadString("http://127.0.0.1:$Port/json/list")
    } catch {
        $script:CdpLastError = "$($_.Exception.Message)"
        return @()
    } finally {
        $wc.Dispose()
    }
    $all = $json | ConvertFrom-Json
    return @($all | Where-Object { $_.type -eq "page" } | ForEach-Object {
        [ordered]@{
            id    = $_.id
            title = if ($_.title) { $_.title.Substring(0, [Math]::Min(64, $_.title.Length)) } else { "" }
            url   = if ($_.url) { $_.url.Substring(0, [Math]::Min(90, $_.url.Length)) } else { "" }
            ws    = $_.webSocketDebuggerUrl
        }
    })
}

function Invoke-CdpEval {
    param(
        [Parameter(Mandatory = $true)][string]$WsUrl,
        [Parameter(Mandatory = $true)][string]$Expression,
        [int]$TimeoutMs = 2500
    )

    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ct = [System.Threading.CancellationToken]::None
    try {
        if (-not $ws.ConnectAsync([Uri]$WsUrl, $ct).Wait($TimeoutMs)) { throw "connect timeout" }

        $msg = @{ id = 1; method = "Runtime.evaluate"; params = @{ expression = $Expression; returnByValue = $true } } | ConvertTo-Json -Depth 6 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
        $seg = New-Object System.ArraySegment[byte] -ArgumentList (,$bytes)
        if (-not $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait($TimeoutMs)) { throw "send timeout" }

        $buf = New-Object byte[] 131072
        $sb = New-Object System.Text.StringBuilder
        $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
        do {
            $resSeg = New-Object System.ArraySegment[byte] -ArgumentList (,$buf)
            $task = $ws.ReceiveAsync($resSeg, $ct)
            if (-not $task.Wait([Math]::Max(1, [int](($deadline - (Get-Date)).TotalMilliseconds)))) { throw "recv timeout" }
            $r = $task.Result
            [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $r.Count))
        } while (-not $r.EndOfMessage)

        $reply = $sb.ToString() | ConvertFrom-Json
        if ($reply.id -ne 1) { throw "unexpected reply id" }
        return $reply.result.result.value
    } finally {
        try {
            if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "bye", $ct).Wait(500) | Out-Null
            }
        } catch { }
        $ws.Dispose()
    }
}

# Compact page description. Keep the JS small: it runs on every query.
$script:CdpPageProbe = @'
(() => {
  const a = document.activeElement || {};
  const t = (s, n) => (s ? String(s).replace(/\s+/g, " ").trim().slice(0, n) : "");
  const pw = a.type === "password";
  return {
    title: t(document.title, 60),
    active: {
      tag: t(a.tagName, 10).toLowerCase(),
      type: t(a.type, 10),
      name: pw ? "[password]" : t(a.name || a.placeholder || a.id || a.getAttribute && a.getAttribute("aria-label"), 36)
    },
    heads: [...document.querySelectorAll("h1,h2")].slice(0, 2).map(e => t(e.textContent, 32))
  };
})()
'@

function Get-CdpPageInfo {
    param([int]$Port = 9222, [int]$TimeoutMs = 2500)
    $pages = Get-CdpPages -Port $Port
    if (-not $pages -or $pages.Count -eq 0) { return $null }
    $page = $pages[0]
    if (-not $page.ws) { return $null }
    $info = Invoke-CdpEval -WsUrl $page.ws -Expression $script:CdpPageProbe -TimeoutMs $TimeoutMs
    if ($info) {
        return [ordered]@{
            title  = $info.title
            url    = $page.url
            active = $info.active
            heads  = @($info.heads)
        }
    }
    return $null
}
