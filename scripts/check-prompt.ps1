# beforeSubmitPrompt hook (Windows): scan prompt via Paradigm Networks API
# before submitting. Returns {continue: true/false, user_message: "..."}.
# Mirrors scripts/check-prompt.sh -- see that file's comments for the
# reasoning behind which failures honor PROMPT_FAILURE_MODE and which
# (not-configured) always allow unconditionally.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "lib\common.ps1")
. (Join-Path $ScriptDir "pn_config.ps1")

$ScanUrlOverride = $env:PARADIGM_NETWORKS_SCAN_URL_OVERRIDE
# 40s (not 20s, matching the bash side): observed directly that
# establishing the HTTPS connection to the scan API from a real Windows
# target can itself take ~20-25s (likely a slow/blocked certificate
# revocation check), before any actual server-side work even starts --
# a stopgap while that root cause is investigated separately.
$TimeoutSeconds = 40
if ($env:PARADIGM_NETWORKS_TIMEOUT) {
  $parsedTimeout = 0
  if ([int]::TryParse($env:PARADIGM_NETWORKS_TIMEOUT, [ref]$parsedTimeout)) {
    $TimeoutSeconds = $parsedTimeout
  }
}
$DebugLogPath = Join-Path $HOME ".paradigm-scanner\check-prompt.log"

# codedefense/scan is retired; this now calls the Anthropic-compatible
# /v1/messages endpoint on the same backend, which requires a model.
# Resolve-PnModel (pn_config.ps1) is the shared precedence chain (env var
# override > saved preference > hardcoded default) -- see its own
# comment for the full rationale. The hardcoded default is a cheap/fast
# tier, chosen because testing showed the block/allow verdict is
# identical across models and max_tokens values -- the platform's guard
# fires before the requested model ever runs, so model choice only
# affects cost/latency on the (always-discarded) allow-path reply, not
# detection accuracy.
$Model = (Resolve-PnModel).Model
# 150 comfortably covers the block banner + reason sentence; confirmed via
# live testing that the banner is injected by the guard without ever being
# subject to max_tokens (output_tokens is 0 even for the full banner), so
# this only trades off cost/latency on the allow path, not truncation risk.
$MaxTokens = 150

$rawMode = $env:PARADIGM_NETWORKS_PROMPT_FAILURE_MODE
if (-not $rawMode) { $rawMode = "allow" }
$rawMode = $rawMode.ToLowerInvariant()
$PromptFailureMode = if ($rawMode -eq "block" -or $rawMode -eq "closed") { "closed" } else { "open" }

Write-DebugLog -Message "===== check-prompt.ps1 invoked ===== HOME=$HOME | USERPROFILE=$env:USERPROFILE | USERNAME=$env:USERNAME | CredPath=$($Script:PnCredPath) | CredFileExists=$(Test-Path $Script:PnCredPath)" -LogPath $DebugLogPath

try {
  $payload = Get-StdinText
  Write-DebugLog -Message "Read stdin | length=$($payload.Length)" -LogPath $DebugLogPath

  $parsedPayload = $null
  try {
    $parsedPayload = $payload | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Write-DebugLog -Message "Payload failed to parse as JSON | error=$($_.Exception.Message) | raw(first 300 chars)=$($payload.Substring(0, [Math]::Min(300, $payload.Length)))" -LogPath $DebugLogPath
    # Deliberately always allow here, unlike the $PromptFailureMode-driven
    # branches below: a malformed payload usually signals a Cursor
    # integration/encoding quirk, not an unreachable scanner. Routing it
    # through $PromptFailureMode would mean an affected machine gets every
    # single prompt blocked persistently, which is worse than a transient
    # scanner outage -- and here the blast radius is the whole product, not
    # just file writes (see check-write.ps1's identical handling of this
    # same situation for the write side).
    Write-JsonAllow -Message "Received invalid input. Allowing prompt -- it was not scanned."
    return
  }

  $prompt = [string](Get-JsonProperty -InputObject $parsedPayload -Name "prompt" -Default "")

  Write-DebugLog -Message "Resolving config (may refresh an expiring token)..." -LogPath $DebugLogPath
  $config = Resolve-PnConfig
  Write-DebugLog -Message "Config resolved | configured=$($null -ne $config)" -LogPath $DebugLogPath
  if ($null -eq $config) {
    Write-JsonAllow -Message "Paradigm Networks is not configured (no login found). Allowing prompt -- run the paradigmnetworks-login skill to authenticate Paradigm Networks. Don't have one yet? Sign up at https://signup.claude-demo.paradigmnetworks.ai/signup."
    return
  }

  $scanUrl = $ScanUrlOverride
  if (-not $scanUrl) {
    $scanUrl = "$($config.BaseUrl.TrimEnd('/'))/v1/messages"
  }

  Write-DebugLog -Message "Scanning prompt | base_url=$($config.BaseUrl) | scan_url=$scanUrl | model=$Model | prompt_len=$($prompt.Length) | timeout=${TimeoutSeconds}s" -LogPath $DebugLogPath

  $callStart = Get-Date
  Write-DebugLog -Message "POST starting -> $scanUrl" -LogPath $DebugLogPath
  $result = Invoke-MessagesHttpPost -Url $scanUrl -TextData $prompt -Model $Model -MaxTokens $MaxTokens -AuthToken $config.AccessToken -TimeoutSec $TimeoutSeconds
  $elapsedMs = [int]((Get-Date) - $callStart).TotalMilliseconds

  $bodyPreview = ""
  if ($result.Body) {
    $bodyPreview = $result.Body.Substring(0, [Math]::Min(500, $result.Body.Length))
  }
  Write-DebugLog -Message "POST returned after ${elapsedMs}ms | TimedOut=$($result.TimedOut) | ConnectionFailed=$($result.ConnectionFailed) | StatusCode=$($result.StatusCode) | body(first 500 chars)=$bodyPreview" -LogPath $DebugLogPath

  if ($result.TimedOut) {
    Write-DebugLog -Message "API timeout | after ${TimeoutSeconds}s | url=$scanUrl" -LogPath $DebugLogPath
    if ($PromptFailureMode -eq "closed") {
      Write-JsonDeny -Message "The scanning service timed out (${TimeoutSeconds}s). Prompt blocked."
    } else {
      Write-JsonAllow -Message "The scanning service timed out (${TimeoutSeconds}s). Allowing prompt."
    }
    return
  }
  if ($result.ConnectionFailed) {
    Write-DebugLog -Message "API unreachable | url=$scanUrl" -LogPath $DebugLogPath
    if ($PromptFailureMode -eq "closed") {
      Write-JsonDeny -Message "The scanning service is unreachable. Prompt blocked."
    } else {
      Write-JsonAllow -Message "The scanning service is unreachable. Allowing prompt."
    }
    return
  }

  if ($result.StatusCode -lt 200 -or $result.StatusCode -ge 300) {
    Write-DebugLog -Message "API HTTP error | status=$($result.StatusCode) | url=$scanUrl" -LogPath $DebugLogPath
    if ($PromptFailureMode -eq "closed") {
      Write-JsonDeny -Message "The scanning service returned an error (HTTP $($result.StatusCode)). Prompt blocked."
    } else {
      Write-JsonAllow -Message "The scanning service returned an error (HTTP $($result.StatusCode)). Allowing prompt."
    }
    return
  }

  $responseObject = $null
  try {
    $responseObject = $result.Body | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Write-DebugLog -Message "API invalid JSON response | url=$scanUrl" -LogPath $DebugLogPath
    if ($PromptFailureMode -eq "closed") {
      Write-JsonDeny -Message "The scanning service returned an invalid response. Prompt blocked."
    } else {
      Write-JsonAllow -Message "The scanning service returned an invalid response. Allowing prompt."
    }
    return
  }

  # ConvertFrom-PnMessagesResponse (lib/common.ps1) classifies this
  # response -- see that function's (and its bash sibling
  # pn_parse_messages_response's) comment for the full detection-rule
  # rationale.
  $parsedVerdict = ConvertFrom-PnMessagesResponse -ResponseBody $result.Body
  $action = $parsedVerdict.Action

  Write-DebugLog -Message "API response received | action=$action" -LogPath $DebugLogPath

  switch ($action) {
    "anomaly" {
      # Zero usage without the block banner -- an unrecognized response
      # shape, not a confirmed verdict either way. Same posture as an
      # invalid-JSON or non-2xx response above: don't guess allow or block.
      Write-DebugLog -Message "API response shape unexpected (zero usage, no block banner) | url=$scanUrl" -LogPath $DebugLogPath
      $anomalyStreak = Add-PnScanAnomaly
      $anomalyPrefix = ""
      if ($anomalyStreak -ge $Script:PnAnomalyWarningThreshold) {
        $anomalyPrefix = "⚠️ Security scanning has failed $anomalyStreak times in a row and may not be protecting you right now. Contact your administrator. "
      }
      if ($PromptFailureMode -eq "closed") {
        Write-JsonDeny -Message "${anomalyPrefix}The scanning service returned an unexpected response. Prompt blocked."
      } else {
        Write-JsonAllow -Message "${anomalyPrefix}The scanning service returned an unexpected response. Allowing prompt."
      }
    }
    "block" {
      Reset-PnScanAnomaly
      # Mirrors scripts/check-prompt.sh's block-message formatting
      # exactly -- see that file's comments for the full rationale.
      # Markdown formatting confirmed rendering correctly in Cursor's UI,
      # with one known exception from testing on a real Windows target:
      # one specific Cursor UI surface ("Submission blocked by hook")
      # silently drops **bold** weight (the markdown gets stripped, but
      # no bold is applied), while `inline code`, `### heading`, and
      # `> blockquote` all render correctly there.
      #
      # $parsedVerdict.Message is already the extracted reason
      # (ConvertFrom-PnMessagesResponse applies the same "security
      # concerns: X" pattern before returning it) -- no second extraction
      # pass needed here.
      $reason = $parsedVerdict.Message

      # Preview of the actual prompt that got flagged, capped at 60 words
      # so a long prompt doesn't blow up the message. Collapsed to a
      # single line first: markdown's ">" blockquote syntax only quotes
      # the line it's on, so a multi-line prompt would otherwise break out
      # of the quote after the first line.
      $flaggedPreview = ($prompt -replace '\s+', ' ').Trim()
      # @(...) matters even though Where-Object already returns a
      # collection: a single-word prompt would otherwise reduce to a bare
      # string crossing this pipeline, and .Count would throw the same way
      # it did once already this session for a single-item collection.
      $words = @($flaggedPreview -split ' ' | Where-Object { $_ -ne '' })
      $wasTruncated = $words.Count -gt 60
      $flaggedPreview = ($words | Select-Object -First 60) -join ' '
      if ($wasTruncated) {
        $flaggedPreview = "$flaggedPreview..."
      }

      # Built via single-quoted (fully literal) fragments concatenated in,
      # not backtick-escaped inside a double-quoted string: backtick is
      # PowerShell's own escape character, so embedding a literal backtick
      # directly in a double-quoted string needs doubling it up, which is
      # easy to get wrong -- concatenating literal single-quoted pieces
      # sidesteps that entirely.
      $concernLine = '**Concern** `' + $reason + '`'
      $quotedContent = '> ' + $flaggedPreview

      # Built from its Unicode code points, not embedded as a literal
      # character in this source file: a literal multi-byte emoji here
      # depends on the file being read back with the exact encoding it was
      # saved with, which is exactly the kind of ambiguity that produced
      # mojibake ("dY>...") on a real Windows target even after forcing
      # [Console]::OutputEncoding to UTF-8 in common.ps1. The shield emoji
      # is two code points -- U+1F6E1 SHIELD, U+FE0F VARIATION SELECTOR-16
      # (selects the emoji-style presentation) -- constructing both from
      # their code points sidesteps source-file encoding entirely.
      $shieldEmoji = [char]::ConvertFromUtf32(0x1F6E1) + [char]::ConvertFromUtf32(0xFE0F)
      $brandedMessage = "### $shieldEmoji Request blocked by Paradigm Networks`n`n" +
        "This message wasn't sent to the model. Your organization's proxy inspects`n" +
        "outbound requests and held this one for review.`n`n" +
        "$concernLine`n`n" +
        "**Flagged content**`n`n" +
        "$quotedContent"
      Write-JsonDeny -Message $brandedMessage
    }
    default {
      # "allow" is the only other action ConvertFrom-PnMessagesResponse
      # produces -- there is no "warn" state on this endpoint (see that
      # function's comment); the model's actual reply is discarded either
      # way, only the verdict matters.
      Reset-PnScanAnomaly
      Write-JsonAllow
    }
  }
} catch {
  # Anything unexpected -- fail open, same posture as an unreachable API.
  Write-DebugLog -Message "UNEXPECTED ERROR | $($_.Exception.GetType().FullName): $($_.Exception.Message)" -LogPath $DebugLogPath
  Write-JsonAllow -Message "The scanning service is unreachable. Allowing prompt."
}
