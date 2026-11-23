# Copied from stocktimal scripts/alarm-line.jq (owner decision D5, 23 Nov 2026); keep the two in step.
# The session start's alarm line, from `gh issue list --label alarm --json title,body,createdAt`:
#   2 alarms: security scan (since 3 days), sanity backup
# Empty when no alarm is open. The short name is the key in the body's marker
# (infra/scripts/utils/workflow-alarm.sh), else the title; an alarm under a day old shows no age.
def short_name:
  ([.body // "" | capture("<!-- workflow-alarm: (?<k>[a-z0-9-]+) -->") | .k | gsub("-"; " ")] | first) // .title;
def age_days: ((now - (.createdAt | fromdateiso8601)) / 86400 | floor);
def entry:
  short_name + (age_days as $d
    | if $d < 1 then "" elif $d == 1 then " (since 1 day)" else " (since \($d) days)" end);
if length == 0 then empty
else "\(length) alarm\(if length == 1 then "" else "s" end): \(sort_by(.createdAt) | map(entry) | join(", "))"
end
