# DshStateWatcher.ps1 — DSH 状态辅助进程（被 DeepSeekPet.ps1 自动启动）
# 职责：在后台轮询 DSH 本地 API，把结果写成 JSON 状态文件，让宠物主进程
# 绝不在 UI 线程上做任何网络/文件扫描。
# 用法（由宠物自动调用）：
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File DshStateWatcher.ps1 -OutFile <json> -ParentPid <pid>
param(
    [string]$OutFile = '',
    [int]$ParentPid = 0
)

$ErrorActionPreference = 'SilentlyContinue'

function Write-StateFile($obj) {
    if (-not $OutFile) { return }
    try {
        $json = $obj | ConvertTo-Json -Compress -Depth 4
        Set-Content -Path $OutFile -Value $json -Encoding UTF8
    } catch {}
}

# 循环：父进程死了就退出（宠物被强杀时不留孤儿）
while ($true) {
    if ($ParentPid -gt 0) {
        $p = Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
        if (-not $p) { break }
    }

    $state = @{
        ok      = $false
        running = $false
        activity = ''
        time    = [long]((Get-Date).ToUniversalTime().Ticks)
    }

    # 1) 主通道：DSH 本地 RPC（session.list + session.history）
    try {
        $listBody = @{ type = 'client-request'; rpcId = ('pet-' + [guid]::NewGuid().ToString()); method = 'session.list'; payload = @{} } | ConvertTo-Json -Depth 6 -Compress
        $lr = Invoke-RestMethod -Uri 'http://127.0.0.1:3080/api/session.list' -Method Post -ContentType 'application/json' -Body $listBody -TimeoutSec 2
        $items = @($lr.result.value.items)
        $state.ok = $true
        $run = @($items | Where-Object { $_.running })
        if ($run.Count -gt 0) {
            $state.running = $true
            try {
                $sid = $run[0].sessionId
                $histBody = @{ type = 'client-request'; rpcId = ('pet-' + [guid]::NewGuid().ToString()); method = 'session.history'; payload = @{ sessionId = $sid; maxMessages = 1 } } | ConvertTo-Json -Depth 6 -Compress
                $hr = Invoke-RestMethod -Uri 'http://127.0.0.1:3080/api/session.history' -Method Post -ContentType 'application/json' -Body $histBody -TimeoutSec 2
                $evs = @($hr.result.value.events)
                $tool = $null
                $kind = 'thinking'
                for ($i = $evs.Count - 1; $i -ge 0; $i--) {
                    $et = $evs[$i].event.type
                    if ($et -match 'error|failed') { $kind = 'failed'; break }
                    if ($et -eq 'tool/call') {
                        if (-not $tool) { $tool = $evs[$i].event.data.name }
                        $kind = 'tool'
                        break
                    }
                    if ($et -eq 'assistant/chunk' -or $et -eq 'assistant/message') { $kind = 'thinking'; break }
                    if ($et -eq 'user/message') { $kind = 'user'; break }
                }
                if ($kind -eq 'tool' -and $tool) { $state.activity = $tool } else { $state.activity = $kind }
            } catch {}
        }
    } catch {
        # 2) 兜底：DSH 服务不可达时用会话日志 mtime 启发式（同样不阻塞 UI 线程）
        $watch = Join-Path $env:USERPROFILE '.dsh\sessions'
        if (Test-Path $watch) {
            $newest = Get-ChildItem $watch -Recurse -Filter '*.zstd' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
            if ($newest) {
                $state.ok = $true
                $state.running = ((Get-Date).ToUniversalTime() - $newest.LastWriteTimeUtc).TotalSeconds -lt 6
                if ($state.running) { $state.activity = 'working' }
            }
        }
    }

    Write-StateFile $state
    Start-Sleep -Milliseconds 1500
}
