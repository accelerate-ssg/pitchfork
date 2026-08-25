import sequtils, algorithm, strutils, tables
import ../../../values

proc natural_key*(v: VMValue): string =
  ## Comparison text for sort_natural. Same as rendering except for
  ## objects: rendering collapses every object to "{}", which would make
  ## them all compare equal, so spell out the pairs the way the reference
  ## implementation's Hash#to_s does.
  if v.kind != vmObject:
    return to_string(v)
  var pairs: seq[string] = @[]
  for key, item in v.objectVal:
    let rendered = if item.kind == vmString: "\"" & item.stringVal & "\""
                   else: to_string(item)
    pairs.add("\"" & key & "\"=>" & rendered)
  result = "{" & pairs.join(", ") & "}"


# Returns the first element of an array or first key-value pair of an object
create_filter:
  proc first(value: VMValue): VMValue =
    case value.kind
    of vmArray:
      if value.arrayVal.len > 0: value.arrayVal[0]
      else: VMValue(kind: vmNull)
    of vmObject:
      if value.objectVal.len > 0:
        for k, v in value.objectVal:
          return VMValue(kind: vmArray, arrayVal: @[
            VMValue(kind: vmString, stringVal: k), v])
      VMValue(kind: vmNull)
    else: VMValue(kind: vmNull)

# Returns the last element of an array
create_filter:
  proc last(value: VMValue): VMValue =
    case value.kind
    of vmArray:
      if value.arrayVal.len > 0: value.arrayVal[^1]
      else: VMValue(kind: vmNull)
    else: VMValue(kind: vmNull)

# Joins the elements of an array into a string separated by a delimiter
create_filter:
  proc join(value: VMValue, args: varargs[VMValue]): VMValue =
    if args.len > 1:
      raise newException(ValueError, "join filter takes at most 1 argument")
    if value.kind != vmArray:
      return value

    let delimiter = if args.len > 0:
      to_string(args[0])  # Convert any type to string; null → ""
    else:
      " "

    # Flatten nested arrays (Ruby's Array#join behavior)
    proc flatten_items(items: seq[VMValue]): seq[VMValue] =
      for item in items:
        if item.kind == vmArray:
          result.add(flatten_items(item.arrayVal))
        else:
          result.add(item)

    let flat = flatten_items(value.arrayVal)
    let joined = flat.mapIt(to_string(it)).join(delimiter)
    result = VMValue(kind: vmString, stringVal: joined)

# Returns the size of an array or string or object
create_filter:
  proc size(value: VMValue): VMValue =
    case value.kind
    of vmArray:
      result = VMValue(kind: vmInt, intVal: value.arrayVal.len.int64)
    of vmString:
      result = VMValue(kind: vmInt, intVal: value.stringVal.len.int64)
    of vmObject:
      result = VMValue(kind: vmInt, intVal: value.objectVal.len.int64)
    else:
      result = VMValue(kind: vmInt, intVal: 0)

# Sorts an array in ascending order
create_filter:
  proc sort(value: VMValue, args: varargs[VMValue]): VMValue =
    if args.len > 1:
      raise newException(ValueError, "sort filter takes at most 1 argument")
    if value.kind != vmArray:
      return value
    
    var sorted = value.arrayVal
    
    # If there's a property argument, use sort_by logic
    if args.len > 0 and args[0].kind == vmString:
      let propName = args[0].stringVal
      sorted.sort(proc(a, b: VMValue): int =
        var aVal, bVal: VMValue
        if a.kind == vmObject and propName in a.objectVal:
          aVal = a.objectVal[propName]
        else:
          aVal = VMValue(kind: vmNull)

        if b.kind == vmObject and propName in b.objectVal:
          bVal = b.objectVal[propName]
        else:
          bVal = VMValue(kind: vmNull)

        # Null-safe comparison: nulls sort last
        if aVal.kind == vmNull and bVal.kind == vmNull: return 0
        if aVal.kind == vmNull: return 1
        if bVal.kind == vmNull: return -1

        # Compare based on types
        if aVal.kind == vmString and bVal.kind == vmString:
          return cmp(aVal.stringVal, bVal.stringVal)
        elif aVal.kind == vmInt and bVal.kind == vmInt:
          return cmp(aVal.intVal, bVal.intVal)
        elif aVal.kind == vmFloat and bVal.kind == vmFloat:
          return cmp(aVal.floatVal, bVal.floatVal)
        else:
          return cmp(to_string(aVal), to_string(bVal))
      )
    else:
      # No property argument - direct sort
      # Check for incompatible types before sorting
      if sorted.len > 1:
        var hasString = false
        var hasNumeric = false
        var hasBool = false
        var hasComplex = false
        
        for item in sorted:
          case item.kind:
          of vmString:
            hasString = true
          of vmInt, vmFloat:
            hasNumeric = true
          of vmBool:
            hasBool = true
          of vmArray, vmObject:
            hasComplex = true
          else:
            discard
        
        # If we have complex types mixed with primitives, that's incompatible
        if hasComplex and (hasString or hasNumeric or hasBool):
          raise newException(ValueError, "Cannot sort array with incompatible types")
        
        # Arrays are also incompatible for direct sorting
        if hasComplex:
          var hasArray = false
          for item in sorted:
            if item.kind == vmArray:
              hasArray = true
              break
          if hasArray:
            raise newException(ValueError, "Cannot sort array with incompatible types")
      
      sorted.sort(proc(a, b: VMValue): int =
        # Compare based on types
        if a.kind == vmString and b.kind == vmString:
          return cmp(a.stringVal, b.stringVal)
        elif a.kind == vmInt and b.kind == vmInt:
          return cmp(a.intVal, b.intVal)
        elif a.kind == vmFloat and b.kind == vmFloat:
          return cmp(a.floatVal, b.floatVal)
        elif a.kind == vmBool and b.kind == vmBool:
          return cmp(a.boolVal, b.boolVal)
        # Mixed numeric types
        elif a.kind in [vmInt, vmFloat] and b.kind in [vmInt, vmFloat]:
          let aFloat = if a.kind == vmInt: a.intVal.float else: a.floatVal
          let bFloat = if b.kind == vmInt: b.intVal.float else: b.floatVal
          return cmp(aFloat, bFloat)
        else:
          # Different types - sort by string representation
          return cmp(to_string(a), to_string(b))
      )
    
    result = VMValue(kind: vmArray, arrayVal: sorted)

# Reverses an array
create_filter:
  proc reverse(value: VMValue, args: varargs[VMValue]): VMValue =
    if args.len > 0:
      raise newException(ValueError, "reverse filter takes no arguments")
    case value.kind
    of vmArray:
      var reversed = value.arrayVal
      reversed.reverse()
      result = VMValue(kind: vmArray, arrayVal: reversed)
    of vmString:
      var reversed = value.stringVal
      reversed.reverse()
      result = VMValue(kind: vmString, stringVal: reversed)
    else:
      result = value

# Maps an attribute from each object in an array
create_filter:
  proc map(value: VMValue, args: varargs[VMValue]): VMValue =
    if args.len != 1:
      raise newException(ValueError, "map filter requires exactly 1 argument (property name)")
    
    # Handle undefined/null property name - treat as empty string
    let propName = if args[0].kind == vmString:
      args[0].stringVal
    elif args[0].kind == vmNull:
      ""  # Undefined property name - will never match, results in all nulls
    else:
      ""  # Invalid type - treat as empty string
    
    # Handle different input types
    var inputArray: seq[VMValue]
    case value.kind:
    of vmArray:
      inputArray = value.arrayVal
    of vmObject:
      # Single object treated as single-item array
      inputArray = @[value]
    else:
      raise newException(ValueError, "map filter can only be applied to arrays or objects")
    
    # Check if we have problematic non-object items that should cause error
    var hasNonObjects = false
    for item in inputArray:
      if item.kind != vmObject and item.kind != vmArray:
        # Numbers, strings, etc. that can't be mapped
        hasNonObjects = true
        break
    
    if hasNonObjects:
      raise newException(ValueError, "map filter requires all items to be objects or arrays")
    
    var mapped: seq[VMValue] = @[]
    
    proc mapItem(item: VMValue): seq[VMValue] =
      if item.kind == vmObject:
        if propName != "" and propName in item.objectVal:
          @[item.objectVal[propName]]
        else:
          @[VMValue(kind: vmNull)]
      elif item.kind == vmArray:
        # Recursively map nested arrays
        var nestedMapped: seq[VMValue] = @[]
        for nestedItem in item.arrayVal:
          nestedMapped.add(mapItem(nestedItem))
        nestedMapped
      else:
        @[VMValue(kind: vmNull)]
    
    for item in inputArray:
      mapped.add(mapItem(item))
    
    result = VMValue(kind: vmArray, arrayVal: mapped)

# Removes nil values from an array, optionally by property
create_filter:
  proc compact(value: VMValue, args: varargs[VMValue]): VMValue =
    # Check argument count first, regardless of value type
    if args.len > 1:
      raise newException(ValueError, "compact filter takes at most 1 argument")
    
    # If value is not an array, wrap in array (non-null values pass through)
    if value.kind != vmArray:
      if value.kind == vmNull:
        return VMValue(kind: vmArray, arrayVal: @[])
      return VMValue(kind: vmArray, arrayVal: @[value])
    
    # If a property name is provided, compact based on that property
    if args.len == 1:
      if args[0].kind != vmString:
        return value
      let propName = args[0].stringVal
      var filtered: seq[VMValue]
      for item in value.arrayVal:
        if item.kind == vmObject and propName in item.objectVal:
          let propValue = item.objectVal[propName]
          if propValue.kind != vmNull:
            filtered.add(item)
        elif item.kind != vmObject:
          # Non-objects are kept if property filtering is used
          filtered.add(item)
      result = VMValue(kind: vmArray, arrayVal: filtered)
    else:
      # No property name - just remove null values
      let filtered = value.arrayVal.filterIt(it.kind != vmNull)
      result = VMValue(kind: vmArray, arrayVal: filtered)

# Concatenates arrays
create_filter:
  proc concat(value: VMValue, args: varargs[VMValue]): VMValue =
    if args.len == 0:
      raise newException(ValueError, "concat filter requires at least 1 argument")

    # Validate arguments are arrays
    for arg in args:
      if arg.kind == vmNull:
        raise newException(ValueError, "concat filter argument is undefined or null")
      elif arg.kind != vmArray:
        raise newException(ValueError, "concat filter arguments must be arrays")

    # Helper to flatten nested arrays
    proc flatten(arr: seq[VMValue]): seq[VMValue] =
      for item in arr:
        if item.kind == vmArray:
          result.add(flatten(item.arrayVal))
        else:
          result.add(item)

    # Convert left value to array, flattening nested arrays
    var left: seq[VMValue]
    case value.kind
    of vmArray: left = flatten(value.arrayVal)
    of vmNull: left = @[]
    else: left = @[value]

    for arg in args:
      left.add(arg.arrayVal)

    result = VMValue(kind: vmArray, arrayVal: left)

# Returns unique elements from an array
create_filter:
  proc uniq(value: VMValue, args: varargs[VMValue]): VMValue =
    if args.len > 1:
      raise newException(ValueError, "uniq filter takes at most 1 argument")

    if value.kind != vmArray:
      return value

    # Property-based deduplication
    if args.len == 1 and args[0].kind == vmString:
      let propName = args[0].stringVal
      var unique: seq[VMValue] = @[]
      var seenKeys: seq[string] = @[]
      for item in value.arrayVal:
        let keyVal = if item.kind == vmObject and propName in item.objectVal:
          to_string(item.objectVal[propName])
        else:
          "\x00__nil__"  # Sentinel for missing property
        if keyVal notin seenKeys:
          seenKeys.add(keyVal)
          unique.add(item)
      result = VMValue(kind: vmArray, arrayVal: unique)
    else:
      # Value-based deduplication using string representation
      var unique: seq[VMValue] = @[]
      var seenKeys: seq[string] = @[]
      for item in value.arrayVal:
        # Build a unique key: kind + string representation
        let key = $item.kind & ":" & to_string(item)
        if key notin seenKeys:
          seenKeys.add(key)
          unique.add(item)
      result = VMValue(kind: vmArray, arrayVal: unique)

# Filters array based on a property value
create_filter:
  proc where(value: VMValue, args: varargs[VMValue]): VMValue =
    # Check for empty or undefined value first
    if value.kind == vmNull:
      return VMValue(kind: vmArray, arrayVal: @[])
      
    if value.kind != vmArray:
      raise newException(ValueError, "where filter can only be applied to arrays")
    
    if args.len > 2:
      raise newException(ValueError, "where filter takes at most 2 arguments")
    
    if args.len < 1:
      raise newException(ValueError, "where filter requires at least 1 argument (property name)")
      
    # Handle undefined/null first argument
    if args[0].kind == vmNull:
      return VMValue(kind: vmArray, arrayVal: @[])
    
    if args[0].kind != vmString:
      raise newException(ValueError, "where filter requires at least 1 argument (property name)")
    
    let propName = args[0].stringVal
    
    if args.len == 1 or (args.len == 2 and args[1].kind == vmNull):
      # Filter for objects that have the property with truthy value
      # (also triggered when second argument is nil/undefined)
      var filtered: seq[VMValue] = @[]
      for item in value.arrayVal:
        if item.kind == vmObject and propName in item.objectVal:
          let propVal = item.objectVal[propName]
          # In Liquid, where with one arg filters for truthy values
          if propVal.kind != vmNull and not (propVal.kind == vmBool and not propVal.boolVal):
            filtered.add(item)
      result = VMValue(kind: vmArray, arrayVal: filtered)
    else:
      # Filter for objects where property equals value
      let targetValue = args[1]
      var filtered: seq[VMValue] = @[]
      for item in value.arrayVal:
        if item.kind == vmObject:
          let hasProp = propName in item.objectVal
          let itemPropValue = if hasProp: item.objectVal[propName]
                             else: VMValue(kind: vmNull)
          # Compare using liquid_eq semantics
          var matches = false
          if itemPropValue.kind == targetValue.kind:
            case itemPropValue.kind
            of vmNull: matches = true
            of vmBool: matches = itemPropValue.boolVal == targetValue.boolVal
            of vmInt: matches = itemPropValue.intVal == targetValue.intVal
            of vmFloat: matches = itemPropValue.floatVal == targetValue.floatVal
            of vmString: matches = itemPropValue.stringVal == targetValue.stringVal
            else: discard
          elif itemPropValue.kind == vmNull and targetValue.kind == vmNull:
            matches = true
          if matches:
            filtered.add(item)
      result = VMValue(kind: vmArray, arrayVal: filtered)

# Sorts an array by a property of each element
create_filter:
  proc sort_by(value: VMValue, args: varargs[VMValue]): VMValue =
    if value.kind != vmArray:
      return value
    
    if args.len != 1 or args[0].kind != vmString:
      raise newException(ValueError, "sort_by filter requires exactly 1 string argument (property name)")
    
    let propName = args[0].stringVal
    var sorted = value.arrayVal
    
    sorted.sort(proc(a, b: VMValue): int =
      var aVal, bVal: VMValue
      if a.kind == vmObject and propName in a.objectVal:
        aVal = a.objectVal[propName]
      else:
        aVal = VMValue(kind: vmNull)
      
      if b.kind == vmObject and propName in b.objectVal:
        bVal = b.objectVal[propName]
      else:
        bVal = VMValue(kind: vmNull)
      
      # Compare based on types
      if aVal.kind == vmString and bVal.kind == vmString:
        return cmp(aVal.stringVal, bVal.stringVal)
      elif aVal.kind == vmInt and bVal.kind == vmInt:
        return cmp(aVal.intVal, bVal.intVal)
      elif aVal.kind == vmFloat and bVal.kind == vmFloat:
        return cmp(aVal.floatVal, bVal.floatVal)
      else:
        return cmp(to_string(aVal), to_string(bVal))
    )
    
    result = VMValue(kind: vmArray, arrayVal: sorted)

# Sorts an array using natural sort order
create_filter:
  proc sort_natural(value: VMValue, args: varargs[VMValue]): VMValue =
    if args.len > 1:
      raise newException(ValueError, "sort_natural filter takes at most 1 argument")
    if value.kind != vmArray:
      return value

    # A property argument sorts by that key; without one — including when
    # the argument is an undefined variable — the elements compare on their
    # own text. Either way the comparison ignores case and puts nils last.
    let propName = if args.len > 0 and args[0].kind == vmString: args[0].stringVal else: ""

    proc sortKey(v: VMValue): VMValue =
      if propName.len == 0:
        return v
      if v.kind == vmObject and propName in v.objectVal:
        return v.objectVal[propName]
      VMValue(kind: vmNull)

    var sorted = value.arrayVal
    sorted.sort(proc(a, b: VMValue): int =
      let aKey = sortKey(a)
      let bKey = sortKey(b)
      if aKey.kind == vmNull and bKey.kind == vmNull: return 0
      if aKey.kind == vmNull: return 1
      if bKey.kind == vmNull: return -1
      cmpIgnoreCase(natural_key(aKey), natural_key(bKey))
    )

    result = VMValue(kind: vmArray, arrayVal: sorted)

# Sums all numeric values in an array
create_filter:
  proc sum(value: VMValue, args: varargs[VMValue]): VMValue =
    if args.len > 1:
      raise newException(ValueError, "sum filter takes at most 1 argument")
    if value.kind != vmArray:
      return VMValue(kind: vmInt, intVal: 0)
    
    let propName = if args.len > 0 and args[0].kind == vmString: args[0].stringVal else: ""
    
    # If property name is specified, validate that all items are objects
    if propName != "":
      for item in value.arrayVal:
        if item.kind != vmObject:
          raise newException(ValueError, "sum filter with property argument requires all items to be objects")
    
    var sumInt: int64 = 0
    var sumFloat: float64 = 0.0
    var hasFloat = false

    proc addValue(val: VMValue) =
      case val.kind
      of vmInt:
        sumInt += val.intVal
        sumFloat += val.intVal.float
      of vmFloat:
        hasFloat = true
        sumFloat += val.floatVal
      of vmString:
        try:
          if '.' in val.stringVal:
            hasFloat = true
            sumFloat += val.stringVal.parseFloat()
          else:
            let intVal = val.stringVal.parseInt()
            sumInt += intVal
            sumFloat += intVal.float
        except:
          discard
      of vmArray:
        # Recursively sum nested arrays
        for nestedItem in val.arrayVal:
          addValue(nestedItem)
      else:
        discard

    for item in value.arrayVal:
      if propName != "":
        if item.kind == vmObject and propName in item.objectVal:
          addValue(item.objectVal[propName])
      else:
        addValue(item)

    if hasFloat:
      result = VMValue(kind: vmFloat, floatVal: sumFloat)
    else:
      result = VMValue(kind: vmInt, intVal: sumInt)