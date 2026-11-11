# ngrok-redact.awk — keeps the tenant's ngrok authtoken out of the container log.
#
#   ngrok ... --log stdout 2>&1 | NGROK_AUTHTOKEN=<token> awk -f ngrok-redact.awk
#
# ONE canonical copy: shared/ngrok-redact/ngrok-redact.awk (woow-paas-charts).
# Charts carry byte-identical copies in charts/<chart>/files/ngrok-redact.awk;
# shared/ngrok-redact/tests/run-tests.sh (CI) fails on any drift.
#
# Why (woow_paas_platform #1613): when authentication fails, the ngrok agent
# echoes the authtoken back — `Your authtoken: <token>` in the ERROR block on
# stderr AND inside every logfmt line's err="…" (escaped once; twice in the
# "terminating with error" line). Measured with ngrok 3.39.11: every token that
# does not look like an ngrok authtoken gets ERR_NGROK_105 and is echoed — a
# typo, blanks, punctuation, quotes, non-ASCII — so a mistyped token is exactly
# the one that leaks (tests/fixtures hold the real output, with fake tokens).
#
# Two independent rules; each one alone covers every measured case:
#   1. keyword — everything after `authtoken` + `:` or `=` (any letter case;
#      quotes, backslashes and blanks of logfmt / JSON escaping allowed in
#      between) up to the END OF THE LINE becomes [REDACTED]. It does not
#      depend on what the token looks like, so punctuation or blanks inside a
#      malformed token cannot end the match early.
#   2. literal — every occurrence of the token itself and of its logfmt / JSON
#      escaped forms (\ and " escaped once and twice), anywhere in a line. A
#      plain string search (index), never a regex: the token's punctuation is
#      literal. Only for tokens of 8+ characters — anything shorter is not a
#      credential, and scrubbing it would mangle ordinary text, including the
#      `ERROR:  ERR_NGROK_<n>` line below.
# Unchanged on purpose: ngrok's own `ERROR:  ERR_NGROK_<n>` line — the
# platform reads the failure code from it (woow_paas_platform #1559).
# The token is read from the environment (NGROK_AUTHTOKEN), never from argv
# (argv is visible in /proc to every process of the pod). Lines are flushed
# one by one, so the log stays live.
#
# POSIX awk only: busybox awk (the ngrok alpine image), mawk (CI), gawk.

function woow_escape(s,    out, i, c) {
  out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\\" || c == "\"")
      out = out "\\"
    out = out c
  }
  return out
}

function woow_scrub(s, t,    out, i) {
  out = ""
  while ((i = index(s, t)) > 0) {
    out = out substr(s, 1, i - 1) "[REDACTED]"
    s = substr(s, i + length(t))
  }
  return out s
}

BEGIN {
  tok = ENVIRON["NGROK_AUTHTOKEN"]
  literal = (length(tok) >= 8)
  esc1 = woow_escape(tok)
  esc2 = woow_escape(esc1)
}

{
  line = $0
  if (match(tolower(line), /authtoken["\\ \t]*[:=]/))
    line = substr(line, 1, RSTART + RLENGTH - 1) " [REDACTED]"
  if (literal) {
    # longest form first (equal to the token when it has no \ or ")
    line = woow_scrub(line, esc2)
    line = woow_scrub(line, esc1)
    line = woow_scrub(line, tok)
  }
  print line
  fflush()
}
