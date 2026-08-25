import strutils, tables, sequtils
import ../../../values

# Returns the default value if the input is null, false, or empty
create_filter:
  proc default(value: VMValue, args: varargs[VMValue]): VMValue =
    if args.len > 2:
      raise newException(ValueError, "default filter takes at most 2 arguments")

    # Handle argument ordering: keyword arg (allow_false) may come before or after positional
    # When both args present and first is bool but second is not, the keyword arg came first
    var defaultValue: VMValue
    var allowFalse = false

    if args.len == 0:
      defaultValue = VMValue(kind: vmString, stringVal: "")
    elif args.len == 1:
      defaultValue = args[0]
    else:
      # Two args: determine which is allow_false and which is the default value
      if args[0].kind == vmBool and args[1].kind != vmBool:
        # Keyword arg first: allow_false: bool, default_value
        allowFalse = args[0].boolVal
        defaultValue = args[1]
      else:
        # Normal order: default_value, allow_false: bool
        defaultValue = args[0]
        if args[1].kind == vmBool:
          allowFalse = args[1].boolVal

    # Determine if we should use the default value
    let shouldUseDefault = case value.kind
    of vmNull:
      true
    of vmBool:
      if allowFalse:
        false  # When allow_false is true, false is not replaced
      else:
        not value.boolVal  # Normal: false is replaced
    of vmString:
      value.stringVal == ""
    of vmArray:
      value.arrayVal.len == 0
    of vmObject:
      value.objectVal.len == 0
    else:
      false

    if shouldUseDefault:
      result = defaultValue
    else:
      result = value

# Returns a string representation of the input
create_filter:
  proc inspect(value: VMValue, args: varargs[VMValue]): VMValue =
    var inspected: string
    case value.kind
    of vmNull:
      inspected = "null"
    of vmBool:
      inspected = $value.boolVal
    of vmInt:
      inspected = $value.intVal
    of vmFloat:
      inspected = $value.floatVal
    of vmString:
      inspected = "\"" & value.stringVal & "\""
    of vmArray:
      var items: seq[string] = @[]
      for item in value.arrayVal:
        let itemStr = case item.kind
        of vmString: "\"" & item.stringVal & "\""
        of vmNull: "null"
        of vmBool: $item.boolVal
        of vmInt: $item.intVal
        of vmFloat: $item.floatVal
        else: "[object]"
        items.add(itemStr)
      inspected = "[" & items.join(", ") & "]"
    of vmObject:
      inspected = "{object}"
    else:
      inspected = "{unknown}"
    
    result = VMValue(kind: vmString, stringVal: inspected)


# Everything outside this set is percent-encoded by url_encode; it is the
# set Ruby's CGI.escape leaves untouched.
const url_unreserved = {'A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~'}
const upper_hex = "0123456789ABCDEF"

# URL encodes a string
create_filter:
  proc url_encode(value: VMValue): VMValue =
    if value.kind != vmString:
      return value
    # Form encoding, not path encoding: a space becomes '+' and every other
    # reserved byte becomes %XX. The old hand-picked list of five
    # characters left '@', '!' and the rest of the reserved set standing.
    var encoded = newStringOfCap(value.stringVal.len + 8)
    for c in value.stringVal:
      if c in url_unreserved:
        encoded.add(c)
      elif c == ' ':
        encoded.add('+')
      else:
        encoded.add('%')
        encoded.add(upper_hex[c.ord shr 4])
        encoded.add(upper_hex[c.ord and 0x0F])
    result = VMValue(kind: vmString, stringVal: encoded)

# URL decodes a string
create_filter:
  proc url_decode(value: VMValue): VMValue =
    if value.kind != vmString:
      return value
    let input = value.stringVal
    var decoded = newStringOfCap(input.len)
    var i = 0
    while i < input.len:
      case input[i]
      of '+':
        decoded.add(' ')
        inc i
      of '%':
        # Lenient like CGI.unescape: a truncated or non-hex escape is left
        # standing rather than raising.
        if i + 2 < input.len and input[i + 1] in HexDigits and input[i + 2] in HexDigits:
          decoded.add(chr(parseHexInt(input[i + 1 .. i + 2])))
          inc i, 3
        else:
          decoded.add('%')
          inc i
      else:
        decoded.add(input[i])
        inc i
    result = VMValue(kind: vmString, stringVal: decoded)

# Returns the type of the value as a string
create_filter:
  proc type_of(value: VMValue, args: varargs[VMValue]): VMValue =
    let typeName = case value.kind
    of vmNull: "null"
    of vmBool: "boolean"
    of vmInt: "number"
    of vmFloat: "number"
    of vmString: "string"
    of vmArray: "array"
    of vmObject: "object"
    else: "unknown"
    
    result = VMValue(kind: vmString, stringVal: typeName)

# Converts a value to JSON string
create_filter:
  proc json(value: VMValue, args: varargs[VMValue]): VMValue =
    proc toJson(v: VMValue): string =
      case v.kind
      of vmNull:
        "null"
      of vmBool:
        $v.boolVal
      of vmInt:
        $v.intVal
      of vmFloat:
        $v.floatVal
      of vmString:
        "\"" & v.stringVal.replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") & "\""
      of vmArray:
        "[" & v.arrayVal.mapIt(toJson(it)).join(",") & "]"
      of vmObject:
        var pairs: seq[string] = @[]
        for k, v in v.objectVal:
          pairs.add("\"" & k & "\":" & toJson(v))
        "{" & pairs.join(",") & "}"
      else:
        "null"
    
    result = VMValue(kind: vmString, stringVal: toJson(value))

# URL encodes a string more comprehensively
create_filter:
  proc url_param_escape(value: VMValue, args: varargs[VMValue]): VMValue =
    if value.kind != vmString:
      return value
    
    var encoded = ""
    for c in value.stringVal:
      case c:
      of ' ': encoded.add("%20")
      of '!': encoded.add("%21")
      of '"': encoded.add("%22") 
      of '#': encoded.add("%23")
      of '$': encoded.add("%24")
      of '%': encoded.add("%25")
      of '&': encoded.add("%26")
      of '\'': encoded.add("%27")
      of '(': encoded.add("%28")
      of ')': encoded.add("%29")
      of '*': encoded.add("%2A")
      of '+': encoded.add("%2B")
      of ',': encoded.add("%2C")
      of '/': encoded.add("%2F")
      of ':': encoded.add("%3A")
      of ';': encoded.add("%3B")
      of '=': encoded.add("%3D")
      of '?': encoded.add("%3F")
      of '@': encoded.add("%40")
      of '[': encoded.add("%5B")
      of ']': encoded.add("%5D")
      else: encoded.add(c)
    
    result = VMValue(kind: vmString, stringVal: encoded)

# Escapes a string for use in URLs  
create_filter:
  proc url_escape(value: VMValue, args: varargs[VMValue]): VMValue =
    # This is essentially the same as url_encode but with different name for compatibility
    return url_encode(value, args)