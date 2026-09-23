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
# 240s, matching the bash side. Deliberately kept long even though
# beforeSubmitPrompt runs with failClosed: true -- a slow/dead backend will
# now freeze the IDE for up to 240s before denying (worse than the 25s a
# fail-fast timeout would give), but this restores headroom for real scan
# latency. See CHANGELOG.md for the full history/tradeoff.
$TimeoutSeconds = 240
# Identifies this plugin to the backend's vendor-classification engine (see
# Invoke-MessagesHttpPost's comment in lib/common.ps1). Deliberately NOT
# named $PnClientId -- pn_config.ps1 already sets $Script:PnClientId to the
# unrelated OAuth value "cursor-plugin", and dot-sourcing it into this
# script's scope means reusing that name here would silently overwrite it.
$PnPluginClientId = "cursor"
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
# affects cost/latency on the allow-path reply, not detection accuracy.
$Model = (Resolve-PnModel).Model
# The block banner itself is never subject to max_tokens (confirmed via
# live testing: output_tokens is 0 even for the full banner, since the
# platform's guard injects it before the requested model runs at all), so
# this budget only governs the allow-path reply's length. Raised from an
# earlier 150 (which comfortably covered the banner but wasn't meant to
# cover anything else, back when that reply was discarded) now that the
# reply is surfaced to the user as user_message -- 150 would truncate most
# real answers (a plain "write me hello.py" reply alone ran ~224 output
# tokens in testing).
$MaxTokens = 4096

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

  # session_id/conversation_id are the same value in practice (confirmed
  # directly against real Cursor hook payloads) -- forwarded to the
  # backend as-is so it can correlate this scan with others in the same
  # conversation. Deliberately just this one opaque id, never
  # user_email/workspace_roots/etc. which sit right next to it in the
  # same hook payload.
  $sessionId = [string](Get-JsonProperty -InputObject $parsedPayload -Name "session_id" -Default "")
  if (-not $sessionId) {
    $sessionId = [string](Get-JsonProperty -InputObject $parsedPayload -Name "conversation_id" -Default "")
  }

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
  $result = Invoke-MessagesHttpPost -Url $scanUrl -TextData $prompt -Model $Model -MaxTokens $MaxTokens -AuthToken $config.AccessToken -TimeoutSec $TimeoutSeconds -SessionId $sessionId -ClientId $PnPluginClientId
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

  # Prefer the backend's Anthropic-shaped human message when branding a
  # non-2xx refuse below. Mirrors scripts/check-prompt.sh.
  $apiErrorDetail = ""
  $apiErrorDetailSection = ""
  if ($result.StatusCode -lt 200 -or $result.StatusCode -ge 300) {
    try {
      $errObj = $result.Body | ConvertFrom-Json -ErrorAction Stop
      if ($errObj.error -and $errObj.error.message) {
        $apiErrorDetail = [string]$errObj.error.message
      } elseif ($errObj.message) {
        $apiErrorDetail = [string]$errObj.message
      }
    } catch {
      $apiErrorDetail = ""
    }
    if ($apiErrorDetail) {
      $apiErrorDetailSection = @"

**Details**

$apiErrorDetail
"@
    }
  }
  $consoleUrl = $config.BaseUrl.TrimEnd('/')
  # See the shield-emoji comment on the 403 branch below for why this is
  # built via ConvertFromUtf32/[char] escapes rather than a literal.
  $shield = "$([System.Char]::ConvertFromUtf32(0x1F6E1))$([char]0xFE0F)"

  # Deterministic refuse statuses (always deny). 403 stays the setup copy
  # on purpose -- see check-prompt.sh for the full rationale.
  switch ($result.StatusCode) {
    400 {
      Write-DebugLog -Message "API HTTP 400 | url=$scanUrl" -LogPath $DebugLogPath
      Write-JsonDeny -Message "### $shield Request couldn't be processed

Your prompt wasn't sent. Paradigm Networks couldn't accept this request.
$apiErrorDetailSection
Please try again. If this keeps happening, reach out to customer.support@paradigmnetworks.ai."
      return
    }
    401 {
      Write-DebugLog -Message "API HTTP 401 | url=$scanUrl" -LogPath $DebugLogPath
      Write-JsonDeny -Message "### $shield Sign in required

Your prompt wasn't sent. Your Paradigm Networks session isn't valid anymore (expired or missing credentials).

Run the ``paradigmnetworks-login`` skill to sign in again, then retry. Console:
[$consoleUrl]($consoleUrl)

If you need help, reach out to customer.support@paradigmnetworks.ai."
      return
    }
    402 {
      Write-DebugLog -Message "API HTTP 402 | url=$scanUrl" -LogPath $DebugLogPath
      Write-JsonDeny -Message "### $shield Budget limit reached

Your prompt wasn't sent. Your organization's Paradigm Networks budget for this period is used up.
$apiErrorDetailSection
Please contact your administrator, or check your plan in the Paradigm Networks console:
[$consoleUrl]($consoleUrl)

If you need help, reach out to customer.support@paradigmnetworks.ai."
      return
    }
    403 {
      Write-DebugLog -Message "API HTTP 403 | url=$scanUrl" -LogPath $DebugLogPath
      # Emoji built via ConvertFromUtf32/[char] escapes, not a literal
      # character, so this file stays pure ASCII -- Windows PowerShell 5.1
      # (unlike PS7+/bash) doesn't reliably assume UTF-8 for a .ps1 with no
      # byte-order mark, and a real UTF-8 multi-byte character here corrupts
      # the parser's token stream for the rest of the file (confirmed
      # directly: an em dash elsewhere in this codebase caused "missing
      # string terminator"/"missing closing brace" errors dozens of lines
      # away). Pure-ASCII source sidesteps the whole class of bug regardless
      # of what encoding any future edit saves the file with.
      Write-JsonDeny -Message "### $shield Complete Your Paradigm Networks Setup

You're logged in successfully, but a few setup steps are still pending before you can start sending prompts.

Please visit the following link to finish your configuration, and then try again:
[$consoleUrl]($consoleUrl)

If you run into any issues during setup, feel free to reach out to customer.support@paradigmnetworks.ai for assistance."
      return
    }
    404 {
      Write-DebugLog -Message "API HTTP 404 | url=$scanUrl" -LogPath $DebugLogPath
      Write-JsonDeny -Message "### $shield Model not available

Your prompt wasn't sent. The model used for this scan isn't available for your organization.
$apiErrorDetailSection
Ask an administrator to enable the model under Policy -> Language Models, or pick a different model. Console:
[$consoleUrl]($consoleUrl)

If you need help, reach out to customer.support@paradigmnetworks.ai."
      return
    }
    413 {
      Write-DebugLog -Message "API HTTP 413 | url=$scanUrl" -LogPath $DebugLogPath
      Write-JsonDeny -Message "### $shield Prompt too large

Your prompt wasn't sent. The content is larger than Paradigm Networks can accept for a scan.
$apiErrorDetailSection
Try shortening the prompt, then send it again. If you need help, reach out to customer.support@paradigmnetworks.ai."
      return
    }
    429 {
      Write-DebugLog -Message "API HTTP 429 | url=$scanUrl" -LogPath $DebugLogPath
      Write-JsonDeny -Message "### $shield Rate limit reached

Your prompt wasn't sent. A temporary rate limit is in effect for your account or organization.
$apiErrorDetailSection
Wait a moment and try again. If this continues, contact your administrator or customer.support@paradigmnetworks.ai."
      return
    }
    { $_ -eq 500 -or $_ -eq 502 } {
      Write-DebugLog -Message "API HTTP $($result.StatusCode) | url=$scanUrl" -LogPath $DebugLogPath
      if ($PromptFailureMode -eq "closed") {
        Write-JsonDeny -Message "### $shield Service temporarily unavailable

Your prompt wasn't sent. Paradigm Networks couldn't complete the scan right now (HTTP $($result.StatusCode)).
$apiErrorDetailSection
Please try again shortly. If this keeps happening, reach out to customer.support@paradigmnetworks.ai."
      } else {
        Write-JsonAllow -Message "### $shield Service temporarily unavailable

Paradigm Networks couldn't complete the scan right now (HTTP $($result.StatusCode)). Allowing your prompt without a security scan.
$apiErrorDetailSection
If this keeps happening, reach out to customer.support@paradigmnetworks.ai."
      }
      return
    }
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
        # See the shield-emoji comment above for why this is built via
        # [char] escapes rather than a literal character.
        $warningSign = "$([char]0x26A0)$([char]0xFE0F)"
        $anomalyPrefix = "$warningSign Security scanning has failed $anomalyStreak times in a row and may not be protecting you right now. Contact your administrator. "
      }
      # $parsedVerdict.Message is whatever the backend actually returned,
      # in full (may be empty if there was truly no text content at all).
      # Shown directly, the same way a real block's reason is shown
      # directly -- not wrapped in a canned "unexpected response"
      # sentence, which would bury real content (e.g. a not-yet-
      # recognized block-banner variant, confirmed to happen in
      # practice) behind boilerplate. The generic sentence is only a
      # last resort when there's genuinely nothing to show.
      if ($parsedVerdict.Message) {
        if ($PromptFailureMode -eq "closed") {
          Write-JsonDeny -Message "${anomalyPrefix}$($parsedVerdict.Message)"
        } else {
          Write-JsonAllow -Message "${anomalyPrefix}$($parsedVerdict.Message)"
        }
        return
      }
      if ($PromptFailureMode -eq "closed") {
        Write-JsonDeny -Message "${anomalyPrefix}The scanning service returned an unexpected response. Prompt blocked."
      } else {
        Write-JsonAllow -Message "${anomalyPrefix}The scanning service returned an unexpected response. Allowing prompt."
      }
    }
    "block" {
      Set-PnLastSuccessfulScan
      # Mirrors scripts/check-prompt.sh's block-message formatting
      # exactly -- see that file's comments for the full rationale.
      # Markdown formatting confirmed rendering correctly in Cursor's UI,
      # with one known exception from testing on a real Windows target:
      # one specific Cursor UI surface ("Submission blocked by hook")
      # silently drops **bold** weight (the markdown gets stripped, but
      # no bold is applied), while `inline code`, `### heading`, and
      # `> blockquote` all render correctly there.
      #
      # $parsedVerdict.Message is the block banner's own explanation,
      # with only the confirmed-fixed scaffolding stripped
      # (ConvertTo-PnStrippedBlockBanner in lib/common.ps1) -- no second
      # extraction pass needed here. It's already a complete explanation
      # in the backend's own words, and can be either a short phrase-in-
      # a-sentence or a long multi-line structured report, so the
      # "Concern" section below has to handle both shapes.
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
      # A single-line reason reads fine as an inline-code label; a
      # multi-line one (e.g. a structured findings report) does not --
      # markdown inline code spans aren't meant to carry embedded line
      # breaks, so a long reason gets its own section instead.
      if ($reason -match "`n") {
        $concernLine = "**Concern**`n`n$reason"
      } else {
        $concernLine = '**Concern** `' + $reason + '`'
      }
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
      # function's comment). The backend is also a coding assistant, not
      # just a scanner, so its reply ($parsedVerdict.Message, full text on
      # this path) is surfaced as user_message rather than discarded --
      # may be empty if there was no text content to show. Cursor's own
      # hooks docs describe user_message as shown "when blocked"; whether
      # it's actually rendered on an allow too is unconfirmed and being
      # tested live rather than assumed either way.
      Set-PnLastSuccessfulScan
      if ($parsedVerdict.Message) {
        Write-JsonAllow -Message $parsedVerdict.Message
      } else {
        Write-JsonAllow
      }
    }
  }
} catch {
  # Anything unexpected -- fail open, same posture as an unreachable API.
  Write-DebugLog -Message "UNEXPECTED ERROR | $($_.Exception.GetType().FullName): $($_.Exception.Message)" -LogPath $DebugLogPath
  Write-JsonAllow -Message "The scanning service is unreachable. Allowing prompt."
}
