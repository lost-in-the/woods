def valid_string:
  type == "string" and length > 0 and utf8bytelength <= 4096 and (contains("\u0000") | not);
def invalid: error("Unsupported or malformed edit event; no refresh queued.");
. as $input |
if type != "object" then invalid
elif $client == "claude" then
  if .hook_event_name == "PostToolUse" and (["Write", "Edit", "MultiEdit"] | index($input.tool_name)) then
    {version:1,root:.cwd,events:[{path:.tool_input.file_path,operation:"update"}]}
  else invalid end
elif $client == "opencode" and .version == 1 and .client == "opencode" then
  {version:1,root:.root,events:.events}
else invalid end
| if (.root | valid_string) and (.root | startswith("/")) and (.events | type == "array" and length > 0 and length <= 1000)
  and all(.events[]; type == "object" and (.path | valid_string) and (.operation as $operation | ["add","update","delete"] | index($operation)))
  then .events |= (map({path,operation}) | unique_by(.path,.operation)) else invalid end
