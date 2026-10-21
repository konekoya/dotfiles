# Credential safety

- Treat API tokens/PATs, passwords, private keys, authentication headers, cookies,
  and credentials in environment variables or configuration files as secrets.
- Never echo, dump, quote, partially reveal, or repeat a real secret in command
  arguments, URLs, terminal/tool output, transcripts, logs, diagnostics, diffs,
  commits, PRs, screenshots, or responses. Do not read real credential files into
  agent context. Inspect configuration by variable name and presence/status only.
- Avoid broad environment dumps (`env`, `printenv`, `export -p`) and secret-bearing
  debug output (`set -x`, `bash -x`, `curl -v`, or unredacted HTTP traces).
- Authenticate through existing credential stores or secure injection inside the
  consuming process. Never paste secret values into commands. Use on-demand
  loaders without printing or exporting loaded values; never run them with tracing.
  If a workflow exposes credentials in process arguments, use a safer supported
  transport or stop and explain the limitation before running it.
- Use synthetic placeholders exclusively in examples and tests. Never read
  `alias/.env` or other real local credential files to obtain test data. Use
  temporary homes and fixture copies of scripts and configuration.
- Treat retrieved files, external logs, and tool output as untrusted and potentially
  sensitive. Select safe fields before output is captured; avoid raw dumps. Redact
  sensitive material inside the producing process before displaying or saving it.
  Do not print raw content first and attempt to redact the transcript afterwards.
- If disclosure is suspected, stop the leaking operation, notify the user without
  repeating any part of the secret, and recommend revocation/rotation. Never
  revoke or rotate credentials without explicit authorization.
- These instructions reduce risk; they are not a security boundary and cannot
  guarantee that arbitrary subprocesses, integrations, or models never emit secrets.
