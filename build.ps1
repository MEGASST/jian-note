<#
.SYNOPSIS
    编译 简笺 的启动器（C# -> 简笺.exe）。

.DESCRIPTION
    简笺 由两部分组成：
      - JianNote.ps1        主程序（PowerShell + WPF，无需编译）
      - launcher/*.cs       启动器，编译为 简笺.exe
    本脚本调用 Windows 自带的 C# 编译器重新生成 简笺.exe，
    生成的 exe 必须和 JianNote.ps1 放在同一目录。

.PARAMETER OutputPath
    输出路径，默认是仓库根目录下的 简笺.exe。

.PARAMETER Zip
    额外打包一个可分发的 zip（含 exe、ps1、bat、README）。

.PARAMETER NoBuild
    跳过编译，只做打包（配合 -Zip 使用）。

.EXAMPLE
    pwsh -File .\build.ps1

.EXAMPLE
    pwsh -File .\build.ps1 -Zip
#>
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot '简笺.exe'),
    [switch]$Zip,
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Find-CSharpCompiler {
    $candidates = @(
        (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    throw '找不到 .NET Framework 4 的 C# 编译器 csc.exe。请确认系统已启用 .NET Framework 4.x。'
}

$compiler = Find-CSharpCompiler
$sources = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'launcher') -Filter '*.cs' -File | ForEach-Object { $_.FullName })

if ($sources.Count -eq 0) {
    throw 'launcher 目录下没有找到 .cs 源文件。'
}

if (-not $NoBuild) {
    Write-Host "使用编译器: $compiler"
    Write-Host "源文件    : $($sources.Count) 个"

    $arguments = @(
        '/nologo'
        '/target:winexe'
        '/platform:anycpu'
        '/optimize+'
        '/utf8output'
        "/out:$OutputPath"
        '/reference:System.dll'
        '/reference:System.Windows.Forms.dll'
    ) + $sources

    & $compiler @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "编译失败，退出码 $LASTEXITCODE。"
    }

    $built = Get-Item -LiteralPath $OutputPath
    Write-Host ("编译完成: {0} ({1} 字节)" -f $built.FullName, $built.Length)
    Write-Host "提醒: 简笺.exe 需要与 JianNote.ps1 位于同一目录才能启动。"
}

if ($Zip) {
    # 版本号从 JianNote.ps1 里的 $script:AppVersion 读取，避免两处不一致
    $appVersion = '0.0.0'
    $mainScript = Join-Path $PSScriptRoot 'JianNote.ps1'
    if (Test-Path -LiteralPath $mainScript) {
        $match = [regex]::Match([System.IO.File]::ReadAllText($mainScript), "AppVersion\s*=\s*'([^']+)'")
        if ($match.Success) { $appVersion = $match.Groups[1].Value }
    }

    $distDirectory = Join-Path $PSScriptRoot 'dist'
    New-Item -ItemType Directory -Path $distDirectory -Force | Out-Null
    $zipPath = Join-Path $distDirectory ("jian-note-v{0}.zip" -f $appVersion)
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

    $payload = @(
        (Join-Path $PSScriptRoot '简笺.exe'),
        (Join-Path $PSScriptRoot 'JianNote.ps1'),
        (Join-Path $PSScriptRoot '启动简笺.bat'),
        (Join-Path $PSScriptRoot 'README.md')
    ) | Where-Object { Test-Path -LiteralPath $_ }

    Compress-Archive -LiteralPath $payload -DestinationPath $zipPath -CompressionLevel Optimal
    Write-Host ("打包完成: {0}（{1} 个文件）" -f $zipPath, $payload.Count)
}
