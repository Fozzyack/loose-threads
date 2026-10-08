; No predicates or generic identifier captures: names are classified by syntax.
[
  "and" "as" "assert" "async" "await" "break" "case" "class"
  "continue" "def" "del" "elif" "else" "except" "exec" "finally"
  "for" "from" "global" "if" "import" "in" "is" "lambda"
  "match" "nonlocal" "not" "or" "pass" "print" "raise" "return"
  "try" "type" "while" "with" "yield" "is not" "not in"
] @keyword

[(integer) (float)] @number
; Capture whole strings, including prefixes, escapes and f-string interpolation.
; Captures inside f-strings are fully contained and ignored by the renderer.
(string) @string
(comment) @comment
[(true) (false) (none) (ellipsis)] @constant

(class_definition name: (identifier) @type)
(type (identifier) @type)
(generic_type (identifier) @type)
(member_type (identifier) @type)
(splat_type (identifier) @type)

(function_definition name: (identifier) @function)
(call function: (identifier) @function)
(call function: (attribute attribute: (identifier) @function))
(decorator (identifier) @function)
(decorator (attribute attribute: (identifier) @function))
; Do not also capture every attribute: that would duplicate method captures.
(keyword_argument name: (identifier) @field)

[
  "+" "-" "*" "**" "/" "//" "%" "@" "&" "|" "^" "~" "<<" ">>"
  "=" ":=" "==" "!=" "<" "<=" ">" ">=" "<>" "->"
  "+=" "-=" "*=" "**=" "/=" "//=" "%=" "@=" "&=" "|=" "^="
  "<<=" ">>="
] @operator
[(keyword_separator) (positional_separator)] @operator
["(" ")" "[" "]" "{" "}"] @bracket
