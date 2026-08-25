import tables, std/macros, sequtils, strutils
import bytecode
export bytecode

type
  Filter* = proc(value: VMValue, args: varargs[VMValue]): VMValue

var filters* = initTable[string, Filter]()

proc register_filter*(name: string, handler: Filter) =
  ## Register a custom filter function
  filters[name] = handler

proc float_to_string*(f: float64): string =
  ## Format a float like Ruby's Float#to_s: the shortest text that reads
  ## back as the same double, always carrying a decimal point. Nim's `$`
  ## already does both; only the exponent form differs, where Nim writes
  ## "1e+20" for Ruby's "1.0e+20".
  ##
  ## Fixing the fraction at 10 digits, as this used to, silently truncated
  ## anything longer: 20 | divided_by: 7.0 rendered "2.8571428571".
  result = $f
  let e = result.find('e')
  if e > 0 and result.find('.', 0, e - 1) < 0:
    result.insert(".0", e)

proc add_to_string*(dest: var string, v: VMValue) =
  ## Append a value's rendering to dest. This is the primitive; to_string
  ## is the same walk into a fresh buffer. Rendering straight into the
  ## destination is what lets output avoid an intermediate string per
  ## value — and, for an array, one per element on top of that.
  case v.kind
  of vmNull: discard
  of vmBool: dest.add(if v.boolVal: "true" else: "false")
  of vmInt: dest.addInt(v.intVal)
  of vmFloat: dest.add(float_to_string(v.floatVal))
  of vmString: dest.add(v.stringVal)
  of vmArray:
    for item in v.arrayVal:
      dest.add_to_string(item)
  of vmObject: dest.add("{}")
  else: discard

proc to_string*(v: VMValue): string =
  if v.kind == vmString:
    result = v.stringVal
  else:
    result.add_to_string(v)

# Enhanced macro that registers the filter and adds argument validation
macro create_filter*(body: untyped): untyped =
  var proc_def: NimNode
  if body.kind == nnkStmtList:
    if body.len != 1 or body[0].kind != nnkProcDef:
      error("Expected a single procedure definition", body)
    proc_def = body[0]
  elif body.kind == nnkProcDef:
    proc_def = body
  else:
    error("Expected a procedure definition", body)

  let proc_name = proc_def.name
  let proc_name_str = $proc_name

  # Analyze the function signature to determine expected argument count
  let formal_params = proc_def[3] # nnkFormalParams
  var expected_arg_count = 0
  var has_varargs = false

  # Skip return type (index 0) and first parameter (value: VMValue, index 1)
  # Count remaining parameters
  for i in 2..<formal_params.len:
    let param = formal_params[i]
    if param.kind == nnkIdentDefs:
      let param_type = param[^2] # Type is second-to-last node
      if (param_type.kind == nnkCommand and param_type[0].strVal == "varargs") or
         (param_type.kind == nnkBracketExpr and param_type[0].strVal == "varargs"):
        has_varargs = true
        break
      else:
        # Count the number of identifiers in this parameter group
        expected_arg_count += param.len - 2 # exclude type and default value

  # Create a wrapper function that validates arguments
  let wrapper_name = newIdentNode(proc_name_str & "_impl")
  let original_name = proc_name

  # Rename the original proc
  proc_def[0] = wrapper_name

  # Create the wrapper proc
  let wrapper_proc = if has_varargs:
    # For varargs functions, don't add validation (they handle it themselves)
    quote do:
      proc `original_name`(value: VMValue, args: varargs[VMValue]): VMValue =
        `wrapper_name`(value, args)
  else:
    # For fixed-arg functions, generate the appropriate call based on arg count
    if expected_arg_count == 0:
      quote do:
        proc `original_name`(value: VMValue, args: varargs[VMValue]): VMValue =
          if args.len != 0:
            raise newException(ValueError, `proc_name_str` & " filter takes no arguments")
          `wrapper_name`(value)
    elif expected_arg_count == 1:
      quote do:
        proc `original_name`(value: VMValue, args: varargs[VMValue]): VMValue =
          if args.len != 1:
            if args.len == 0:
              raise newException(ValueError, `proc_name_str` & " filter requires exactly 1 argument")
            else:
              raise newException(ValueError, `proc_name_str` & " filter takes at most 1 argument")
          `wrapper_name`(value, args[0])
    elif expected_arg_count == 2:
      quote do:
        proc `original_name`(value: VMValue, args: varargs[VMValue]): VMValue =
          if args.len != 2:
            raise newException(ValueError, `proc_name_str` & " filter requires exactly 2 arguments")
          `wrapper_name`(value, args[0], args[1])
    else:
      # For more than 2 args, fall back to generic handling
      quote do:
        proc `original_name`(value: VMValue, args: varargs[VMValue]): VMValue =
          if args.len != `expected_arg_count`:
            raise newException(ValueError, `proc_name_str` & " filter requires exactly " & $`expected_arg_count` & " arguments")
          # This will need manual handling for 3+ args - for now just pass through
          `wrapper_name`(value, args)

  result = newStmtList(
    proc_def,      # Original proc with new name
    wrapper_proc,  # Wrapper proc with validation
    quote do:
      filters[`proc_name_str`] = `original_name`
  )
