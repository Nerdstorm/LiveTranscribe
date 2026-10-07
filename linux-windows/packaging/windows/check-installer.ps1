# Checks the Windows installer as the Linux packages are checked (packaging/linux/check-packages.sh).
# It installs the app, silently, into a folder of its own, and checks what it put there:
# - the OpenVINO runtime fetch-openvino.sh left in Runtime (by default target/openvino-runtime), in
#   the openvino folder beside the app: every DLL byte for byte, and nothing else, with its
#   licences;
# - the sherpa-onnx DLLs fetch-sherpa-onnx.sh left in SherpaOnnx (by default target/sherpa-onnx),
#   beside the app, where Windows looks first (System32 may have an older ONNX Runtime), with their
#   licences in licenses\sherpa-onnx;
# - the parts of Microsoft's C++ runtime that OpenVINO's DLLs load, beside the app, where Windows
#   finds them for DLLs loaded from its openvino folder (Tauri's bundleVCRuntime puts them there);
# - the app's own licence, LICENSE.txt;
# that the app starts as installed: `livetranscribe models` lists the speech models, the default
# among them; and that uninstalling it removes what it installed.
#   packaging/windows/check-installer.ps1 -Installer <setup.exe> [-Runtime F] [-SherpaOnnx F]

param(
    [Parameter(Mandatory = $true)][string]$Installer,
    [string]$Runtime = (Join-Path $PSScriptRoot '../../target/openvino-runtime'),
    [string]$SherpaOnnx = (Join-Path $PSScriptRoot '../../target/sherpa-onnx')
)

$ErrorActionPreference = 'Stop'
$script:failed = $false

# What OpenVINO's DLLs import from the C++ runtime (the rest of it is Windows' own, the UCRT).
$CppRuntime = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')

function Fail([string]$Message) {
    Write-Host "check-installer: $Message"
    $script:failed = $true
}

# Checks that the installed Folder has each file in Fetched (those matching Filter), byte for byte;
# with -Only, that it has no others matching Filter either.
function Compare-Files([string]$Label, [string]$Fetched, [string]$Folder, [string]$Filter, [switch]$Only) {
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
        Fail "$Label`: the installation has no $Folder"
        return
    }
    $wanted = @(Get-ChildItem -LiteralPath $Fetched -File -Filter $Filter)
    if ($wanted.Count -eq 0) {
        Fail "$Label`: $Fetched has no $Filter to compare with"
        return
    }
    $bad = $false
    foreach ($file in $wanted) {
        $installed = Join-Path $Folder $file.Name
        if (-not (Test-Path -LiteralPath $installed -PathType Leaf)) {
            Fail "$Label`: $($file.Name) is missing"
            $bad = $true
        } elseif ((Get-FileHash -LiteralPath $installed).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash) {
            Fail "$Label`: $($file.Name) isn't the file fetched"
            $bad = $true
        }
    }
    if ($Only) {
        foreach ($file in Get-ChildItem -LiteralPath $Folder -File -Filter $Filter) {
            if (-not (Test-Path -LiteralPath (Join-Path $Fetched $file.Name))) {
                Fail "$Label`: $($file.Name) isn't one of those fetched"
                $bad = $true
            }
        }
    }
    if (-not $bad) {
        Write-Host "$Label`: its $($wanted.Count) files are those fetched"
    }
}

$installer = (Resolve-Path -LiteralPath $Installer).Path
$licence = Join-Path $PSScriptRoot '../../../LICENSE'
$deepAdapter = Join-Path $PSScriptRoot '../../../Packages/LiveTranscribeKit/Sources/Cleanup/DeepAdapter'
$work = Join-Path ([IO.Path]::GetTempPath()) "lt-installer-check-$PID"
$folder = Join-Path $work 'Live Transcribe'
$app = Join-Path $folder 'livetranscribe.exe'
$uninstaller = Join-Path $folder 'uninstall.exe'
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    # NSIS: /S installs silently, and /D, last and unquoted, says where.
    $install = Start-Process -FilePath $installer -ArgumentList '/S', "/D=$folder" -Wait -PassThru
    if ($install.ExitCode -ne 0) {
        throw "the installer failed, with exit code $($install.ExitCode)"
    }
    if (-not (Test-Path -LiteralPath $app -PathType Leaf)) {
        throw "the installer put no livetranscribe.exe in $folder"
    }

    Compare-Files 'OpenVINO' $Runtime (Join-Path $folder 'openvino') '*.dll' -Only
    Compare-Files "OpenVINO's licences" (Join-Path $Runtime 'licenses') (Join-Path $folder 'openvino\licenses') '*'
    Compare-Files 'sherpa-onnx' (Join-Path $SherpaOnnx 'lib') $folder '*.dll'
    Compare-Files "sherpa-onnx's licences" (Join-Path $SherpaOnnx 'licenses') (Join-Path $folder 'licenses\sherpa-onnx') '*'
    Compare-Files "Deep adapter's source notice" $deepAdapter (Join-Path $folder 'licenses\deep-adapter') 'NOTICE.md'
    $missing = @($CppRuntime | Where-Object { -not (Test-Path -LiteralPath (Join-Path $folder $_) -PathType Leaf) })
    if ($missing.Count -gt 0) {
        Fail "the C++ runtime OpenVINO needs isn't beside the app: no $($missing -join ', ')"
    } else {
        Write-Host "The C++ runtime OpenVINO needs is beside the app: $($CppRuntime -join ', ')"
    }
    $installedLicence = Join-Path $folder 'LICENSE.txt'
    if (-not (Test-Path -LiteralPath $installedLicence -PathType Leaf) -or
        (Get-FileHash -LiteralPath $installedLicence).Hash -ne (Get-FileHash -LiteralPath $licence).Hash) {
        Fail "LICENSE.txt isn't the app's licence, or is missing"
    }

    # The app is a windowed program: its output goes to the files, and Start-Process waits for it.
    $listed = Join-Path $work 'models.txt'
    $log = Join-Path $work 'models.log'
    $models = Start-Process -FilePath $app -ArgumentList 'models' -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $listed -RedirectStandardError $log
    if ($models.ExitCode -ne 0) {
        Fail "``livetranscribe models`` failed, with exit code $($models.ExitCode):"
        Get-Content -LiteralPath $log | Write-Host
    } elseif (-not (Select-String -LiteralPath $listed -SimpleMatch '(default' -Quiet)) {
        Fail "``livetranscribe models`` didn't list the default model:"
        Get-Content -LiteralPath $listed | Write-Host
    } else {
        $count = @(Get-Content -LiteralPath $listed | Where-Object { $_.Trim() }).Count
        Write-Host "The installed app starts, finds sherpa-onnx's DLLs, and lists $count speech models"
    }

    # _? keeps the uninstaller in place, so waiting for it waits for the uninstall; it is all that
    # should be left.
    $uninstall = Start-Process -FilePath $uninstaller -ArgumentList '/S', "_?=$folder" -Wait -PassThru
    if ($uninstall.ExitCode -ne 0) {
        Fail "the uninstaller failed, with exit code $($uninstall.ExitCode)"
    } else {
        $left = @(Get-ChildItem -LiteralPath $folder -Recurse -Force |
            Where-Object { -not $_.PSIsContainer -and $_.FullName -ne $uninstaller })
        if ($left.Count -gt 0) {
            Fail "uninstalling left $($left.Count) files, such as $($left[0].FullName)"
        } else {
            Write-Host 'Uninstalling removes what was installed'
        }
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failed) {
    exit 1
}
