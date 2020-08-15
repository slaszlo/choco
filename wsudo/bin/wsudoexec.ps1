#Requires -Version 5.1

param(
  [Parameter(Mandatory = $true)] [ValidateSet('prepare','run')] [string] $action,
  [string] $title,
  [string] $command,
  [switch] $stayOpen,
  [switch] $detach)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

class Helpers {
  static [bool]IsElevated()
  {
      $currentPrincipal = New-Object Security.Principal.WindowsPrincipal( `
          [Security.Principal.WindowsIdentity]::GetCurrent())
      return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)        
  }
}

class CommandInfo {
  [string]$curDir
  [string]$comSpec
  [string]$commandLine
  [string]$title
  [bool]$detached
  [bool]$stayOpen
  [bool]$wasElevated
}

switch($action) {
  'prepare' { 
    # pack curDir, commandLine etc using JSON/base64 and re-launch itself as admin
    $commandInfo = [CommandInfo]::new()
    $commandInfo.comSpec = $env:ComSpec
    $commandInfo.commandLine = $env:wsudo_commandLine
    $commandInfo.curDir = $env:wsudo_curDir
    $commandInfo.title = $title
    $commandInfo.detached = $detach
    $commandInfo.stayOpen = $stayOpen
    $commandInfo.wasElevated = [Helpers]::IsElevated()

    $commandInfoJson = ConvertTo-Json -Compress $commandInfo
    $commandInfoEncoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($commandInfoJson))
    # get the powershell EXE name
    $powershell = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $startProcessArgs = @{
      PassThru = $true
      FilePath = $powershell
      ArgumentList = @("-ExecutionPolicy Bypass -NoProfile -NoLogo -File $PSCommandPath", '-action run', "-command $commandInfoEncoded")
    }

    if (!$commandInfo.wasElevated) {
      $startProcessArgs.Verb = 'runAs'
    }
    else {
      $startProcessArgs.NoNewWindow = !$detach;
    }

    try {
      $pi = Start-Process @startProcessArgs
    }
    catch {
      exit 1
    }

    if ($detach) {
      # don't wait for the child proces to finish
      if ($pi.HasExited) {
        exit $pi.ExitCode
      }
      else {
        exit 0
      }
    }
    else {
      if (!$commandInfo.wasElevated) {
        Write-Output "Elevated and waiting..."
      }
      $pi.WaitForExit()
      exit $pi.ExitCode
    }
    break
  }
  'run' {
    # unpack curDir, commandLine etc and run the command under CMD
    if (!$command) { 
      throw 'Must provide commandInfo.'
    }

    $commandInfoJson = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($command));
    $commandInfo = [CommandInfo](ConvertFrom-Json $commandInfoJson)

    Set-Location $commandInfo.curDir
    $empty = [String]::IsNullOrWhiteSpace($commandInfo.commandLine)

    if ($commandInfo.wasElevated) 
    {
      if (!$commandInfo.detached) {
        if ($empty) {
          Write-Output "Nothing to execute, exiting."
          exit 1
        }
        else {
          $commandInfo.stayOpen = $false;
        }
      }
    }
    else {
      if ($empty) {
        $commandInfo.stayOpen = $true;
      }
    }

    if ($commandInfo.title -and ($commandInfo.detached -or !$commandInfo.wasElevated)) { 
      $host.ui.RawUI.WindowTitle = $commandInfo.title
    }

    $comSpecOpts = $(if ($commandInfo.stayOpen -or $empty) { '/K' } else { '/C' })
    $startProcessArgs = @{
      PassThru = $true
      NoNewWindow = $true
      WorkingDirectory = $commandInfo.curDir
      FilePath = $commandInfo.comSpec
      ArgumentList = @($comSpecOpts + $commandInfo.commandLine)
    }
    $pi = Start-Process @startProcessArgs
    $pi.WaitForExit()
    exit $pi.ExitCode
  }
  default {
    throw 'Invalid action.'
  }
}
