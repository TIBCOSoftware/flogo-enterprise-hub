# Morning Briefing Demo Recorder
# Usage: run this script, do your demo, press Ctrl+C to stop recording
# Output: C:\tmp\morning-briefing-demo.mp4

$ffmpeg = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\" -Recurse -Filter "ffmpeg.exe" |
           Where-Object { $_.DirectoryName -match 'bin' } | Select-Object -First 1).FullName

$output = "C:\tmp\morning-briefing-demo.mp4"

Write-Host ""
Write-Host "  Morning Briefing Demo Recorder" -ForegroundColor Cyan
Write-Host "  ==============================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Steps to follow while recording:" -ForegroundColor Yellow
Write-Host "   1. Open VS Code and show the morning-briefing.flogo flow diagram"
Write-Host "   2. Point out the flow: REST data sources -> agentactivity -> return"
Write-Host "   3. Open a terminal (or this window) and run the trigger command below"
Write-Host "   4. Show the markdown briefing response"
Write-Host "   5. Press Ctrl+C to stop recording"
Write-Host ""
Write-Host "  Trigger command (paste in a second terminal):" -ForegroundColor Green
Write-Host '   python3 -c "import urllib.request; r=urllib.request.urlopen(''http://localhost:9095/api/morning-briefing'',timeout=90); print(r.read().decode())"'
Write-Host ""
Write-Host "  Output: $output" -ForegroundColor Gray
Write-Host ""
Write-Host "  Starting recording in 3 seconds..." -ForegroundColor Red
Start-Sleep 3
Write-Host "  RECORDING..." -ForegroundColor Red

& $ffmpeg `
  -f gdigrab `
  -framerate 30 `
  -i desktop `
  -vf "scale=1680:1050" `
  -c:v libx264 `
  -preset fast `
  -crf 20 `
  -pix_fmt yuv420p `
  $output `
  -y 2>&1

Write-Host ""
Write-Host "  Recording saved to: $output" -ForegroundColor Green
