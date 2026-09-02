# Pester tests for ConvertFrom-PnMessagesResponse (lib/common.ps1) --
# the security-critical /v1/messages verdict classifier. Mirrors the
# fixture cases already covered on the bash side (pn_parse_messages_
# response, test/test-unit.sh) so the two implementations can't quietly
# drift apart from each other -- see P2-1/P2-3/P3-3 for why that
# matters: this heuristic is the entire block/allow decision, with no
# real structured verdict field from the backend.
#
# Run with: pwsh -NoProfile -Command "Invoke-Pester -Path test/pester -Output Detailed"

BeforeAll {
  $ScriptDir = Split-Path -Parent $PSScriptRoot
  $RepoRoot = Split-Path -Parent $ScriptDir
  . (Join-Path $RepoRoot "scripts\lib\common.ps1")
}

Describe "ConvertFrom-PnMessagesResponse" {
  It "classifies a normal reply (non-zero usage) as allow" {
    $body = '{"content":[{"type":"text","text":"Hello! How can I help?"}],"model":"anthropic/claude-sonnet-4-6","usage":{"input_tokens":870,"output_tokens":46}}'
    $result = ConvertFrom-PnMessagesResponse -ResponseBody $body
    $result.Action | Should -Be "allow"
  }

  It "classifies a REQUEST BLOCKED banner with zero usage as block, and strips the banner scaffolding" {
    $body = '{"content":[{"type":"text","text":"```\n========================================================================\n  REQUEST BLOCKED\n========================================================================\n\n  The submitted content was flagged because it triggered the following security concerns: destructive operation.\n\n========================================================================\n```"}],"model":"bedrock/us.anthropic.claude-sonnet-4-6","usage":{"input_tokens":0,"output_tokens":0}}'
    $result = ConvertFrom-PnMessagesResponse -ResponseBody $body
    $result.Action | Should -Be "block"
    $result.Message | Should -Be "  The submitted content was flagged because it triggered the following security concerns: destructive operation."
  }

  It "classifies a long, structured multi-finding report banner as block, keeping the full report (not a short extracted phrase, not the raw dividers/fence)" {
    # Regression test for a real production bug: the block banner has at
    # least two shapes -- a short phrase-in-a-sentence (above) and this
    # longer structured report (an actual example from real hook logs,
    # trimmed to one finding). The old implementation tried to regex-
    # match "security concerns: X" and, failing to match this shape,
    # fell back to dumping the ENTIRE raw banner -- dividers, code
    # fence, and all -- as the "reason", which the caller then wrapped
    # in its own sentence on top, producing a garbled double message.
    $body = '{"content":[{"type":"text","text":"```\n========================================================================\n  REQUEST BLOCKED\n========================================================================\n\n  The submitted content was flagged because it contains OWASP Top 10 and OWASP ASVS compliance violations.\n\n  OWASP Top 10 Findings (1 issue)\n  ----------------------------------------------------------------------\n\n  [1] [HIGH] Debug Mode Enabled in Production\n      Category : A02:2025 - Security Misconfiguration\n      Snippet  : debug=True\n\n========================================================================\n```"}],"usage":{"input_tokens":0,"output_tokens":0}}'
    $result = ConvertFrom-PnMessagesResponse -ResponseBody $body
    $result.Action | Should -Be "block"
    $result.Message | Should -Match "OWASP Top 10 and OWASP ASVS compliance violations"
    $result.Message | Should -Match "Debug Mode Enabled in Production"
    $result.Message | Should -Not -Match "===="
    $result.Message | Should -Not -Match '```'
    $result.Message | Should -Not -Match "REQUEST BLOCKED"
  }

  It "classifies zero usage WITHOUT a block banner as anomaly, not allow or block" {
    # This is the case the detection rule exists specifically to avoid
    # guessing on -- a plain "banner AND zero usage" check would still
    # correctly reject this (no banner), but a naive implementation that
    # only checked zero usage could wrongly call this a block.
    $body = '{"content":[{"type":"text","text":"An unrecognized response shape, not a real block or a real reply."}],"usage":{"input_tokens":0,"output_tokens":0}}'
    $result = ConvertFrom-PnMessagesResponse -ResponseBody $body
    $result.Action | Should -Be "anomaly"
    $result.Message | Should -Be "An unrecognized response shape, not a real block or a real reply."
  }

  It "collapses newlines/tabs to single spaces in the anomaly preview" {
    $body = '{"content":[{"type":"text","text":"line one\nline two\t\tpadded"}],"usage":{"input_tokens":0,"output_tokens":0}}'
    $result = ConvertFrom-PnMessagesResponse -ResponseBody $body
    $result.Action | Should -Be "anomaly"
    $result.Message | Should -Be "line one line two padded"
  }

  It "truncates a long anomaly preview to 200 chars plus an ellipsis" {
    $longText = "a" * 250
    $body = "{`"content`":[{`"type`":`"text`",`"text`":`"$longText`"}],`"usage`":{`"input_tokens`":0,`"output_tokens`":0}}"
    $result = ConvertFrom-PnMessagesResponse -ResponseBody $body
    $result.Action | Should -Be "anomaly"
    $result.Message | Should -Be (("a" * 200) + "...")
  }

  It "classifies a missing content array as anomaly" {
    $body = '{"usage":{"input_tokens":0,"output_tokens":0}}'
    $result = ConvertFrom-PnMessagesResponse -ResponseBody $body
    $result.Action | Should -Be "anomaly"
  }

  It "classifies missing usage numbers as anomaly" {
    $body = '{"content":[{"type":"text","text":"some reply"}]}'
    $result = ConvertFrom-PnMessagesResponse -ResponseBody $body
    $result.Action | Should -Be "anomaly"
  }

  It "classifies invalid JSON as anomaly" {
    $result = ConvertFrom-PnMessagesResponse -ResponseBody "not json at all"
    $result.Action | Should -Be "anomaly"
  }

  It "finds the text block even when a non-text block (e.g. thinking) comes first" {
    $body = '{"content":[{"type":"thinking","thinking":"internal reasoning, not the answer"},{"type":"text","text":"```\n===\n  REQUEST BLOCKED\n===\n  The submitted content was flagged because it triggered the following security concerns: policy violation.\n===\n```"}],"usage":{"input_tokens":0,"output_tokens":0}}'
    $result = ConvertFrom-PnMessagesResponse -ResponseBody $body
    $result.Action | Should -Be "block"
    # Also confirms a 3-char "===" divider strips the same as a 72-char one.
    $result.Message | Should -Be "  The submitted content was flagged because it triggered the following security concerns: policy violation."
  }

  It "does not treat a real, non-zero-usage reply that happens to mention REQUEST BLOCKED as a block" {
    # Guards the false-positive direction of the detection rule: a real
    # completion (non-zero usage) that merely discusses or quotes the
    # phrase must never be misclassified as an actual block.
    $body = '{"content":[{"type":"text","text":"I noticed your message contains the phrase REQUEST BLOCKED -- did you mean to paste an error log?"}],"usage":{"input_tokens":42,"output_tokens":18}}'
    $result = ConvertFrom-PnMessagesResponse -ResponseBody $body
    $result.Action | Should -Be "allow"
  }
}
