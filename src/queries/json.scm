; Capture whole strings once, distinguishing object keys from string values.
(pair key: (string) @field)
(pair value: (string) @string)
(array (string) @string)
(document (string) @string)

(number) @number
[(true) (false) (null)] @constant
(comment) @comment

[":" ","] @operator
["{" "}" "[" "]"] @bracket
