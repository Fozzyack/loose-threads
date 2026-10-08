; Capture only literal command names, not substitutions or concatenations.
; Whole strings/heredocs intentionally hide their nested captures in the renderer.
[
  "if" "then" "elif" "else" "fi"
  "for" "select" "in" "while" "until" "do" "done"
  "case" "esac" "function"
  "declare" "typeset" "export" "readonly" "local" "unset" "unsetenv"
] @keyword

(comment) @comment
(number) @number
(file_descriptor) @number
[(string) (raw_string) (ansi_c_string)] @string
[(heredoc_start) (heredoc_body) (heredoc_end)] @string
(special_variable_name) @constant

(function_definition name: (word) @function)
(command_name (word) @function)

; Named test operators include -eq, -n, and similar shell tests.
(test_operator) @operator
[
  "=" "+=" "-=" "*=" "/=" "%=" "**=" "<<=" ">>=" "&=" "^=" "|="
  "+" "-" "*" "/" "%" "**" "++" "--" "!" "~" "^"
  "==" "!=" "=~" "<" ">" "<=" ">=" "-a" "-o"
  "&" "|" "|&" "&&" "||" ";" ";;" ";&" ";;&" "," "?" ":"
  "<<" "<<-" ">>" "<<<" "&>" "&>>" "<&" ">&" "<&-" ">&-" ">|"
  "$" "#" "##" "%%" ":=" ":-" ":+" ":?" "//" "/#" "/%" ",," "^^" "@" ".."
] @operator

; Parameter transformation letters are operators only in expansion position.
(expansion operator: ["U" "u" "L" "Q" "E" "P" "A" "K" "a" "k"] @operator)

[
  "(" ")" "((" "))" "[" "]" "[[" "]]" "{" "}"
  "$(" "${" "$((" "$[" "<(" ">(" "`" "$`"
] @bracket
