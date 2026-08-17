# DeepSeekPet.ps1 v3 — DeepSeek 桌面宠物「鲸鱼娘」
# 100% 本地运行，不联网（状态通过本地 DSH API 获取，见 DshStateWatcher.ps1）。
# 鲸鱼娘动画素材来自 zhu1090093659/dsh-web-ui 的 dsh-pet 插件（BSD-3-Clause），
# 版权声明见 skins\whale-girl\LICENSE。
# 用法：双击 StartPet.bat，或执行  powershell.exe -File DeepSeekPet.ps1
param(
    [int]$TestSeconds = 0   # 内部测试用：N 秒后自动关闭
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace Win32 -Name Gdi32 -MemberDefinition '[DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr hObject);'

# ---------- 日志（带轮转：超过 256KB 转存 pet.old.log） ----------
function Write-Log([string]$msg) {
    try {
        $logPath = Join-Path $PSScriptRoot 'pet.log'
        if ((Test-Path $logPath) -and ((Get-Item $logPath).Length -gt 256KB)) {
            Remove-Item (Join-Path $PSScriptRoot 'pet.old.log') -Force -ErrorAction SilentlyContinue
            Move-Item $logPath (Join-Path $PSScriptRoot 'pet.old.log') -Force -ErrorAction SilentlyContinue
        }
        $line = ('[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss'), $msg)
        Add-Content -Path $logPath -Value $line -Encoding UTF8
    } catch {}
}

# ---------- 配置读写（提前定义，窗口创建前就要用） ----------
function Load-Cfg {
    $cfg = @{}
    if (Test-Path $script:CfgFile) {
        Get-Content $script:CfgFile -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_ -match '^\s*([A-Za-z]+)\s*=\s*(.*?)\s*$') { $cfg[$Matches[1]] = $Matches[2] }
        }
    } elseif (Test-Path (Join-Path $script:Root 'pet.pos')) {
        $raw = Get-Content (Join-Path $script:Root 'pet.pos') -Raw -ErrorAction SilentlyContinue
        if ($raw -match '^\s*(-?[\d\.]+)\s*,\s*(-?[\d\.]+)') {
            $cfg['left'] = $Matches[1]
            $cfg['top'] = $Matches[2]
        }
    }
    return $cfg
}

function Save-Cfg {
    $lines = @(
        "skin=$($script:SkinId)",
        "size=$($script:SizeKey)",
        "follow=$([int]$script:FollowMouse)",
        "patrol=$([int]$script:PatrolMode)",
        "topmost=$([int]$script:Window.Topmost)",
        "left=$($script:Window.Left)",
        "top=$($script:Window.Top)"
    )
    $lines | Set-Content $script:CfgFile -Encoding UTF8
}

# ---------- 单实例 ----------
$script:Created = $false
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\DeepSeekDesktopPet_Whale', [ref]$script:Created)
if ($script:Created) {
    [void]$script:Mutex.WaitOne()
} else {
    # 已有实例在运行：可能是旧版卡在隐藏桌面上的僵尸实例。
    # 接管：杀掉其它实例，自己成为唯一的新实例（保证双击总能出现在你的桌面上）。
    Write-Log 'second instance: taking over, killing old instances'
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '-File' -and $_.CommandLine -match 'DeepSeekPet\.ps1' -and $_.CommandLine -notmatch '-NonInteractive' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Write-Log "killing old pid $($_.ProcessId)"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '-File' -and $_.CommandLine -match 'DeepSeekPet\.ps1' -and $_.CommandLine -notmatch '-NonInteractive' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Write-Log "killing old pid $($_.ProcessId)"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $script:Mutex.Dispose()
    $tries = 0
    while ($tries -lt 6) {
        Start-Sleep -Milliseconds 500
        $script:Created = $false
        $script:Mutex = New-Object System.Threading.Mutex($false, 'Local\DeepSeekDesktopPet_Whale', [ref]$script:Created)
        if ($script:Created) { [void]$script:Mutex.WaitOne(); break }
        $script:Mutex.Dispose()
        $tries++
    }
    if (-not $script:Created) { Write-Log 'takeover failed, exit'; exit 0 }
    Write-Log 'takeover ok'
}

# ---------- 全局兜底：任何未处理错误写日志，不无声退出 ----------
trap {
    $now = Get-Date
    if (-not $script:LastTrapTime -or ($now - $script:LastTrapTime).TotalSeconds -gt 10) {
        $script:LastTrapTime = $now
        try {
            $line = ('[{0}] TRAP: {1}: {2}' -f $now.ToString('HH:mm:ss'), $_.Exception.GetType().Name, $_.Exception.Message)
            Add-Content -Path (Join-Path $PSScriptRoot 'pet.log') -Value $line -Encoding UTF8
        } catch {}
    }
    continue
}

# ---------- 路径与状态 ----------
$script:Root      = $PSScriptRoot
$script:CfgFile   = Join-Path $script:Root 'pet.cfg'

# 大小档位（标准 = 素材原生分辨率 192x208）
$script:SizeKey    = 'large'
$script:SizeTable  = @{ small = 0.9; normal = 1.28; large = 1.6; xlarge = 2.0 }
$script:SizeNames  = @{ small = '小'; normal = '标准'; large = '大'; xlarge = '特大' }
$script:SizeFactor = 1.6
$script:Cfg = Load-Cfg
if ($script:Cfg.ContainsKey('size') -and $script:SizeTable.ContainsKey($script:Cfg['size'])) {
    $script:SizeKey = $script:Cfg['size']
    $script:SizeFactor = $script:SizeTable[$script:SizeKey]
}

$script:Sleeping  = $false
$script:Dragging  = $false
$script:MovedPx   = 0
$script:LastX     = 0
$script:LastY     = 0
$script:DPI       = 1.0
$script:TickCount = 0.0
$script:Bounce    = 1.0
$script:Mode      = 'idle'          # idle | working | celebrate | sleep
$script:Jumping   = $false
$script:JumpY     = 0.0
$script:Vy        = 0.0
$script:SpinAngle = 0.0
$script:FollowMouse = $false
$script:PatrolMode  = $false
$script:SkinId      = 'whalegirl'
$script:CurrentAnim = 'Idle'
$script:TransientAnim  = $null
$script:TransientUntil = [datetime]::MinValue
$script:FrameIndex  = 0
$script:FrameAccum  = 0.0
$script:WorkNotified = $false
$script:WasWorking   = $false
$script:WorkStart    = [datetime]::MinValue
$script:LastActivity = ''

# 待机活动状态
$script:Wandering    = $false
$script:WanderDir    = 1
$script:WanderSteps  = 0
$script:LastInteract = Get-Date

# 工具名/状态 → 中文显示
$script:ToolNames = @{
    'read' = '读文件'; 'edit' = '改文件'; 'write' = '写文件'; 'glob' = '搜文件'; 'grep' = '搜代码';
    'pwsh' = '跑命令'; 'web_search' = '上网搜索'; 'read_image' = '看图片';
    'subagent' = '派子智能体'; 'subagent_fork' = '派子智能体'; 'workflow' = '多智能体编排';
    'todo_write' = '更新任务清单'; 'ask_user_question' = '向你提问'; 'skill' = '加载技能';
    'create_goal' = '创建目标'; 'update_goal' = '更新目标'; 'get_goal' = '查看目标';
    'exit_plan_mode' = '提交计划'; 'ralph' = 'Ralph 迭代';
    'job_output' = '查后台任务'; 'job_kill' = '停后台任务'; 'job_list' = '列后台任务';
    'list_agents' = '查看子智能体'; 'send_message' = '给子智能体传话'; 'interrupt_agent' = '打断子智能体';
    'thinking' = '思考中'; 'user' = '等你发话'; 'working' = '干活中'; 'failed' = '出错了'
}

# ---------- 台词 ----------
$script:IdleLines = @(
    '我在陪着你写代码哦 🐳',
    '别急，慢慢来～',
    '记得保存文件！',
    '喝口水休息一下 💧',
    '有 bug 很正常，我们一起来修',
    '今天也要元气满满！',
    '加油，你比想象中更强',
    '写累了就摸摸我呀'
)
$script:WorkLines = @(
    'DeepSeek 正在干活，我转圈圈给它加油～',
    '智能体正在努力，鲸鱼娘待命中…',
    '干活中！加油加油！',
    '我看它马上就好啦，稍等哦～'
)
$script:DoneLines = @(
    '干完啦！🎉 鲸鱼娘为你欢呼',
    '任务完成～撒花 🎊',
    '搞定！给你转个圈庆祝一下',
    '大功告成，奖励一条小鱼干？'
)
$script:FoodLines = @(
    '小鱼干真好吃！( ˶ˆᗜˆ˵ )',
    '再来一条嘛～',
    '饱饱的，充满干劲！'
)
$script:PetLines = @(
    '嘿嘿，好舒服～',
    '摸摸头，代码少出错～',
    '最喜欢你啦！'
)

# ---------- GIF 解码：把动画 GIF 拆成帧 + 每帧时长 ----------
function Convert-GifToFrames([string]$Path) {
    $img = [System.Drawing.Image]::FromFile($Path)
    try {
        $dim = New-Object System.Drawing.Imaging.FrameDimension($img.FrameDimensionsList[0])
        $count = $img.GetFrameCount($dim)
        $frames = New-Object 'System.Collections.Generic.List[System.Windows.Media.Imaging.BitmapSource]'
        $delays = New-Object 'System.Collections.Generic.List[int]'
        for ($i = 0; $i -lt $count; $i++) {
            $img.SelectActiveFrame($dim, $i) | Out-Null
            $bmp = New-Object System.Drawing.Bitmap($img)
            $h = $bmp.GetHbitmap()
            try {
                $bs = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHBitmap(
                    $h, [IntPtr]::Zero, [System.Windows.Int32Rect]::Empty,
                    [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
                $bs.Freeze()
                $frames.Add($bs)
            } finally {
                [Win32.Gdi32]::DeleteObject($h) | Out-Null
                $bmp.Dispose()
            }
            $delays.Add(10)
        }
        try {
            $prop = $img.GetPropertyItem(0x5100)   # PropertyTagFrameDelay（1/100 秒）
            if ($prop) {
                for ($i = 0; $i -lt $count; $i++) {
                    $d = [BitConverter]::ToInt32($prop.Value, $i * 4)
                    if ($d -gt 0 -and $i -lt $delays.Count) { $delays[$i] = $d }
                }
            }
        } catch {}
        return @{ Frames = $frames; Delays = $delays }
    } finally {
        $img.Dispose()
    }
}

# ---------- 皮肤注册表 ----------
$script:Skins = @{}

foreach ($s in @(
    @{ Id = 'whalegirl'; Name = '鲸鱼娘';  Emoji = $null },
    @{ Id = 'whale';     Name = '经典小鲸'; Emoji = '🐳' },
    @{ Id = 'blue';      Name = '蓝鲸';     Emoji = '🐋' },
    @{ Id = 'dolphin';   Name = '海豚';     Emoji = '🐬' },
    @{ Id = 'seal';      Name = '海豹';     Emoji = '🦭' }
)) { $script:Skins[$s.Id] = $s }

# 鲸鱼娘：加载官方 9 态动画（失败则回退 emoji 小鲸）
$wgDir = Join-Path $script:Root 'skins\whale-girl'
try {
    $wg = $script:Skins['whalegirl']
    $wg.Type      = 'gif'
    $wg.Idle      = Convert-GifToFrames (Join-Path $wgDir 'idle.gif')
    $wg.Wave      = Convert-GifToFrames (Join-Path $wgDir 'waving.gif')
    $wg.Working   = Convert-GifToFrames (Join-Path $wgDir 'running.gif')
    $wg.Celebrate = Convert-GifToFrames (Join-Path $wgDir 'jumping.gif')
    $wg.Sleep     = Convert-GifToFrames (Join-Path $wgDir 'waiting.gif')
    $wg.RunningRight = Convert-GifToFrames (Join-Path $wgDir 'running-right.gif')
    $wg.RunningLeft  = Convert-GifToFrames (Join-Path $wgDir 'running-left.gif')
    $wg.Review    = Convert-GifToFrames (Join-Path $wgDir 'review.gif')
    $wg.Failed    = Convert-GifToFrames (Join-Path $wgDir 'failed.gif')
    $wg.Waiting   = Convert-GifToFrames (Join-Path $wgDir 'waiting.gif')
    Write-Log "gif ok: idle=$($wg.Idle.Frames.Count) wave=$($wg.Wave.Frames.Count) run=$($wg.Working.Frames.Count) jump=$($wg.Celebrate.Frames.Count) wait=$($wg.Waiting.Frames.Count) runR=$($wg.RunningRight.Frames.Count) runL=$($wg.RunningLeft.Frames.Count) review=$($wg.Review.Frames.Count) failed=$($wg.Failed.Frames.Count)"
} catch {
    $script:Skins['whalegirl'].Type = 'missing'
    Write-Log "gif load FAILED: $($_.Exception.Message)"
}

# ---------- 窗口 ----------
$script:Window = New-Object System.Windows.Window
$script:Window.Title = 'DeepSeek 桌面宠物'
$script:Window.WindowStyle = 'None'
$script:Window.AllowsTransparency = $true
$script:Window.Background = [System.Windows.Media.Brushes]::Transparent
$script:Window.ResizeMode = 'NoResize'
$script:Window.Topmost = $true
$script:Window.ShowInTaskbar = $false
$script:Window.Width = 190 * $script:SizeFactor
$script:Window.Height = 212 * $script:SizeFactor

$grid = New-Object System.Windows.Controls.Grid
$script:Window.Content = $grid

# 演员容器：emoji 文字 + GIF 图片共用一个变换（弹跳/旋转/位移）
$script:Actor = New-Object System.Windows.Controls.Grid
$script:Actor.Width = 150 * $script:SizeFactor
$script:Actor.Height = 165 * $script:SizeFactor
$script:Actor.HorizontalAlignment = 'Center'
$script:Actor.VerticalAlignment = 'Bottom'
$actorMargin = 8 * $script:SizeFactor
$script:Actor.Margin = New-Object System.Windows.Thickness(0, 0, 0, $actorMargin)
$script:Actor.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)

$tg = New-Object System.Windows.Media.TransformGroup
$script:ScaleT = New-Object System.Windows.Media.ScaleTransform(1, 1)
$script:RotT   = New-Object System.Windows.Media.RotateTransform(0)
$script:MoveT  = New-Object System.Windows.Media.TranslateTransform(0, 0)
[void]$tg.Children.Add($script:ScaleT)
[void]$tg.Children.Add($script:RotT)
[void]$tg.Children.Add($script:MoveT)
$script:Actor.RenderTransform = $tg

$script:Whale = New-Object System.Windows.Controls.TextBlock
$script:Whale.Text = '🐳'
$script:Whale.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI Emoji')
$script:Whale.FontSize = 84 * $script:SizeFactor
$script:Whale.HorizontalAlignment = 'Center'
$script:Whale.VerticalAlignment = 'Center'
[void]$script:Actor.Children.Add($script:Whale)

$script:PetImage = New-Object System.Windows.Controls.Image
$script:PetImage.Stretch = 'Uniform'
$script:PetImage.Width = 150 * $script:SizeFactor
$script:PetImage.Height = 165 * $script:SizeFactor
$script:PetImage.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
$script:PetFlip = New-Object System.Windows.Media.ScaleTransform(1, 1)
$script:PetImage.RenderTransform = $script:PetFlip
$script:PetImage.Visibility = 'Collapsed'
[void]$script:Actor.Children.Add($script:PetImage)

[void]$grid.Children.Add($script:Actor)

# ---------- 气泡 ----------
$script:Bubble = New-Object System.Windows.Controls.Primitives.Popup
$script:Bubble.AllowsTransparency = $true
$script:Bubble.PlacementTarget = $script:Window
$script:Bubble.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Top
$script:Bubble.StaysOpen = $false
$script:Bubble.PopupAnimation = 'Fade'
$script:Bubble.Width = 270 * $script:SizeFactor

$conv = New-Object System.Windows.Media.BrushConverter
$border = New-Object System.Windows.Controls.Border
$border.Background = $conv.ConvertFromString('#F7FFFDF5')
$border.BorderBrush = $conv.ConvertFromString('#FFB9C6F2')
$border.BorderThickness = New-Object System.Windows.Thickness(1.5)
$border.CornerRadius = New-Object System.Windows.CornerRadius(12)
$border.Padding = New-Object System.Windows.Thickness(12, 8, 12, 8)

$script:BubbleText = New-Object System.Windows.Controls.TextBlock
$script:BubbleText.FontSize = 14 * $script:SizeFactor
$script:BubbleText.Foreground = $conv.ConvertFromString('#FF33415C')
$script:BubbleText.TextWrapping = 'Wrap'
$border.Child = $script:BubbleText
$script:Bubble.Child = $border

$script:BubbleHide = New-Object System.Windows.Threading.DispatcherTimer
$script:BubbleHide.Interval = [TimeSpan]::FromMilliseconds(3800)
$script:BubbleHide.Add_Tick({
    $script:Bubble.IsOpen = $false
    $script:BubbleHide.Stop()
})

function Show-Bubble([string]$text, [bool]$sticky = $false) {
    $script:BubbleText.Text = $text
    $script:Bubble.IsOpen = $true
    $script:BubbleHide.Stop()
    if (-not $sticky) { $script:BubbleHide.Start() }
}

# ---------- 动画切换 ----------
function Get-ModeAnim([string]$mode) {
    switch ($mode) {
        'working'   { return 'Working' }
        'celebrate' { return 'Celebrate' }
        'sleep'     { return 'Sleep' }
        default     { return 'Idle' }
    }
}

function Set-Anim([string]$name) {
    $script:CurrentAnim = $name
    $script:FrameIndex = 0
    $script:FrameAccum = 0.0
    $skin = $script:Skins[$script:SkinId]
    if ($skin.Type -eq 'gif') {
        $data = $skin[$name]
        if ($data) { $script:PetImage.Source = $data.Frames[0] }
    } else {
        if ($name -eq 'Sleep') { $script:Whale.Text = '😴' }
        else { $script:Whale.Text = $skin.Emoji }
    }
}

function Start-Transient([string]$anim, [double]$seconds) {
    $script:TransientAnim = $anim
    $script:TransientUntil = (Get-Date).AddSeconds($seconds)
    $skin = $script:Skins[$script:SkinId]
    if ($skin.Type -eq 'gif') {
        $data = $skin[$anim]
        if ($data) {
            $script:FrameIndex = 0
            $script:FrameAccum = 0.0
            $script:PetImage.Source = $data.Frames[0]
        }
    }
}

function Start-Jump {
    if ($script:Jumping) { return }
    $script:Jumping = $true
    $script:JumpY = -2.0
    $script:Vy = -12.0 * $script:SizeFactor
}

# ---------- 皮肤应用 ----------
function Apply-Skin([string]$id) {
    if (-not $script:Skins.ContainsKey($id)) { return }
    $script:SkinId = $id
    $skin = $script:Skins[$id]
    $isGif = ($skin.Type -eq 'gif' -and $skin.ContainsKey('Idle'))
    if ($isGif) {
        $script:Whale.Visibility = 'Collapsed'
        $script:PetImage.Visibility = 'Visible'
    } else {
        $script:Whale.Visibility = 'Visible'
        $script:PetImage.Visibility = 'Collapsed'
        if (-not $skin.Emoji) { $script:Whale.Text = '🐳' } else { $script:Whale.Text = $skin.Emoji }
    }
    Set-Anim (Get-ModeAnim $script:Mode)
    try { Save-Cfg } catch {}
}

# ---------- 多屏边界 ----------
function Get-ScreenBounds {
    $minX = [int]::MaxValue; $minY = [int]::MaxValue
    $maxX = [int]::MinValue; $maxY = [int]::MinValue
    foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
        if ($s.Bounds.X -lt $minX) { $minX = $s.Bounds.X }
        if ($s.Bounds.Y -lt $minY) { $minY = $s.Bounds.Y }
        if ($s.Bounds.Right -gt $maxX) { $maxX = $s.Bounds.Right }
        if ($s.Bounds.Bottom -gt $maxY) { $maxY = $s.Bounds.Bottom }
    }
    return @{ X = $minX; Y = $minY; Right = $maxX; Bottom = $maxY }
}

# ---------- 大小切换 ----------
function Apply-Size([string]$key) {
    if (-not $script:SizeTable.ContainsKey($key)) { return }
    $script:SizeKey = $key
    $script:SizeFactor = $script:SizeTable[$key]
    $script:Window.Width = 190 * $script:SizeFactor
    $script:Window.Height = 212 * $script:SizeFactor
    $script:Actor.Width = 150 * $script:SizeFactor
    $script:Actor.Height = 165 * $script:SizeFactor
    $am = 8 * $script:SizeFactor
    $script:Actor.Margin = New-Object System.Windows.Thickness(0, 0, 0, $am)
    $script:PetImage.Width = 150 * $script:SizeFactor
    $script:PetImage.Height = 165 * $script:SizeFactor
    $script:Whale.FontSize = 84 * $script:SizeFactor
    $script:Bubble.Width = 270 * $script:SizeFactor
    $script:BubbleText.FontSize = 14 * $script:SizeFactor
    # 变大后若超出屏幕（全部显示器并集），拉回屏幕内
    $sb = Get-ScreenBounds
    $maxL = ($sb.Right - $script:Window.Width) / $script:DPI
    $maxT = ($sb.Bottom - $script:Window.Height) / $script:DPI
    if ($script:Window.Left -gt $maxL) { $script:Window.Left = $maxL }
    if ($script:Window.Top -gt $maxT) { $script:Window.Top = $maxT }
    if ($script:Window.Left -lt ($sb.X / $script:DPI)) { $script:Window.Left = $sb.X / $script:DPI }
    if ($script:Window.Top -lt ($sb.Y / $script:DPI)) { $script:Window.Top = $sb.Y / $script:DPI }
    foreach ($k in $script:SizeMenuItems.Keys) { $script:SizeMenuItems[$k].IsChecked = ($k -eq $key) }
    Write-Log "size: $key x$($script:SizeFactor)"
    try { Save-Cfg } catch {}
}

# ---------- 模式 ----------
function Set-Mode([string]$mode) {
    if ($script:Mode -ne $mode) { Write-Log "mode: $($script:Mode) -> $mode" }
    $script:Mode = $mode
    Set-Anim (Get-ModeAnim $mode)
}

function Set-SleepState([bool]$sleep) {
    $script:Sleeping = $sleep
    if ($sleep) {
        Set-Mode 'sleep'
        $script:Window.Opacity = 0.7
        $script:Bubble.IsOpen = $false
        $script:BubbleHide.Stop()
        $script:Jumping = $false
        $script:JumpY = 0.0
    } else {
        $script:Window.Opacity = 1.0
        Set-Mode 'idle'
        Show-Bubble '睡醒啦～刚才梦到你在写代码'
        if ($script:PatrolMode) { Start-Wander -Long }
    }
}

function Start-Celebrate {
    if ($script:Sleeping) { return }
    Set-Mode 'celebrate'
    Start-Jump
    Show-Bubble ($script:DoneLines | Get-Random)
    $script:CelebrateTimer.Stop()
    $script:CelebrateTimer.Start()
}

function Invoke-Click {
    if ($script:Sleeping) { Set-SleepState $false; return }
    $script:LastInteract = Get-Date
    Start-Jump
    Start-Transient 'Wave' 1.3
    Show-Bubble ($script:IdleLines | Get-Random)
}

# ---------- 待机活动：随机散步 / 打哈欠 / 小跳 / 挥手 / 闲聊 / 打盹 ----------
function Start-Wander([switch]$Long) {
    if ($script:Jumping -or $script:Wandering) { return }
    $script:Wandering = $true
    $script:WanderDir = if ((Get-Random -Maximum 2) -eq 0) { -1 } else { 1 }
    $script:WanderSteps = if ($Long) { Get-Random -Minimum 150 -Maximum 350 } else { Get-Random -Minimum 50 -Maximum 140 }
    Write-Log "idle-action: wander dir=$($script:WanderDir) steps=$($script:WanderSteps)"
}

function Start-IdleAction {
    if ($script:Sleeping -or $script:Dragging -or $script:Mode -ne 'idle') { return }
    if ($script:TransientAnim -or $script:Wandering -or $script:Jumping) { return }
    if ($script:PatrolMode) { return }   # 巡逻时她自己找乐子，不抢戏
    $idleMins = ((Get-Date) - $script:LastInteract).TotalMinutes
    $roll = Get-Random -Maximum 100
    if ($idleMins -ge 3 -and $roll -lt 20) {
        # 长时间没人理：打个小盹
        Start-Transient 'Waiting' 4.0
        Show-Bubble '💤 打个盹…你回来了叫醒我哦'
        Write-Log 'idle-action: nap'
    } elseif ($roll -lt 40) {
        Start-Wander
    } elseif ($roll -lt 55) {
        $script:Bounce = 1.25
        Start-Transient 'Wave' 1.3
        Show-Bubble ($script:IdleLines | Get-Random)
        Write-Log 'idle-action: wave'
    } elseif ($roll -lt 70) {
        Start-Jump
        Write-Log 'idle-action: hop'
    } elseif ($roll -lt 85) {
        Start-Transient 'Waiting' 1.6
        Show-Bubble '啊～有点困'
        Write-Log 'idle-action: yawn'
    } else {
        Show-Bubble ($script:IdleLines | Get-Random)
        Write-Log 'idle-action: talk'
    }
    $next = Get-Random -Minimum 18 -Maximum 45
    $script:IdleActionTimer.Interval = [TimeSpan]::FromSeconds($next)
    $script:IdleActionTimer.Start()
}

# ---------- 拖拽 ----------
$script:Window.Add_MouseLeftButtonDown({
    $script:Dragging = $true
    $script:MovedPx = 0
    $script:LastX = [System.Windows.Forms.Cursor]::Position.X
    $script:LastY = [System.Windows.Forms.Cursor]::Position.Y
    $script:Window.CaptureMouse() | Out-Null
})

$script:Window.Add_MouseMove({
    if ($script:Dragging) {
        if ($script:DPI -le 0) { $script:DPI = 1 }
        $now = [System.Windows.Forms.Cursor]::Position
        $dx = ($now.X - $script:LastX) / $script:DPI
        $dy = ($now.Y - $script:LastY) / $script:DPI
        $script:MovedPx += [Math]::Abs($now.X - $script:LastX) + [Math]::Abs($now.Y - $script:LastY)
        $script:Window.Left += $dx
        $script:Window.Top += $dy
        $script:LastX = $now.X
        $script:LastY = $now.Y
    }
})

$script:Window.Add_MouseLeftButtonUp({
    if ($script:Dragging) {
        $script:Dragging = $false
        $script:LastInteract = Get-Date
        try { $script:Window.ReleaseMouseCapture() | Out-Null } catch {}
        if ($script:MovedPx -lt 8) { Invoke-Click } else { try { Save-Cfg } catch {} }
    }
})

# ---------- 右键菜单 ----------
$menu = New-Object System.Windows.Controls.ContextMenu

$miPet = New-Object System.Windows.Controls.MenuItem
$miPet.Header = '摸摸头'
$miPet.Add_Click({ $script:LastInteract = Get-Date; Start-Jump; Start-Transient 'Wave' 1.3; Show-Bubble ($script:PetLines | Get-Random) })
[void]$menu.Items.Add($miPet)

$miFood = New-Object System.Windows.Controls.MenuItem
$miFood.Header = '喂小鱼干 🐟'
$miFood.Add_Click({ $script:LastInteract = Get-Date; Start-Jump; Start-Transient 'Wave' 1.3; Show-Bubble ($script:FoodLines | Get-Random) })
[void]$menu.Items.Add($miFood)

$miSay = New-Object System.Windows.Controls.MenuItem
$miSay.Header = '说句话'
$miSay.Add_Click({ Show-Bubble ($script:IdleLines | Get-Random) })
[void]$menu.Items.Add($miSay)

$miWalk = New-Object System.Windows.Controls.MenuItem
$miWalk.Header = '去散步 🚶'
$miWalk.Add_Click({
    $script:LastInteract = Get-Date
    if ($script:Sleeping) { Set-SleepState $false }
    if ($script:Mode -ne 'idle') { Set-Mode 'idle' }
    Start-Wander -Long
})
[void]$menu.Items.Add($miWalk)

$miPatrol = New-Object System.Windows.Controls.MenuItem
$miPatrol.Header = '巡逻模式（不停散步）🚶‍♂️'
$miPatrol.IsCheckable = $true
$miPatrol.Add_Click({
    $script:PatrolMode = $miPatrol.IsChecked
    if ($script:PatrolMode) {
        $script:LastInteract = Get-Date
        if ($script:Sleeping) { Set-SleepState $false }
        if ($script:Mode -ne 'idle') { Set-Mode 'idle' }
        Start-Wander -Long
        Show-Bubble '巡逻模式启动！绕屏幕散步去～'
    } else {
        $script:Wandering = $false
        Show-Bubble '巡逻结束，歇会儿～'
    }
    try { Save-Cfg } catch {}
})
[void]$menu.Items.Add($miPatrol)

$miSkin = New-Object System.Windows.Controls.MenuItem
$miSkin.Header = '皮肤'
foreach ($k in @('whalegirl', 'whale', 'blue', 'dolphin', 'seal')) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $script:Skins[$k].Name
    $mi.Tag = $k
    $mi.Add_Click({ Apply-Skin $this.Tag })
    [void]$miSkin.Items.Add($mi)
}
[void]$menu.Items.Add($miSkin)

$miSize = New-Object System.Windows.Controls.MenuItem
$miSize.Header = '大小'
$script:SizeMenuItems = @{}
foreach ($k in @('small', 'normal', 'large', 'xlarge')) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $script:SizeNames[$k]
    $mi.Tag = $k
    $mi.IsCheckable = $true
    $mi.Add_Click({ Apply-Size $this.Tag })
    $script:SizeMenuItems[$k] = $mi
    [void]$miSize.Items.Add($mi)
}
[void]$menu.Items.Add($miSize)

$miFollow = New-Object System.Windows.Controls.MenuItem
$miFollow.Header = '跟随鼠标'
$miFollow.IsCheckable = $true
$miFollow.Add_Click({ $script:FollowMouse = $miFollow.IsChecked; try { Save-Cfg } catch {} })
[void]$menu.Items.Add($miFollow)

$miSleep = New-Object System.Windows.Controls.MenuItem
$miSleep.Header = '睡觉 / 醒来'
$miSleep.Add_Click({ Set-SleepState (-not $script:Sleeping) })
[void]$menu.Items.Add($miSleep)

$miTop = New-Object System.Windows.Controls.MenuItem
$miTop.Header = '始终置顶'
$miTop.IsCheckable = $true
$miTop.IsChecked = $true
$miTop.Add_Click({ $script:Window.Topmost = $miTop.IsChecked; try { Save-Cfg } catch {} })
[void]$menu.Items.Add($miTop)

[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))

$miQuit = New-Object System.Windows.Controls.MenuItem
$miQuit.Header = '退出'
$miQuit.Add_Click({ $script:Window.Close() })
[void]$menu.Items.Add($miQuit)

$script:Window.ContextMenu = $menu

# ---------- 庆祝计时 ----------
$script:CelebrateTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:CelebrateTimer.Interval = [TimeSpan]::FromMilliseconds(2600)
$script:CelebrateTimer.Add_Tick({
    $script:CelebrateTimer.Stop()
    if (-not $script:Sleeping -and $script:Mode -eq 'celebrate') {
        Set-Mode 'idle'
        Show-Bubble '搞定啦～等你发指令 🐳'
    }
})

# ---------- 主循环 ----------
$script:MainTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:MainTimer.Interval = [TimeSpan]::FromMilliseconds(33)
$script:MainTimer.Add_Tick({
    $script:TickCount += 0.033

    # GIF 帧推进
    $skin = $script:Skins[$script:SkinId]
    if ($skin.Type -eq 'gif') {
        $anim = $script:CurrentAnim
        if ($script:TransientAnim) {
            if ((Get-Date) -le $script:TransientUntil) { $anim = $script:TransientAnim }
            else {
                $script:TransientAnim = $null
                Set-Anim $script:CurrentAnim
            }
        }
        # 跟随鼠标时换成跑动动画（左右方向各一套，官方 9 态全部上岗）
        if (-not $script:TransientAnim -and $script:FollowMouse -and -not $script:Dragging -and -not $script:Sleeping -and $script:Mode -eq 'idle') {
            $ftx = [System.Windows.Forms.Cursor]::Position.X / $script:DPI - $script:Window.Width / 2
            $fdx = $ftx - $script:Window.Left
            if ([Math]::Abs($fdx) -gt 8) {
                if ($fdx -lt 0) { $anim = 'RunningLeft' } else { $anim = 'RunningRight' }
            }
        }
        # 待机散步时同样换成跑动动画
        if (-not $script:TransientAnim -and $script:Wandering -and $skin.ContainsKey('RunningLeft')) {
            if ($script:WanderDir -lt 0) { $anim = 'RunningLeft' } else { $anim = 'RunningRight' }
        }
        $data = $skin[$anim]
        if ($data -and $data.Frames.Count -gt 0) {
            $script:FrameAccum += 33
            $d = $data.Delays[$script:FrameIndex] * 10   # 1/100s -> ms
            if ($d -lt 40) { $d = 40 }
            if ($script:FrameAccum -ge $d) {
                $script:FrameAccum = 0
                $script:FrameIndex = ($script:FrameIndex + 1) % $data.Frames.Count
                $script:PetImage.Source = $data.Frames[$script:FrameIndex]
            }
        }
    }

    # 弹跳回弹
    $script:Bounce += (1.0 - $script:Bounce) * 0.12
    if ([Math]::Abs($script:Bounce - 1.0) -lt 0.004) { $script:Bounce = 1.0 }
    $script:ScaleT.ScaleX = $script:Bounce
    $script:ScaleT.ScaleY = $script:Bounce

    # 垂直漂浮 / 旋转
    $bob = 0.0
    if (-not $script:Sleeping) {
        if ($script:Mode -eq 'idle') { $bob = [Math]::Sin($script:TickCount * 2.1) * 5 * $script:SizeFactor }
        if ($script:Mode -eq 'working') {
            $script:SpinAngle = ($script:SpinAngle + 5) % 360
            $script:RotT.Angle = $script:SpinAngle
        } elseif ($script:Mode -eq 'celebrate') {
            $script:RotT.Angle = [Math]::Sin($script:TickCount * 4) * 12
        } else {
            $script:RotT.Angle = [Math]::Sin($script:TickCount * 1.3) * 5
        }
    } else {
        $script:RotT.Angle = 0
    }

    # 跳跃物理（Y 轴向下为正：重力让 Vy 增加，落地后复位）
    if ($script:Jumping) {
        $script:Vy += 1.2 * $script:SizeFactor
        $script:JumpY += $script:Vy
        if ($script:JumpY -ge 0) {
            $script:JumpY = 0.0
            $script:Vy = 0.0
            $script:Jumping = $false
            $script:Bounce = 0.86
        }
        if ($script:JumpY -lt (-400 * $script:SizeFactor)) {   # 兜底：任何异常都不许飞出窗口
            $script:JumpY = 0.0
            $script:Vy = 0.0
            $script:Jumping = $false
        }
    }
    $script:MoveT.Y = $bob + $script:JumpY

    # 待机散步（水平移动，到屏幕边缘自动停下并保存位置；巡逻模式则掉头继续走）
    if ($script:Wandering -and -not $script:Sleeping -and -not $script:Dragging) {
        $sb2 = Get-ScreenBounds
        $minX = $sb2.X / $script:DPI
        $maxX = ($sb2.Right - $script:Window.Width) / $script:DPI
        $script:Window.Left += $script:WanderDir * 2
        $script:WanderSteps--
        if ($script:Window.Left -le $minX -or $script:Window.Left -ge $maxX -or $script:WanderSteps -le 0) {
            $script:Window.Left = [Math]::Max($minX, [Math]::Min($script:Window.Left, $maxX))
            if ($script:PatrolMode) {
                # 巡逻：掉头继续走
                $script:WanderDir = -$script:WanderDir
                $script:WanderSteps = Get-Random -Minimum 120 -Maximum 400
                Write-Log 'idle-action: patrol turn'
            } else {
                $script:Wandering = $false
                Write-Log 'idle-action: wander done'
                try { Save-Cfg } catch {}
            }
        }
    }

    # 跟随鼠标
    if ($script:FollowMouse -and -not $script:Dragging -and -not $script:Sleeping) {
        $tx = [System.Windows.Forms.Cursor]::Position.X / $script:DPI - $script:Window.Width / 2
        $ty = [System.Windows.Forms.Cursor]::Position.Y / $script:DPI - $script:Window.Height / 2
        $script:Window.Left += ($tx - $script:Window.Left) * 0.06
        $script:Window.Top += ($ty - $script:Window.Top) * 0.06
    }
})

# ---------- 随机闲聊 ----------
$script:IdleTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:IdleTimer.Interval = [TimeSpan]::FromSeconds(110)
$script:IdleTimer.Add_Tick({
    if (-not $script:Sleeping -and $script:Mode -eq 'idle' -and -not $script:Wandering) {
        if ((Get-Random -Maximum 100) -lt 35) {
            Show-Bubble ($script:IdleLines | Get-Random)
        }
    }
})

# ---------- 待机活动调度（随机间隔 18-45 秒） ----------
$script:IdleActionTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:IdleActionTimer.Interval = [TimeSpan]::FromSeconds(25)
$script:IdleActionTimer.Add_Tick({
    $script:IdleActionTimer.Stop()
    Start-IdleAction
})

# ---------- DSH 状态引擎（辅助进程轮询，UI 线程只读状态文件） ----------
$script:StateFile = Join-Path $env:TEMP 'dsh-pet-state.json'
$script:WatcherPid = 0

function Start-StateWatcher {
    if ($script:WatcherPid) {
        $alive = Get-Process -Id $script:WatcherPid -ErrorAction SilentlyContinue
        if ($alive) { return }
    }
    try {
        $helper = Join-Path $script:Root 'DshStateWatcher.ps1'
        if (-not (Test-Path $helper)) { Write-Log 'helper script missing'; return }
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $helper), '-OutFile', ('"{0}"' -f $script:StateFile), '-ParentPid', "$PID")
        $p = Start-Process powershell.exe -ArgumentList $args -PassThru -WindowStyle Hidden
        $script:WatcherPid = $p.Id
        Write-Log "watcher helper pid $($p.Id)"
    } catch {
        Write-Log "watcher start fail: $($_.Exception.Message)"
    }
}

$script:WatchTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:WatchTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
$script:WatchTimer.Add_Tick({
    try {
        if (-not $script:WatcherPid) { Start-StateWatcher; return }
        if (-not (Test-Path $script:StateFile)) { return }
        $raw = Get-Content $script:StateFile -Raw -ErrorAction SilentlyContinue
        if (-not $raw) { return }
        try { $state = $raw | ConvertFrom-Json } catch { return }
        if (-not $state -or -not ($state.PSObject.Properties.Name -contains 'ok')) { return }
        # 新鲜度检查：辅助进程卡死时保持现状，不瞎报
        $age = ((Get-Date).ToUniversalTime().Ticks - [long]$state.time) / 10000000.0
        if ($age -gt 8) { return }

        if ($state.running) {
            if (-not $script:WasWorking) { $script:WorkStart = Get-Date }
            $script:WasWorking = $true
            if (-not $script:Sleeping -and $script:Mode -eq 'idle') {
                Write-Log 'watcher: work start'
                Set-Mode 'working'
                $script:LastActivity = ''
            }
            if (-not $script:Sleeping -and $script:Mode -eq 'working') {
                if ($state.activity -and $state.activity -ne $script:LastActivity) {
                    $script:LastActivity = $state.activity
                    Write-Log "activity: $($state.activity)"
                    $label = $script:ToolNames[$state.activity]
                    if (-not $label) { $label = $state.activity }
                    # 动画映射（官方 9 态）：思考→running，工具→running-right，
                    # 出错→failed，向你提问→review，其余→running
                    if ($state.activity -eq 'failed') {
                        Set-Anim 'Failed'
                        Show-Bubble '出错了，别灰心 🥺'
                    } elseif ($state.activity -eq 'ask_user_question') {
                        Set-Anim 'Review'
                        Show-Bubble "有问题要问你～" $true
                    } elseif ($state.activity -in @('thinking', 'user', 'working')) {
                        Set-Anim 'Working'
                        Show-Bubble "正在：$label" $true
                    } else {
                        Set-Anim 'RunningRight'
                        Show-Bubble "正在：$label" $true
                    }
                }
            }
        } else {
            if ($script:WasWorking) {
                $script:WasWorking = $false
                $dur = ((Get-Date) - $script:WorkStart).TotalSeconds
                Write-Log "watcher: work end dur=$([int]$dur)s"
                if ($dur -ge 8 -and -not $script:Sleeping) { Start-Celebrate }
                elseif (-not $script:Sleeping -and $script:Mode -eq 'working') {
                    Set-Mode 'idle'
                    Show-Bubble '搞定啦～等你发指令 🐳'
                }
            }
        }
    } catch {
        Write-Log "watch-error: $($_.Exception.Message)"
    }
})

# ---------- 首次欢迎 ----------
$script:WelcomeTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:WelcomeTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
$script:WelcomeTimer.Add_Tick({
    $script:WelcomeTimer.Stop()
    Show-Bubble '你好呀，我是鲸鱼娘 🐳 DeepSeek 干活时我会转圈圈，干完给你欢呼～'
})

# ---------- 位置与初始化 ----------
$script:Window.Add_Loaded({
    $src = [System.Windows.PresentationSource]::FromVisual($script:Window)
    if ($src) { $script:DPI = $src.CompositionTarget.TransformToDevice.M11 }
    if ($script:DPI -le 0) { $script:DPI = 1 }

    $cfg = $script:Cfg

    if ($cfg.ContainsKey('skin')) { Apply-Skin $cfg['skin'] } else { Apply-Skin 'whalegirl' }
    foreach ($k in $script:SizeMenuItems.Keys) { $script:SizeMenuItems[$k].IsChecked = ($k -eq $script:SizeKey) }
    if ($cfg['follow'] -eq '1') { $script:FollowMouse = $true; $miFollow.IsChecked = $true }
    if ($cfg['patrol'] -eq '1') { $script:PatrolMode = $true; $miPatrol.IsChecked = $true }
    if ($cfg['topmost'] -eq '0') { $script:Window.Topmost = $false; $miTop.IsChecked = $false }

    # 默认位置：鼠标所在屏幕的右下角；钳制到全部显示器的并集内
    $sb = Get-ScreenBounds
    $cs = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
    $left = $cs.Bounds.Right / $script:DPI - $script:Window.Width - 15
    $top = $cs.Bounds.Bottom / $script:DPI - $script:Window.Height - 20
    if ($cfg.ContainsKey('left')) { $left = [double]$cfg['left'] }
    if ($cfg.ContainsKey('top')) { $top = [double]$cfg['top'] }
    $minL = $sb.X / $script:DPI
    $minT = $sb.Y / $script:DPI
    $maxL = ($sb.Right - $script:Window.Width) / $script:DPI
    $maxT = ($sb.Bottom - $script:Window.Height) / $script:DPI
    $script:Window.Left = [Math]::Max($minL, [Math]::Min($left, $maxL))
    $script:Window.Top = [Math]::Max($minT, [Math]::Min($top, $maxT))

    Write-Log "start ps=$($PSVersionTable.PSVersion) dpi=$([Math]::Round($script:DPI,2)) skin=$($script:SkinId) size=$($script:SizeKey) pos=$([int]$script:Window.Left),$([int]$script:Window.Top)"

    $script:MainTimer.Start()
    $script:IdleTimer.Start()
    $script:WatchTimer.Start()
    $script:WelcomeTimer.Start()
    $script:IdleActionTimer.Start()
    if ($script:PatrolMode) { Start-Wander -Long }
})

$script:Window.Add_Closed({
    Write-Log 'closed'
    $script:MainTimer.Stop()
    $script:IdleTimer.Stop()
    $script:IdleActionTimer.Stop()
    $script:WatchTimer.Stop()
    $script:CelebrateTimer.Stop()
    $script:BubbleHide.Stop()
    try { if ($script:WatcherPid) { Stop-Process -Id $script:WatcherPid -Force -ErrorAction SilentlyContinue } } catch {}
    try { Save-Cfg } catch {}
    try { $script:Mutex.ReleaseMutex() } catch {}
    $script:Mutex.Dispose()
})

# ---------- 测试模式 ----------
if ($TestSeconds -gt 0) {
    $testTimer = New-Object System.Windows.Threading.DispatcherTimer
    $testTimer.Interval = [TimeSpan]::FromSeconds($TestSeconds)
    $testTimer.Add_Tick({ $script:Window.Close() })
    $testTimer.Start()
}

$script:Window.ShowDialog() | Out-Null
