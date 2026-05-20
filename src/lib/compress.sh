#!/usr/bin/env bash
# compress.sh — caveman-lite compression of an assistant turn.
# stdin: full assistant text. stdout: 1-3 short bullets (no leading dash), one per line.
#
# Default = rule-based, $0 cost, ~50ms.
# Opt-in via MEMORY_CLAUDE_COMPRESS=haiku + ANTHROPIC_API_KEY.

set -euo pipefail

INPUT="$(cat)"
[[ -z "${INPUT// /}" ]] && exit 0

rule_based() {
  # Strip code fences, html, and inline backtick spans for brevity scoring.
  local stripped
  stripped=$(printf '%s' "$INPUT" \
    | awk 'BEGIN{infence=0} /^```/{infence=!infence; next} !infence{print}' \
    | sed -E 's/<[^>]+>//g' \
    | sed -E 's/`[^`]*`//g')

  # Take the first 1-3 short, informative-looking sentences.
  # Lower min length so short replies still emit at least one bullet.
  printf '%s' "$stripped" \
    | tr '\n' ' ' \
    | sed -E 's/  +/ /g' \
    | awk 'BEGIN{RS="[.!?] "} {
        gsub(/^[[:space:]]+|[[:space:]]+$/,"")
        if (length($0) > 3 && length($0) < 240 && $0 !~ /^(I |Let me |I.ll |Here|Now|Let.s )/) {
          print $0
          n++
          if (n >= 3) exit
        }
      }'
}

haiku_based() {
  command -v curl >/dev/null 2>&1 || { rule_based; return; }
  local body
  body=$(jq -n --arg p "Compress this assistant turn into 1-3 ultra-concise bullets in 'caveman lite' style: imperative, no articles, max 80 chars each. Capture only NEW findings, facts, or decisions another collaborator must know. No code blocks. No preamble. Output bullets only, one per line, no leading dash.

TURN:
$INPUT" '{
    model: "claude-haiku-4-5",
    max_tokens: 150,
    messages: [{role:"user", content:$p}]
  }')

  local resp
  resp=$(curl -sS --max-time 8 https://api.anthropic.com/v1/messages \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$body" 2>/dev/null) || { rule_based; return; }

  printf '%s' "$resp" | jq -r '.content[0].text // empty' \
    | grep -v '^\s*$' \
    | sed -E 's/^[[:space:]]*[-*][[:space:]]*//' \
    | head -3
}

if [[ "${MEMORY_CLAUDE_COMPRESS:-rule}" == "haiku" ]] && [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  out=$(haiku_based)
  if [[ -z "${out// /}" ]]; then rule_based; else printf '%s\n' "$out"; fi
else
  rule_based
fi
