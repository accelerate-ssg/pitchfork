import times, strutils
import ../../../values

proc liquid_date_format(dt: DateTime, format: string): string =
  ## Format a DateTime with Liquid/strftime format directives.
  ## Processes directives one at a time, building the output string directly.
  result = ""
  var i = 0

  while i < format.len:
    if format[i] == '%' and i + 1 < format.len:
      case format[i + 1]
      of '%':
        result.add('%')
        i += 2
      of 's':
        result.add($dt.toTime.toUnix)
        i += 2
      of 'Y':
        result.add(dt.format("yyyy"))
        i += 2
      of 'm':
        result.add(dt.format("MM"))
        i += 2
      of 'd':
        result.add(dt.format("dd"))
        i += 2
      of 'H':
        result.add(dt.format("HH"))
        i += 2
      of 'M':
        result.add(dt.format("mm"))
        i += 2
      of 'S':
        result.add(dt.format("ss"))
        i += 2
      of 'b':
        result.add(dt.format("MMM"))
        i += 2
      of 'B':
        result.add(dt.format("MMMM"))
        i += 2
      of 'y':
        result.add(dt.format("yy"))
        i += 2
      of 'I':
        result.add(dt.format("hh"))
        i += 2
      of 'p':
        result.add(dt.format("tt"))
        i += 2
      of 'P':
        result.add(if dt.hour < 12: "am" else: "pm")
        i += 2
      of 'A':
        result.add(dt.format("dddd"))
        i += 2
      of 'a':
        result.add(dt.format("ddd"))
        i += 2
      of 'e':
        result.add(align($dt.monthday, 2))
        i += 2
      of 'j':
        result.add(align($(dt.yearday + 1), 3, '0'))
        i += 2
      of 'Z':
        result.add(dt.format("zzz"))
        i += 2
      of 'z':
        result.add(dt.format("zzz"))
        i += 2
      else:
        # Unknown directive — pass through as-is
        result.add(format[i..i+1])
        i += 2
    else:
      result.add(format[i])
      i += 1

# Formats a date according to a specified format
create_filter:
  proc date(value: VMValue, args: varargs[VMValue]): VMValue =
    if args.len < 1:
      raise newException(ValueError, "date filter requires 1 argument (format)")
    if args.len > 1:
      raise newException(ValueError, "date filter takes at most 1 argument")

    # If format argument is undefined/null, return original value
    if args[0].kind != vmString:
      result = value
      return

    let format = args[0].stringVal

    var dt: DateTime

    case value.kind
    of vmInt:
      # Treat as Unix timestamp
      try:
        dt = fromUnix(value.intVal).utc
      except:
        result = value
        return
    of vmString:
      let input = value.stringVal
      # Try parsing as Unix timestamp (non-negative only)
      var parsedAsTimestamp = false
      if input.len > 0 and input[0] in {'0'..'9'}:
        try:
          let timestamp = parseBiggestInt(input)
          dt = fromUnix(timestamp).utc
          parsedAsTimestamp = true
        except:
          discard
      if not parsedAsTimestamp:
        # Try various date formats
        var parsed = false
        for fmt in ["yyyy-MM-dd'T'HH:mm:sszzz", "yyyy-MM-dd HH:mm:ss",
                     "yyyy-MM-dd", "MMMM d, yyyy", "MMMM dd, yyyy",
                     "MMM d, yyyy", "MMM dd, yyyy",
                     "d MMMM yyyy", "dd MMMM yyyy"]:
          try:
            dt = parse(input, fmt, utc())
            parsed = true
            break
          except:
            discard
        if not parsed:
          result = value
          return
    else:
      result = value
      return

    try:
      result = VMValue(kind: vmString, stringVal: liquid_date_format(dt, format))
    except:
      result = value

# Returns the current date/time
create_filter:
  proc date_now(value: VMValue, args: varargs[VMValue]): VMValue =
    let format = if args.len > 0 and args[0].kind == vmString:
      args[0].stringVal
    else:
      "%Y-%m-%d %H:%M:%S"
    
    # Through liquid_date_format, not DateTime.format: the argument is a
    # strftime pattern like the `date` filter takes, and Nim's own format
    # raises on the '%' rather than reading it. That made every call to
    # this filter throw, the default format included.
    result = VMValue(kind: vmString, stringVal: liquid_date_format(now(), format))

# Adds time to a date
create_filter:
  proc date_add(value: VMValue, args: varargs[VMValue]): VMValue =
    if args.len < 2:
      raise newException(ValueError, "date_add filter requires 2 arguments (amount, unit)")
    
    let amount = if args[0].kind == vmInt: args[0].intVal.int else: 0
    let unit = if args[1].kind == vmString: args[1].stringVal else: "days"
    
    var input: string
    case value.kind
    of vmString:
      input = value.stringVal
    else:
      result = value
      return
    
    try:
      var dt: DateTime
      try:
        dt = parse(input, "yyyy-MM-dd'T'HH:mm:sszzz")
      except:
        try:
          dt = parse(input, "yyyy-MM-dd HH:mm:ss")  
        except:
          dt = parse(input, "yyyy-MM-dd")
      
      let newDt = case unit.toLower()
      of "seconds", "second", "s":
        dt + initDuration(seconds = amount)
      of "minutes", "minute", "m":
        dt + initDuration(minutes = amount)
      of "hours", "hour", "h":
        dt + initDuration(hours = amount)  
      of "days", "day", "d":
        dt + initDuration(days = amount)
      of "weeks", "week", "w":
        dt + initDuration(weeks = amount)
      of "months", "month":
        dt + initTimeInterval(months = amount)
      of "years", "year", "y":
        dt + initTimeInterval(years = amount)
      else:
        dt
      
      result = VMValue(kind: vmString, stringVal: newDt.format("yyyy-MM-dd'T'HH:mm:sszzz"))
    except:
      result = value