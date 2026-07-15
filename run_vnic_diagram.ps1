#--- Use PowerShell to run
#--- powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\<$PATH>\run_vnic_diagram.ps1"


#--- Environmental variables
$server    = "Server-9105-22A-7892A51"
$hmcAddr   = "hscroot@192.168.136.105"
$outHtml   = "C:\Users\IvanNG\vnic_tree_Server-9105-22A-7892A51.html"
$scriptSrc = "C:\Users\IvanNG\vnic_tree_html_diagram.sh"
$sshKey    = "C:\Users\IvanNG\.ssh\id_rsa_script_dev"
$sshOpts   = "-i $sshKey -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=30"

function Run-Ssh([string]$extraArgs, [byte[]]$stdinBytes) {
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo.FileName  = "ssh"
    $p.StartInfo.Arguments = "$sshOpts $hmcAddr $extraArgs"
    $p.StartInfo.UseShellExecute        = $false
    $p.StartInfo.RedirectStandardInput  = $true
    $p.StartInfo.RedirectStandardOutput = $true
    $p.StartInfo.RedirectStandardError  = $true
    $p.Start() | Out-Null
    if ($stdinBytes) {
        $p.StandardInput.BaseStream.Write($stdinBytes, 0, $stdinBytes.Length)
    }
    $p.StandardInput.Close()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit(180000)
    return [PSCustomObject]@{ Exit=$p.ExitCode; Out=$stdout; Err=$stderr }
}

# STEP 1: Deploy script to HMC
Write-Host ""
Write-Host "STEP 1 - Deploy script to HMC" -ForegroundColor Cyan
Write-Host "  ssh $hmcAddr  ->  cp /dev/stdin /home/hscroot/vnic_tree_html_diagram.sh"

$scriptBytes = [System.Text.Encoding]::UTF8.GetBytes((Get-Content -Raw $scriptSrc))
$deployArgs  = [string]::Concat('"', "cp /dev/stdin /home/hscroot/vnic_tree_html_diagram.sh", '"')
$r1 = Run-Ssh $deployArgs $scriptBytes

if ($r1.Exit -eq 0) {
    Write-Host "  Result : SUCCESS (exit 0)" -ForegroundColor Green
} else {
    Write-Host "  Result : FAILED  exit=$($r1.Exit)  err=$($r1.Err)" -ForegroundColor Red
    exit 1
}

# STEP 2: Run script and capture HTML
Write-Host ""
Write-Host "STEP 2 - Run script on HMC, capture HTML" -ForegroundColor Cyan
Write-Host "  Managed system : $server"

$nl         = [char]10
$preamble   = "set -- " + $server + $nl
$fullScript = $preamble + (Get-Content -Raw $scriptSrc)
$runBytes   = [System.Text.Encoding]::UTF8.GetBytes($fullScript)
$r2 = Run-Ssh "-T" $runBytes

Write-Host "  HMC log:" -ForegroundColor DarkCyan
$r2.Err -split "`n" | Where-Object { $_.Trim() -ne "" } | ForEach-Object {
    Write-Host "    $_" -ForegroundColor DarkCyan
}

if ($r2.Exit -ne 0 -or $r2.Out.Length -lt 1000) {
    Write-Host "  FAILED exit=$($r2.Exit) output=$($r2.Out.Length) bytes" -ForegroundColor Red
    exit 1
}

# STEP 3: Save HTML
Write-Host ""
Write-Host "STEP 3 - Save HTML to disk" -ForegroundColor Cyan
[System.IO.File]::WriteAllText($outHtml, $r2.Out, [System.Text.Encoding]::UTF8)
$fsize = (Get-Item $outHtml).Length
Write-Host "  File : $outHtml" -ForegroundColor Green
Write-Host "  Size : $fsize bytes" -ForegroundColor Green

# STEP 4: Verify
Write-Host ""
Write-Host "STEP 4 - Verification" -ForegroundColor Cyan
$html        = $r2.Out
$nodeCount   = ([regex]::Matches($html, [regex]::Escape(' id="n') + '[0-9]+')).Count
$toggleCount = ([regex]::Matches($html, 'onclick=.toggle')).Count
$badgeOkCnt  = ([regex]::Matches($html, 'badge ok')).Count
$badgeErrCnt = ([regex]::Matches($html, 'badge err')).Count
$bkCards     = ([regex]::Matches($html, 'bk-card-title')).Count
$capBars     = ([regex]::Matches($html, 'capbar-fill')).Count
Write-Host "  Node IDs     : $nodeCount"
Write-Host "  toggle calls : $toggleCount"
Write-Host "  Badges ok    : $badgeOkCnt"
Write-Host "  Badges err   : $badgeErrCnt"
Write-Host "  Bk cards     : $bkCards"
Write-Host "  Cap bars     : $capBars"
Write-Host ""
Write-Host "Done! To open: Start-Process $outHtml" -ForegroundColor Yellow
