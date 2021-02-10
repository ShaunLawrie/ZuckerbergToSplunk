#Requires -Version 7
param(
    [string] $MessagesDirectoryPath = "$PSScriptRoot/messages/"
)
$ErrorActionPreference = "Stop"

if(!(Test-Path $MessagesDirectoryPath)) {
    Write-Error "You need to extract the facebook messages folder to $MessagesDirectoryPath"
}

$conversations = Get-ChildItem -Recurse -Path "$MessagesDirectoryPath/inbox" -Filter "*.json"
               | Group-Object -Property { $_.Directory.Name }

Remove-Item -Path "$PSScriptRoot/FlattenedMessages.json" -ErrorAction SilentlyContinue

$filelock = [System.Threading.ReaderWriterLockSlim]::new()
$scriptroot = $PSScriptRoot
$conversations | Foreach-Object -ThrottleLimit 12 -Parallel {
    $conversation = $_
    $filelock = $using:fileLock
    $scriptroot = $using:scriptroot
    Write-Host "Processing $($conversation.Name)"
    $conversation.Group | Foreach-Object -ThrottleLimit 12 -Parallel {
        $output = ""
        $messageArchive = $_
        $messageArchiveContent = Get-Content -Raw -Path $messageArchive.FullName | ConvertFrom-Json
        $epochStart = Get-Date "1970-01-01T00:00:00"
        $scriptroot = $using:scriptroot
        Foreach ($message in $messageArchiveContent.messages) {
            $messageDate = ($epochStart).AddMilliseconds($message.timestamp_ms)
            
            if($message.content) {
                # Bruh facebook corrupted this by exporting as the wrong encoding
                # Treat it as latin then flip it back to utf-8 to correct the emojiii 😑
                $latinBytes = [System.Text.Encoding]::GetEncoding('iso-8859-1').GetBytes($message.content)
                $content = [System.Text.Encoding]::UTF8.GetString($latinBytes)
            } else {
                $content = "No content"
            }

            if($message.photos) {
                $message.type = "Photos"
                if(!$content) {
                    $content = "$($message.sender_name) sent a photo"
                }
            } elseif($message.sticker) {
                $message.type = "Sticker"
                if(!$content) {
                    $content = "$($message.sender_name) sent a sticker"
                }
            } elseif($message.type -eq "Call") {
                $content = $message.call_duration
            } elseif($message.type -eq "Share") {
                $content = $content + " " + $message.share.link
            } elseif($message.type -eq "Subscribe" -or $message.type -eq "Unsubscribe") {
                continue
            }

            $splunkEvent = @{
                Sender = $message.sender_name
                Message = $content
                Type = $message.type
                ChatTitle = $messageArchiveContent.title
            }

            $output += (($splunkEvent | ConvertTo-Json -Depth 10 -Compress) -replace "^{", "{`"Date`":`"$messageDate`",") + "`n"
        }
        $lock = $using:fileLock
        try{
            $lock.EnterWriteLock()
            Add-Content -Path "./FlattenedMessages.json" -Value $output -NoNewline
        }
        catch {
            Write-Warning "Failed to write conversation to file "
        }
        finally{
            if($lock.IsWriteLockHeld){
                $lock.ExitWriteLock()
            }
        }
    }
}