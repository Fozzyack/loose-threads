; Capture tokens and contextual names, not whole declarations or expressions.
; Strings include their escapes; field names use the shared field token class.
[
  "auto" "break" "case" "const" "constexpr" "continue" "default"
  "do" "else" "enum" "extern" "for" "goto" "if" "inline"
  "register" "restrict" "return" "static" "struct" "switch"
  "thread_local" "typedef" "union" "volatile" "while"
  "_Atomic" "_Generic" "_Nonnull" "_Noreturn" "noreturn"
  "alignas" "_Alignas" "__extension__" "__restrict__"
  "__inline" "__inline__" "__forceinline" "__thread"
  "asm" "__asm" "__asm__" "__volatile__"
  "__attribute" "__attribute__" "__declspec" "__based"
  "__cdecl" "__clrcall" "__stdcall" "__fastcall" "__thiscall"
  "__vectorcall" "_unaligned" "__unaligned"
  "__try" "__except" "__finally" "__leave"
] @keyword

[
  "#include" "#define" "#if" "#ifdef" "#ifndef" "#else"
  "#elif" "#elifdef" "#elifndef" "#endif"
  (preproc_directive)
] @keyword

(number_literal) @number
[(string_literal) (char_literal) (system_lib_string)] @string
(comment) @comment
[(true) (false) (null)] @constant
[(primitive_type) (type_identifier) "signed" "unsigned" "long" "short"] @type

[
  "sizeof" "offsetof" "alignof" "_Alignof" "_alignof"
  "__alignof" "__alignof__" "defined"
] @builtin

(function_declarator declarator: (identifier) @function)
(function_declarator declarator: (parenthesized_declarator (identifier) @function))
(function_declarator declarator: (parenthesized_declarator
  (pointer_declarator declarator: (identifier) @function)))
(function_declarator declarator: (parenthesized_declarator
  (pointer_declarator declarator: (pointer_declarator declarator: (identifier) @function))))
(function_declarator declarator: (parenthesized_declarator
  (pointer_declarator declarator: (array_declarator declarator: (identifier) @function))))

(parameter_declaration declarator: (identifier) @parameter)
(parameter_declaration declarator: (pointer_declarator declarator: (identifier) @parameter))
(parameter_declaration declarator: (pointer_declarator
  declarator: (pointer_declarator declarator: (identifier) @parameter)))
(parameter_declaration declarator: (array_declarator declarator: (identifier) @parameter))
(call_expression function: (identifier) @function)
(field_identifier) @field
(enumerator name: (identifier) @constant)
(preproc_def name: (identifier) @constant)
(preproc_function_def name: (identifier) @function)
(macro_type_specifier name: (identifier) @type)

[
  "+" "-" "*" "/" "%" "=" "==" "!=" "<" ">" "<=" ">="
  "!" "~" "&" "|" "^" "&&" "||" "<<" ">>" "++" "--"
  "+=" "-=" "*=" "/=" "%=" "&=" "|=" "^=" "<<=" ">>="
  "." "->" "?" ":" "..."
] @operator
["(" ")" "[" "]" "{" "}" "[[" "]]"] @bracket
