:; exit 0
@echo off
rem The first line is a POSIX guard, not decoration. To cmd.exe it is a label -
rem skipped, and never echoed, since label lines are not echoed even with ECHO ON
rem - while /bin/sh reads it as a no-op followed by "exit 0". It is needed because
rem Cursor runs EVERY hook entry in a hooks.json array on every platform: it has
rem no per-entry platform filtering (confirmed against Cursor's own hooks
rem documentation), so the Windows entry - this shim - is also spawned on macOS
rem and Linux. Without the guard, /bin/sh there fails on a non-executable .cmd
rem with a permission-denied error, printed for every single hook invocation.
rem The shim ships executable (tracked in git with the executable bit set), so sh
rem runs it as a script and it exits 0 in silence; the sibling .sh hook entry does
rem the real work on those platforms. Keep the rest of this file sh-parseable as
rem well - no parentheses, no backticks, no unbalanced quotes - so a shell that
rem reads ahead past the exit cannot trip over the batch body.
rem
rem Launches Windows PowerShell from an absolute, OS-controlled path.
rem
rem Cursor's hook runner does not reliably expand %SystemRoot% (or the
rem shell-style SystemRoot variants) inside the hook JSON command string
rem itself -- it's left literal there. This .cmd is instead executed by
rem cmd.exe, where %SystemRoot% DOES expand to a non-writable, real location,
rem so the path stays correct even on a non-standard system root. A bare
rem "powershell.exe" would be resolved via the current directory before PATH,
rem letting a planted binary hijack the hook; an absolute path defeats that.
rem
rem The first argument is the .ps1 to run; any remaining arguments are
rem forwarded to it unchanged.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File %*
