# This file is part of the Spring engine (GPL v2 or later), see LICENSE.html

[CmdletBinding()]
param(
	[string]$BuildDirectory = "build-mingw",
	[string]$RuntimeDirectory = "build-official-release\extract",
	[string]$OutputName = "spring-dev.exe",
	[ValidateRange(1, 256)]
	[int]$Jobs = [Environment]::ProcessorCount,
	[switch]$Incremental,
	[switch]$SkipStrip,
	[switch]$SkipVersionCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepositoryPath
{
	param(
		[Parameter(Mandatory = $true)]
		[string]$Path
	)

	if ([IO.Path]::IsPathRooted($Path)) {
		return [IO.Path]::GetFullPath($Path)
	}

	return [IO.Path]::GetFullPath((Join-Path $script:RepositoryRoot $Path))
}

function Get-CMakeCacheValue
{
	param(
		[Parameter(Mandatory = $true)]
		[string]$CachePath,
		[Parameter(Mandatory = $true)]
		[string]$Name
	)

	$match = Select-String -LiteralPath $CachePath -Pattern ("^{0}:[^=]+=(.*)$" -f [regex]::Escape($Name)) | Select-Object -First 1
	if ($null -eq $match) {
		return $null
	}

	return $match.Matches[0].Groups[1].Value
}

$RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$buildPath = Resolve-RepositoryPath $BuildDirectory
$runtimePath = Resolve-RepositoryPath $RuntimeDirectory
$cachePath = Join-Path $buildPath "CMakeCache.txt"

if (!(Test-Path -LiteralPath $cachePath -PathType Leaf)) {
	throw "Configured CMake build directory not found: $buildPath. See doc/windows-engine-build.md for the one-time configuration command."
}

$cmakeCommand = Get-Command "cmake" -CommandType Application -ErrorAction Stop | Select-Object -First 1
$cmakeHome = Get-CMakeCacheValue -CachePath $cachePath -Name "CMAKE_HOME_DIRECTORY"
if ($null -ne $cmakeHome -and [IO.Path]::GetFullPath($cmakeHome) -ne $RepositoryRoot) {
	throw "CMake build directory belongs to '$cmakeHome', not '$RepositoryRoot'."
}

$buildArguments = @(
	"--build", $buildPath,
	"--target", "engine-legacy",
	"--parallel", $Jobs
)

if (!$Incremental) {
	# Header dependency data has previously been incomplete in the native
	# MinGW/Ninja setup. A clean target rebuild prevents mixed C++ layouts.
	$buildArguments += "--clean-first"
}

$buildMode = if ($Incremental) { "incremental" } else { "clean" }
Write-Host "Building engine-legacy ($buildMode, $Jobs jobs)..."
Write-Host "  Source:  $RepositoryRoot"
Write-Host "  Build:   $buildPath"

& $cmakeCommand.Source @buildArguments
if ($LASTEXITCODE -ne 0) {
	throw "CMake build failed with exit code $LASTEXITCODE."
}

$enginePath = Join-Path $buildPath "spring.exe"
if (!(Test-Path -LiteralPath $enginePath -PathType Leaf)) {
	throw "Build succeeded but engine executable was not found: $enginePath"
}

New-Item -ItemType Directory -Path $runtimePath -Force | Out-Null
$outputPath = Join-Path $runtimePath $OutputName
$temporaryName = "{0}.{1}.exe" -f [IO.Path]::GetFileNameWithoutExtension($OutputName), [guid]::NewGuid().ToString("N")
$temporaryPath = Join-Path $runtimePath $temporaryName

try {
	if ($SkipStrip) {
		Copy-Item -LiteralPath $enginePath -Destination $temporaryPath
	} else {
		$stripPath = Get-CMakeCacheValue -CachePath $cachePath -Name "CMAKE_STRIP"
		if ([string]::IsNullOrWhiteSpace($stripPath) -or !(Test-Path -LiteralPath $stripPath -PathType Leaf)) {
			$stripCommand = Get-Command "strip" -CommandType Application -ErrorAction Stop | Select-Object -First 1
			$stripPath = $stripCommand.Source
		}

		Write-Host "Stripping debug symbols for a Windows-loadable development executable..."
		& $stripPath "--strip-all" "-o" $temporaryPath $enginePath
		if ($LASTEXITCODE -ne 0) {
			throw "strip failed with exit code $LASTEXITCODE."
		}
	}

	if (!$SkipVersionCheck) {
		Write-Host "Checking that the generated executable can be started..."
		& $temporaryPath "--version"
		if ($LASTEXITCODE -ne 0) {
			throw "Generated executable failed its startup check with exit code $LASTEXITCODE."
		}
	}

	Move-Item -LiteralPath $temporaryPath -Destination $outputPath -Force
} finally {
	if (Test-Path -LiteralPath $temporaryPath) {
		Remove-Item -LiteralPath $temporaryPath -Force
	}
}

$engineInfo = Get-Item -LiteralPath $enginePath
$outputInfo = Get-Item -LiteralPath $outputPath
Write-Host "Build completed successfully."
Write-Host ("  Unstripped: {0} ({1:N1} MiB)" -f $engineInfo.FullName, ($engineInfo.Length / 1MB))
Write-Host ("  Runnable:   {0} ({1:N1} MiB)" -f $outputInfo.FullName, ($outputInfo.Length / 1MB))
