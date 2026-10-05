; Keep captures non-overlapping: no generic identifier or nested escape captures.
[
  "asm" "defer" "errdefer" "test" "error" "const" "var"
  "struct" "union" "enum" "opaque" "fn"
  "async" "await" "suspend" "nosuspend" "resume"
  "and" "or" "orelse" "return" "if" "else" "switch"
  "for" "while" "break" "continue" "usingnamespace" "export"
  "try" "catch" "volatile" "allowzero" "noalias" "addrspace"
  "align" "callconv" "linksection" "pub" "inline" "noinline"
  "extern" "comptime" "packed" "threadlocal"
] @keyword

[(integer) (float)] @number
[(string) (multiline_string) (character)] @string
(comment) @comment
(boolean) @constant
["null" "undefined" "unreachable"] @constant
[(builtin_type) "anyframe"] @type
(builtin_identifier) @builtin

["+" "-" "=" "/" "*"] @operator
["(" ")" "[" "]" "{" "}"] @bracket

(field_expression member: (identifier) @field)
(field_initializer (identifier) @field)
(container_field name: (identifier) @field)

(function_declaration name: (identifier) @function)
(call_expression function: (identifier) @function)
