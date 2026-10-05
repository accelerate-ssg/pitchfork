import std/[tables, hashes, algorithm, math, sets]
import arena_context_store

from bytecode import Instruction, VMValue, VMValueKind, TemplateCompiler

export arena_context_store

type
  # Tag runtime handler (forward declaration for VM)
  TagRuntimeHandler* = proc(vm: var VM, inst: Instruction) {.nimcall.}

  CompiledPartial* = object
    ## A partial compiled once and reused by every include that names it.
    bytecode*: seq[Instruction]
    strings*: seq[string]
    constants*: seq[VMValue]

  # Runtime VM for executing templates. Language-agnostic: template-language
  # specifics arrive via tag_handlers, the filter registry, and partial_compiler.
  VM* = object
    # Execution state
    stack*: seq[VMValue]
    pc*: int                    # Program counter
    
    # The compiled template being executed
    bytecode*: seq[Instruction]
    strings*: seq[string]       # String constants
    constants*: seq[VMValue]    # Other constants
    
    # Runtime data
    # The caller's context, borrowed rather than copied: the VM never
    # writes through this pointer, and it must outlive the VM. Every
    # caller satisfies that — a VM lives entirely inside one render call,
    # and a sub-VM inside its parent's. nil when no context was given.
    context*: ptr Table[string, VMValue]
    # Arena-backed lazy context, borrowed on the same terms as context.
    # Top-level names resolve from context_root when the table probes
    # miss; containers travel as vmNode ids and every access lands in
    # the arena's access log. nil / InvalidNodeId when not rendering
    # against an arena.
    arena*: ptr Arena
    context_root*: NodeId
    variables*: Table[string, VMValue]  # VM-owned scope (e.g. a {% render %}-bound forloop)
    # Template-created variables, shared by reference with every
    # shared-scope sub-VM: an include used to copy the whole table in and
    # back out again, so its cost scaled with the caller's scope.
    locals*: TableRef[string, VMValue]
    
    # Iteration state
    iterators*: seq[Iterator]   # Stack of active iterators

    # Context stack (Mustache-family scoped name resolution; empty for Liquid)
    ctx_stack*: seq[VMValue]
    
    # Output
    output*: string
    escape_html*: bool
    
    # Capture state for {% capture %} tags
    capture_stack*: seq[string]  # Stack of captured outputs
    capture_escape_stack*: seq[bool]  # Track escape state for nested captures
    is_capturing*: bool
    
    # Filters are now handled by the filters module

    # Loop continuation tracking (for offset: continue), shared with
    # sub-VMs on the same terms as locals.
    loop_offsets*: TableRef[string, int]  # var_name -> last consumed index

    # Partial sources, borrowed on the same terms as context: read-only
    # for the VM's lifetime, shared with every sub-VM. nil when none were
    # given.
    partials*: ptr Table[string, string]  # partial name -> source
    # Compiled partials, memoised by name (and indent) and shared by
    # reference with every sub-VM. Copying it per include meant
    # deep-copying the bytecode of every partial already compiled —
    # including ones this include does not render — in and back out
    # again. Nothing about a name-keyed memo is observable through
    # aliasing.
    partial_cache*: TableRef[string, CompiledPartial]
    partial_compiler*: TemplateCompiler  # Compiles partial source in the template's language

    # Tag runtime handlers (for externalized tag implementations)
    tag_handlers*: Table[string, TagRuntimeHandler]

    # Break/continue propagation (for include tag)
    pending_break*: bool
    pending_continue*: bool

    # Keyword arguments (for include tag) - read-only overlay on locals
    keyword_args*: Table[string, VMValue]

    # Blank check state (for whitespace-only block suppression)
    blank_check_stack*: seq[int]  # Stack of output positions to check

    # ── State owned by the Liquid tine's runtime tag handlers ──
    # TODO: generalize into per-handler extension state once a second
    # tine exercises the boundary.
    cycle_counters*: Table[string, int]  # {% cycle %}: group_key -> current index
    counters*: Table[string, int64]      # {% increment/decrement %}: counter_name -> value
    tablerow_iters*: seq[TablerowState]  # Stack of active tablerow iterators
    ifchanged_last*: string              # Last output from ifchanged block

    # Dependency tracking
    track_access*: bool                    # Enable/disable tracking (default false = zero overhead)
    path_stack*: seq[string]               # Shadow stack for property paths
    accessed_paths*: HashSet[string]       # Recorded dependency paths

    # Performance
    instruction_count*: int
    max_stack_size*: int
    
  TablerowState* = object
    items*: seq[VMValue]
    index*: int          # Current item index (0-based)
    cols*: int           # Number of columns (0 = unlimited)
    var_name*: string    # Loop variable name
    # Cell metadata is built on demand, invalidated when the cell
    # advances — same scheme as Iterator.forloop_cache.
    tablerowloop_cache*: VMValue
    tablerowloop_valid*: bool

  Iterator* = object
    items*: seq[VMValue]
    keys*: seq[string]   # Object-key per item when iterating an object as
                         # values (Handlebars #each); empty otherwise
    builds_forloop*: bool  # Expose forloop metadata to the loop body.
                           # Tines whose loops never mention forloop/@data
                           # (Mustache) leave this off.
    index*: int
    var_name*: string
    body_end*: int       # pc this loop's endfor leads to; 0 until its first
                         # opIterNext has run
    original_offset*: int  # Offset applied to original collection (for offset: continue tracking)
    saved_var*: VMValue      # Pre-loop binding of the loop variable, if any.
                             # Liquid scopes the loop variable to the loop:
                             # an outer assign of the same name must be
                             # visible again after endfor.
    had_saved_var*: bool
    saved_forloop*: VMValue  # The enclosing loop's forloop (becomes parentloop)
    loop_name*: string       # forloop.name value (e.g., "tag-product.tags")
    # forloop metadata is built on demand, not per iteration: most loop
    # bodies never mention it, and building the object cost more than the
    # rest of an iteration put together. Invalidated when the iteration
    # advances, rebuilt at most once per iteration by the first lookup.
    forloop_cache*: VMValue
    forloop_valid*: bool

  LiquidVM* {.deprecated: "renamed to VM".} = VM
    


proc `==`*(a, b: VMValue): bool =
  ## Compare two VMValues for structural equality
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  # First check if kinds match
  if a.kind != b.kind:
    return false
  
  # Then compare based on kind
  case a.kind
  of vm_null:
    return true  # All nulls are equal
  of vm_bool:
    return a.boolVal == b.boolVal
  of vm_int:
    return a.intVal == b.intVal
  of vm_float:
    return a.floatVal == b.floatVal
  of vm_string:
    return a.stringVal == b.stringVal
  of vm_array:
    if a.arrayVal.len != b.arrayVal.len:
      return false
    for i in 0..<a.arrayVal.len:
      if a.arrayVal[i] != b.arrayVal[i]:
        return false
    return true
  of vm_object:
    if a.objectVal.len != b.objectVal.len:
      return false
    for key, aVal in a.objectVal:
      if key notin b.objectVal:
        return false
      if aVal != b.objectVal[key]:
        return false
    return true
  of vmEmpty:
    return true  # All empty values are equal
  of vmNode:
    # Same node = same value. Two different nodes may hold equal data,
    # but callers that care (opEqual and friends) materialize before
    # comparing, so identity is the only meaning left here.
    return a.nodeVal == b.nodeVal

# You might also want to add hash for using VMValue in tables
proc hash*(v: VMValue): Hash =
  ## Hash a VMValue for use in tables/sets
  var h: Hash = 0
  h = h !& hash(v.kind.int)
  
  case v.kind
  of vm_null:
    discard  # All nulls hash the same
  of vm_bool:
    h = h !& hash(v.boolVal)
  of vm_int:
    h = h !& hash(v.intVal)
  of vm_float:
    h = h !& hash(v.floatVal)
  of vm_string:
    h = h !& hash(v.stringVal)
  of vm_array:
    for item in v.arrayVal:
      h = h !& hash(item)
  of vm_object:
    # Hash based on sorted keys for consistency
    var keys: seq[string] = @[]
    for k in v.objectVal.keys:
      keys.add(k)
    keys.sort()
    for k in keys:
      h = h !& hash(k)
      h = h !& hash(v.objectVal[k])
  of vmEmpty:
    discard  # All empty values hash the same
  of vmNode:
    h = h !& hash(v.nodeVal)

  result = !$h

# Also useful: conversion to bool for truthiness checks
proc to_bool*(v: VMValue): bool =
  ## Convert VMValue to boolean (for truthiness)
  case v.kind
  of vm_null:
    return false
  of vm_bool:
    return v.boolVal
  of vm_int:
    return v.intVal != 0
  of vm_float:
    return v.floatVal != 0.0 and not v.floatVal.isNaN
  of vm_string:
    return v.stringVal.len > 0
  of vm_array:
    return v.arrayVal.len > 0
  of vm_object:
    return v.objectVal.len > 0
  of vmEmpty:
    return false  # empty is falsy like null
  of vmNode:
    # Emptiness would need arena access to tell; treat lazy containers
    # as truthy, like the eager container kinds.
    return true

# Helper constructor functions for cleaner code
proc vm_null*(): VMValue =
  VMValue(kind: vm_null)

proc vm_bool*(b: bool): VMValue =
  VMValue(kind: vm_bool, boolVal: b)

proc vm_int*(i: int64): VMValue =
  VMValue(kind: vm_int, intVal: i)

proc vm_float*(f: float64): VMValue =
  VMValue(kind: vm_float, floatVal: f)

proc vm_string*(s: string): VMValue =
  VMValue(kind: vm_string, stringVal: s)

proc vm_array*(a: seq[VMValue]): VMValue =
  VMValue(kind: vm_array, arrayVal: a)

proc vm_object*(o: OrderedTable[string, VMValue]): VMValue =
  VMValue(kind: vm_object, objectVal: o)

proc vm_object*(o: Table[string, VMValue]): VMValue =
  var ordered = initOrderedTable[string, VMValue]()
  for k, v in o:
    ordered[k] = v
  VMValue(kind: vm_object, objectVal: ordered)
