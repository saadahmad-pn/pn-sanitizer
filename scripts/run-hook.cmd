:; d="$(cd "$(dirname "$0")" && pwd)"; exec bash "$d/$1.sh"
@echo off
rem Polyglot hook dispatcher: one hooks.json entry per event, on every
rem platform. Line 1 above is a no-op label to cmd.exe (label lines are
rem skipped and never echoed, even with ECHO ON) and a real command to
rem /bin/sh: `exec` replaces the shell process outright, so sh never reads
rem past this line into the batch body below -- unlike the old
rem run-powershell.cmd shim (which just exited early), this file's batch
rem body no longer needs to stay sh-parseable, since sh is gone by the time
rem cmd.exe would reach it. Cursor spawns hook commands through a shell
rem (confirmed by that same predecessor shim relying on /bin/sh executing
rem its own first line), so this single command works unmodified on both
rem platforms without Cursor needing any per-platform filtering.
rem
rem Argument contract: the caller passes a single bare hook name (e.g.
rem "check-prompt"), never a path -- %~dp0 resolves this dispatcher's own
rem directory, so there is no caller-supplied path to mangle, and %2..%9
rem (not %*) preserve each argument's own quoting even when the plugin's
rem install path contains a space.
rem
rem Ships executable in git (same as the shim it replaces) so /bin/sh can
rem run it as a script on macOS/Linux.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0%~1.ps1" %2 %3 %4 %5 %6 %7 %8 %9
