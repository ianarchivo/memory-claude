#!/usr/bin/env bash
# tags.sh — cheap keyword-frequency tag extractor.
# Used as a fallback when Haiku-based compression is unavailable, so offline
# summaries still carry tags for filtering. Decoupled from compress.sh.
#
# mc_extract_tags reads text on stdin and emits up to 2 tags, one per line.
# Output is lowercase, stopword-filtered, length-clamped. Empty stdin -> empty.

mc_extract_tags() {
  awk '
    BEGIN {
      # Common English stopwords + Claude/codebase fillers that are never
      # useful as tags. Kept small; tag quality is more about exclusion
      # than inclusion since frequency surfaces the real signal.
      sw_list = "the and of to a in for is that this with on by it be as at " \
                "from an are or not but can will would should i you we they " \
                "have has had do does did been being was were so if then " \
                "than which what when where why how also just only one two " \
                "any all some more most less use used using uses your our " \
                "their there here new like into out up down off over under " \
                "via per such these those need needs need-to want let see " \
                "make made get got go going gets case cases run running " \
                "thing things lot lots way ways yes no ok okay sure great " \
                "good fine first last next prev value values key keys "
      n = split(sw_list, sw_arr, " ")
      for (i = 1; i <= n; i++) sw[sw_arr[i]] = 1
    }
    {
      # Lowercase, then split on any non-alpha. This drops backticks,
      # punctuation, digits, all of it — tokens are pure [a-z]+ runs.
      line = tolower($0)
      gsub(/[^a-z]+/, " ", line)
      m = split(line, toks, " ")
      for (i = 1; i <= m; i++) {
        t = toks[i]
        if (length(t) < 4) continue   # skip very short
        if (length(t) > 24) continue  # skip absurdly long
        if (t in sw) continue
        count[t]++
      }
    }
    END {
      # Sort by frequency descending. awk has no stable sort built-in;
      # emit "<count>\t<token>" then pipe through sort -k1,1nr.
      for (t in count) printf "%d\t%s\n", count[t], t
    }
  ' \
    | sort -k1,1nr -k2,2 \
    | awk '{ print $2 }' \
    | head -n 2
}

# When invoked directly (not sourced), read stdin and run.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  mc_extract_tags
fi
