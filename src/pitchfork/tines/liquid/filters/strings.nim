import strutils, base64, xmltree, sequtils, re

import ../../../values

# Compiled once. Nim's `re` is a runtime proc with no cache of its own, so
# a pattern written inline in a filter body is compiled and studied again
# on every call — which for these two filters cost more than the match.
let non_handle_chars = re"[^-\w]"
# strip_html drops these wholesale, contents and all, before it gets to
# loose tags: a <script> body is not text the reader was ever meant to see.
let html_blocks = re"(?s)<script.*?</script>|<!--.*?-->|<style.*?</style>"
let html_tag = re"(?s)<.*?>"

proc opens_entity(s: string, i: int): bool =
  ## True when s[i] == '&' starts a character reference — named ("&amp;")
  ## or numeric ("&#39;"). escape_once leaves those alone, which is what
  ## makes it idempotent over already-escaped markup.
  var j = i + 1
  if j < s.len and s[j] == '#':
    inc j
    let digits_start = j
    while j < s.len and s[j] in Digits:
      inc j
    return j > digits_start and j < s.len and s[j] == ';'
  let alpha_start = j
  while j < s.len and s[j] in Letters:
    inc j
  result = j > alpha_start and j < s.len and s[j] == ';'

proc is_base64(s: string, url_safe: bool): bool =
  ## Reject what Ruby's Base64.strict_decode64 rejects. Nim's decoder is
  ## lenient and happily returns garbage for a non-base64 string, but the
  ## reference implementation raises — `{{ 5 | base64_decode }}` is an
  ## error, not "5".
  if s.len == 0:
    return true
  let alphabet = if url_safe: {'A'..'Z', 'a'..'z', '0'..'9', '-', '_', '+', '/'}
                 else: {'A'..'Z', 'a'..'z', '0'..'9', '+', '/'}
  var padding = 0
  for i, c in s:
    if c == '=':
      inc padding
      # Padding is at most two characters and only ever trails.
      if padding > 2 or i < s.len - 2:
        return false
    elif padding > 0:
      return false
    elif c notin alphabet:
      return false
  # The URL-safe variant is routinely written without its padding.
  if url_safe:
    result = (s.len - padding) mod 4 != 1
  else:
    result = s.len mod 4 == 0


# Appends a string to another string
create_filter:
  proc append(value: VMValue, suffix: VMValue): VMValue =
    let input = to_string(value)
    let suffixStr = to_string(suffix)
    result = VMValue(kind: vmString, stringVal: input & suffixStr)

# Converts a base64-encoded string into a string
create_filter:
  proc base64_decode(value: VMValue): VMValue =
    let input = to_string(value)
    if not input.is_base64(url_safe = false):
      raise newException(ValueError, "base64_decode filter: input is not valid base64")
    result = VMValue(kind: vmString, stringVal: input.decode())

# Converts a string into a base64-encoded string
create_filter:
  proc base64_encode(value: VMValue): VMValue =
    result = VMValue(kind: vmString, stringVal: to_string(value).encode())

# Converts a URL-safe base64-encoded string into a string
create_filter:
  proc base64_url_safe_decode(value: VMValue): VMValue =
    let input = to_string(value)
    if not input.is_base64(url_safe = true):
      raise newException(ValueError,
        "base64_url_safe_decode filter: input is not valid URL-safe base64")
    result = VMValue(kind: vmString, stringVal: input.decode())

# Converts a string into a URL-safe base64-encoded string
create_filter:
  proc base64_url_safe_encode(value: VMValue): VMValue =
    result = VMValue(kind: vmString, stringVal: to_string(value).encode(safe = true))

# Capitalizes the first word in a string and downcases the remaining characters
create_filter:
  proc capitalize(value: VMValue): VMValue =
    if value.kind != vmString:
      return value
    var str = value.stringVal.toLower()
    if str.len > 0:
      str[0] = str[0].toUpperAscii()
    result = VMValue(kind: vmString, stringVal: str)

# Converts a string into a camelized string
create_filter:
  proc camelize(value: VMValue, args: varargs[VMValue]): VMValue =
    if value.kind != vmString:
      return value
    let parts = value.stringVal.split("_")
    let camelized = parts.mapIt(it.capitalizeAscii()).join("")
    result = VMValue(kind: vmString, stringVal: camelized)

# downcase - Converts a string to all lowercase characters
create_filter:
  proc downcase(value: VMValue): VMValue =
    if value.kind != vmString:
      return value
    result = VMValue(kind: vmString, stringVal: value.stringVal.toLower())

# escape - Escapes special characters in HTML
create_filter:
  proc escape(value: VMValue): VMValue =
    let input = to_string(value)
    if input.len == 0:
      return VMValue(kind: vmString, stringVal: "")
    # Custom HTML escape that handles single quotes (xmltree.escape doesn't)
    var escaped = newStringOfCap(input.len + 10)
    for c in input:
      case c
      of '&': escaped.add("&amp;")
      of '<': escaped.add("&lt;")
      of '>': escaped.add("&gt;")
      of '"': escaped.add("&quot;")
      of '\'': escaped.add("&#39;")
      else: escaped.add(c)
    result = VMValue(kind: vmString, stringVal: escaped)

# Converts a string into a URL-friendly format
create_filter:
  proc handleize(value: VMValue, args: varargs[VMValue]): VMValue =
    if value.kind != vmString:
      return value
    var str = value.stringVal.toLower()
    str = strutils.replace(str, " ", "-")
    str = re.replace(str, non_handle_chars, "")
    result = VMValue(kind: vmString, stringVal: str)

# Strips all leading and trailing whitespace from a string
create_filter:
  proc strip(value: VMValue): VMValue =
    if value.kind != vmString:
      return value
    result = VMValue(kind: vmString, stringVal: value.stringVal.strip())

# Returns the first N characters of a string
create_filter:
  proc truncate(value: VMValue, args: varargs[VMValue]): VMValue =
    let input = to_string(value)

    if args.len > 2:
      raise newException(ValueError, "truncate filter takes at most 2 arguments")

    # Handle length argument
    let length = if args.len > 0:
      case args[0].kind
      of vmInt: args[0].intVal.int
      of vmFloat: args[0].floatVal.int
      of vmString:
        try: args[0].stringVal.parseInt()
        except: 50
      of vmNull:
        raise newException(ValueError, "truncate filter: first argument cannot be nil")
        0
      else: 50
    else:
      50

    # Handle ellipsis: undefined (vmNull) → empty string, missing → "..."
    let ellipsis = if args.len > 1:
      if args[1].kind == vmNull: ""
      else: to_string(args[1])
    else:
      "..."

    if input.len <= length:
      result = VMValue(kind: vmString, stringVal: input)
    else:
      let cutLen = max(0, length - ellipsis.len)
      result = VMValue(kind: vmString, stringVal: input[0..<cutLen] & ellipsis)

# Returns the first N words of a string, preserving whole words
create_filter:
  proc truncatewords(value: VMValue, args: varargs[VMValue]): VMValue =
    let input = to_string(value)

    if args.len > 2:
      raise newException(ValueError, "truncatewords filter takes at most 2 arguments")

    # Handle word count argument
    var wordCount = if args.len > 0:
      case args[0].kind
      of vmInt: args[0].intVal.int
      of vmFloat: args[0].floatVal.int
      of vmString:
        try: args[0].stringVal.parseInt()
        except: 15
      of vmNull:
        raise newException(ValueError, "truncatewords filter: first argument cannot be nil")
        0
      else: 15
    else:
      15

    # Minimum word count is 1 in Liquid
    if wordCount < 1:
      wordCount = 1

    # Handle ellipsis: undefined (vmNull) → empty string, missing → "..."
    # Non-string arg → convert to string
    let ellipsis = if args.len > 1:
      if args[1].kind == vmNull: ""
      else: to_string(args[1])
    else:
      "..."

    # Split on whitespace (handles multiple spaces, tabs, newlines)
    let words = input.splitWhitespace()
    if words.len <= wordCount:
      result = VMValue(kind: vmString, stringVal: words.join(" "))
    else:
      result = VMValue(kind: vmString, stringVal: words[0..<wordCount].join(" ") & ellipsis)

# upcase - Converts a string to all uppercase characters
create_filter:
  proc upcase(value: VMValue): VMValue =
    if value.kind != vmString:
      return value
    result = VMValue(kind: vmString, stringVal: value.stringVal.toUpper())

# Prepends a string to another string
create_filter:
  proc prepend(value: VMValue, prefix: VMValue): VMValue =
    let input = to_string(value)
    let prefixStr = to_string(prefix)
    result = VMValue(kind: vmString, stringVal: prefixStr & input)

# Removes a substring from a string
create_filter:
  proc remove(value: VMValue, substring: VMValue): VMValue =
    if value.kind != vmString:
      return value
    let substringStr = to_string(substring)
    result = VMValue(kind: vmString, stringVal: value.stringVal.replace(substringStr, ""))

# Removes the first occurrence of a substring from a string
create_filter:
  proc remove_first(value: VMValue, substring: VMValue): VMValue =
    if value.kind != vmString:
      return value
    let substringStr = to_string(substring)
    let idx = value.stringVal.find(substringStr)
    var resultStr = value.stringVal
    if idx >= 0:
      resultStr = value.stringVal[0..<idx] & value.stringVal[idx + substringStr.len..^1]
    result = VMValue(kind: vmString, stringVal: resultStr)

# Replaces all occurrences of a substring with another string
create_filter:
  proc replace(value: VMValue, args: varargs[VMValue]): VMValue =
    let input = to_string(value)

    if args.len < 1:
      raise newException(ValueError, "replace filter requires at least 1 argument (search string)")
    if args.len > 2:
      raise newException(ValueError, "replace filter takes at most 2 arguments")

    let searchStr = to_string(args[0])
    let replacementStr = if args.len >= 2: to_string(args[1]) else: ""
    if searchStr.len == 0:
      # Empty search string: insert replacement between every character and at boundaries
      var res = newStringOfCap(input.len * (1 + replacementStr.len) + replacementStr.len)
      for i, c in input:
        res.add(replacementStr)
        res.add(c)
      res.add(replacementStr)
      result = VMValue(kind: vmString, stringVal: res)
    else:
      result = VMValue(kind: vmString, stringVal: input.replace(searchStr, replacementStr))

# Replaces the first occurrence of a substring with another string
create_filter:
  proc replace_first(value: VMValue, args: varargs[VMValue]): VMValue =
    # Unlike replace_last, the replacement is optional and defaults to the
    # empty string, so `replace_first: "ll"` deletes rather than raising.
    if args.len < 1:
      raise newException(ValueError, "replace_first filter requires at least 1 argument (search string)")
    if args.len > 2:
      raise newException(ValueError, "replace_first filter takes at most 2 arguments")
    if value.kind != vmString:
      return value
    let searchStr = to_string(args[0])
    let replacementStr = if args.len >= 2: to_string(args[1]) else: ""
    let idx = value.stringVal.find(searchStr)
    var resultStr = value.stringVal
    if idx >= 0:
      resultStr = value.stringVal[0..<idx] & replacementStr & value.stringVal[idx + searchStr.len..^1]
    result = VMValue(kind: vmString, stringVal: resultStr)

# Strips HTML tags from a string
create_filter:
  proc strip_html(value: VMValue): VMValue =
    if value.kind != vmString:
      return value
    # Script, style and comment blocks go first, contents included; what is
    # left of the markup is then reduced to its text by dropping the tags.
    var stripped = re.replace(value.stringVal, html_blocks, "")
    stripped = re.replace(stripped, html_tag, "")
    result = VMValue(kind: vmString, stringVal: stripped)

# Strips newlines from a string
create_filter:
  proc strip_newlines(value: VMValue): VMValue =
    if value.kind != vmString:
      return value
    let stripped = value.stringVal.multiReplace([("\n", ""), ("\r", "")])
    result = VMValue(kind: vmString, stringVal: stripped)

# Converts newlines to HTML breaks
create_filter:
  proc newline_to_br(value: VMValue): VMValue =
    if value.kind != vmString:
      return value
    let input = value.stringVal
    # The <br /> is inserted before the newline, not instead of it: the
    # source line structure survives into the HTML. A CRLF collapses to a
    # single break, and a lone CR is left alone.
    var res = newStringOfCap(input.len + 16)
    var i = 0
    while i < input.len:
      if input[i] == '\r' and i + 1 < input.len and input[i + 1] == '\n':
        res.add("<br />\n")
        inc i, 2
      elif input[i] == '\n':
        res.add("<br />\n")
        inc i
      else:
        res.add(input[i])
        inc i
    result = VMValue(kind: vmString, stringVal: res)

# Removes the last occurrence of a substring from a string
create_filter:
  proc remove_last(value: VMValue, substring: VMValue): VMValue =
    if value.kind != vmString:
      return value
    let substringStr = to_string(substring)
    let idx = value.stringVal.rfind(substringStr)
    var resultStr = value.stringVal
    if idx >= 0:
      resultStr = value.stringVal[0..<idx] & value.stringVal[idx + substringStr.len..^1]
    result = VMValue(kind: vmString, stringVal: resultStr)

# Replaces the last occurrence of a substring with another string  
create_filter:
  proc replace_last(value: VMValue, search: VMValue, replacement: VMValue): VMValue =
    if value.kind != vmString:
      return value
    let searchStr = to_string(search)
    let replacementStr = to_string(replacement)
    let idx = value.stringVal.rfind(searchStr)
    var resultStr = value.stringVal
    if idx >= 0:
      resultStr = value.stringVal[0..<idx] & replacementStr & value.stringVal[idx + searchStr.len..^1]
    result = VMValue(kind: vmString, stringVal: resultStr)

# Removes leading whitespace from a string
create_filter:
  proc lstrip(value: VMValue): VMValue =
    if value.kind != vmString:
      return value
    var i = 0
    while i < value.stringVal.len and value.stringVal[i] in {' ', '\t', '\n', '\r'}:
      inc i
    if i == 0:
      return value
    result = VMValue(kind: vmString, stringVal: value.stringVal[i..^1])

# Removes trailing whitespace from a string
create_filter:
  proc rstrip(value: VMValue): VMValue =
    if value.kind != vmString:
      return value
    var i = value.stringVal.len - 1
    while i >= 0 and value.stringVal[i] in {' ', '\t', '\n', '\r'}:
      dec i
    if i == value.stringVal.len - 1:
      return value
    result = VMValue(kind: vmString, stringVal: value.stringVal[0..i])

# Extracts a substring from a string, or a slice from an array
create_filter:
  proc slice(value: VMValue, args: varargs[VMValue]): VMValue =
    if value.kind notin {vmString, vmArray}:
      return VMValue(kind: vmNull)
    if args.len < 1:
      raise newException(ValueError, "slice filter requires at least 1 argument (start index)")
    if args.len > 2:
      raise newException(ValueError, "slice filter takes at most 2 arguments")

    # Parse start index with strict type checking
    if args[0].kind == vmNull:
      raise newException(ValueError, "slice filter: first argument cannot be undefined")
    if args[0].kind == vmFloat:
      raise newException(ValueError, "slice filter: first argument must be an integer, not a float")
    var startIdx: int
    if args[0].kind == vmInt:
      startIdx = args[0].intVal.int
    elif args[0].kind == vmString:
      try:
        startIdx = args[0].stringVal.parseInt()
      except:
        raise newException(ValueError, "slice filter: first argument must be an integer")
    else:
      raise newException(ValueError, "slice filter: first argument must be an integer")

    var length = 1
    if args.len > 1:
      if args[1].kind == vmNull:
        length = 1
      elif args[1].kind == vmFloat:
        raise newException(ValueError, "slice filter: second argument must be an integer, not a float")
      elif args[1].kind == vmInt:
        length = args[1].intVal.int
      elif args[1].kind == vmString:
        try:
          length = args[1].stringVal.parseInt()
        except:
          raise newException(ValueError, "slice filter: second argument must be an integer")
      else:
        raise newException(ValueError, "slice filter: second argument must be an integer")

    if value.kind == vmString:
      let str = value.stringVal
      let actualStart = if startIdx < 0: max(0, str.len + startIdx) else: startIdx
      if length <= 0 or actualStart >= str.len:
        result = VMValue(kind: vmString, stringVal: "")
      else:
        let endIdx = min(actualStart + length, str.len)
        result = VMValue(kind: vmString, stringVal: str[actualStart..<endIdx])
    else:  # vmArray
      let arr = value.arrayVal
      let actualStart = if startIdx < 0: max(0, arr.len + startIdx) else: startIdx
      if length <= 0 or actualStart >= arr.len:
        result = VMValue(kind: vmArray, arrayVal: @[])
      else:
        let endIdx = min(actualStart + length, arr.len)
        result = VMValue(kind: vmArray, arrayVal: arr[actualStart..<endIdx])

# HTML escapes a string, but only if it hasn't been escaped already
create_filter:
  proc escape_once(value: VMValue): VMValue =
    if value.kind != vmString:
      return value
    let input = value.stringVal
    # The decision is per-character, not per-string: raw markup still gets
    # escaped when an entity appears elsewhere in the same string. Only a
    # '&' that already opens a character reference is passed through.
    var escaped = newStringOfCap(input.len + 16)
    for i, c in input:
      case c
      of '<': escaped.add("&lt;")
      of '>': escaped.add("&gt;")
      of '"': escaped.add("&quot;")
      of '\'': escaped.add("&#39;")
      of '&':
        if input.opens_entity(i): escaped.add('&')
        else: escaped.add("&amp;")
      else: escaped.add(c)
    result = VMValue(kind: vmString, stringVal: escaped)

# Splits a string into an array using a delimiter
create_filter:
  proc split(value: VMValue, args: varargs[VMValue]): VMValue =
    if args.len == 0:
      raise newException(ValueError, "split filter requires exactly 1 argument")
    if args.len > 1:
      raise newException(ValueError, "split filter takes at most 1 argument")

    let input = to_string(value)
    if input.len == 0:
      return VMValue(kind: vmArray, arrayVal: @[])

    let delim = to_string(args[0])

    if delim.len == 0:
      # Empty delimiter: split into individual characters
      var chars: seq[VMValue] = @[]
      for c in input:
        chars.add(VMValue(kind: vmString, stringVal: $c))
      result = VMValue(kind: vmArray, arrayVal: chars)
    else:
      var parts = input.split(delim)
      # Drop trailing empty strings (Ruby split behavior)
      while parts.len > 0 and parts[^1] == "":
        parts.setLen(parts.len - 1)
      let vmParts = parts.mapIt(VMValue(kind: vmString, stringVal: it))
      result = VMValue(kind: vmArray, arrayVal: vmParts)