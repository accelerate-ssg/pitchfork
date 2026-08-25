#
# Generate new section labels using:
# https://patorjk.com/software/taag/#p=display&h=0&v=1&c=bash&f=Georgia11&t=text
#
import std/[times, monotimes, tables]

import types, ../../profiling, lexer/[classify_identifier, matches_at, parse_token, scan_identifier, scan_text, scan_end_tag]

const
  IdentFirstTable2 = 0x07fffffe87fffffe'u64
  IdentContTable1 = 0x03ff200000000000'u64
  IdentContTable2 = 0x07fffffe87fffffe'u64



template add_token(section: var Section, tokenKind: TokenKind, tokStart, tokStop: int) =
  ## Adds a token to a section's token list with zero-allocation token creation.
  ##
  ## This template efficiently constructs tokens using only indices into the
  ## original input string, avoiding any string copies or allocations.
  ##
  ## **Performance:**
  ## - Inlined at compile time
  ## - Single allocation only when growing the sequence
  ## - Tokens use 16-24 bytes each (3 fields)
  ##
  ## **Parameters:**
  ## - `section`: Section to add the token to (modified)
  ## - `tokenKind`: Type of token (tkIdentifier, tkNumber, etc.)
  ## - `tokStart`: Starting position in original input
  ## - `tokStop`: Ending position in original input (exclusive)
  ##
  ## **Examples:**
  ##
  ## ```nim
  ## var section = Section(kind: skTag)
  ## section.tokens = newSeqOfCap[Token](10)
  ## 
  ## # Add an identifier token for "product" at position 5-12
  ## section.add_token(tkIdentifier, 5, 12)
  ## 
  ## # Add an operator token for "==" at position 13-15
  ## section.add_token(tkEq, 13, 15)
  ## 
  ## # Add a number token for "42" at position 16-18
  ## section.add_token(tkNumber, 16, 18)
  ## 
  ## assert section.tokens.len == 3
  ## assert section.tokens[0].kind == tkIdentifier
  ## assert section.tokens[0].start == 5
  ## assert section.tokens[0].stop == 12
  ## ```
  ##
  ## **Usage Pattern:**
  ##
  ## ```nim
  ## # In the lexer's token parsing
  ## let tokStart = pos
  ## scan_identifier(input, pos)
  ## if pos > tokStart:
  ##   section.add_token(classify_identifier(input, tokStart, pos), tokStart, pos)
  ## ```
  section.tokens.add(Token(kind: tokenKind, start: tokStart, stop: tokStop))

template skip_whitespace(input: string, pos: var int) =
  ## Advances position past any whitespace characters.
  ##
  ## Efficiently skips spaces, tabs, carriage returns, and newlines.
  ## Commonly used between tokens in tag and output sections.
  ##
  ## **Performance:**
  ## - Tight loop with good branch prediction
  ## - ~2-3ns per whitespace character
  ## - Zero allocations
  ##
  ## **Parameters:**
  ## - `input`: The string being scanned
  ## - `pos`: Current position (modified to skip past whitespace)
  ##
  ## **Whitespace Characters:**
  ## - Space (` `)
  ## - Tab (`\t`)
  ## - Carriage return (`\r`)
  ## - Newline (`\n`)
  ##
  ## **Examples:**
  ##
  ## ```nim
  ## var text = "  \t\n  hello"
  ## var pos = 0
  ## text.skip_whitespace(pos)
  ## assert pos == 6  # Skipped all whitespace
  ## assert text[pos] == 'h'
  ## 
  ## # No whitespace to skip
  ## text = "hello"
  ## pos = 0
  ## text.skip_whitespace(pos)
  ## assert pos == 0  # Position unchanged
  ## 
  ## # Mixed whitespace
  ## text = " \r\n\t next"
  ## pos = 0
  ## text.skip_whitespace(pos)
  ## assert pos == 5
  ## assert text[pos] == 'n'
  ## 
  ## # At end of string
  ## text = "end   "
  ## pos = 3
  ## text.skip_whitespace(pos)
  ## assert pos == 6  # At end of string
  ## ```
  ##
  ## **Common Usage:**
  ##
  ## ```nim
  ## # In tag parsing
  ## pos += 2  # Skip "{%"
  ## input.skip_whitespace(pos)  # Skip any spaces after {%
  ## 
  ## # Between tokens
  ## parse_token(input, pos, section)
  ## input.skip_whitespace(pos)  # Skip spaces before next token
  ## ```
  while pos < input.len and input[pos] in {' ', '\t', '\r', '\n'}:
    inc pos

proc validate_liquid_block(input: string, sections: seq[Section]) =
  ## A liquid tag's body is its own block body: it may not close a block
  ## opened outside the tag, and whatever it opens it must also close.
  ## Without this an `endif` inside a liquid tag silently closed an `if`
  ## from the surrounding template.
  const openers = {tkIf, tkUnless, tkFor, tkCase, tkCapture}
  const closers = {tkEndif, tkEndunless, tkEndfor, tkEndcase, tkEndcapture,
                   tkEndtablerow, tkEndifchanged}
  var depth = 0
  for section in sections:
    if section.kind != skTag or section.tokens.len == 0:
      continue
    let first = section.tokens[0]
    if first.kind in openers:
      inc depth
    elif first.kind in closers:
      dec depth
    elif first.kind == tkIdentifier:
      # These block tags have no keyword token of their own. comment and
      # raw are only recognised by the outer lexer, so inside a liquid
      # body they arrive here as plain identifiers.
      let name = input[first.start ..< first.stop]
      if name in ["tablerow", "ifchanged", "comment", "raw"]:
        inc depth
      elif name.len > 3 and name[0 .. 2] == "end":
        dec depth
    if depth < 0:
      raise newException(ValueError,
        "liquid tag cannot close a block it did not open")
  if depth != 0:
    raise newException(ValueError,
      "block opened inside a liquid tag was never closed")

proc lex_liquid_block(input: string, startPos: int):
    tuple[sections: seq[Section], endPos: int, stripRight: bool] =
  ## Parses a `{% liquid %}` block where each line is an implicit Liquid tag.
  ##
  ## The liquid tag allows writing multiple Liquid statements without tag delimiters.
  ## Each line inside the block is treated as if it were wrapped in `{% %}` tags,
  ## making templates more readable when they contain many consecutive Liquid statements.
  ##
  ## **Liquid Block Syntax:**
  ## ```liquid
  ## {% liquid
  ##   assign name = "John"
  ##   if name == "John"
  ##     echo "Hello John!"
  ##   endif
  ## %}
  ## ```
  ## Is equivalent to:
  ## ```liquid
  ## {% assign name = "John" %}
  ## {% if name == "John" %}
  ##   {% echo "Hello John!" %}
  ## {% endif %}
  ## ```
  ##
  ## **Performance:**
  ## - Processes ~500M-1B chars/sec for typical liquid blocks
  ## - Line-by-line parsing with minimal overhead
  ## - Echo statements converted to output sections for efficiency
  ##
  ## **Parameters:**
  ## - `input`: The source string containing the liquid block
  ## - `startPos`: Position after "liquid" keyword (typically after the 6th character of `{% liquid`)
  ##
  ## **Returns:**
  ## - `sections`: Sequence of parsed sections (tags and outputs)
  ## - `endPos`: Position after the closing `%}` of the liquid block
  ##
  ## **Special Handling:**
  ## - Empty lines are skipped
  ## - Lines starting with `#` are treated as comments and skipped
  ## - Lines starting with `echo` become output sections (not tags)
  ## - The block ends at a standalone `%}` on its own line
  ##
  ## **Examples:**
  ##
  ## ```nim
  ## # Simple liquid block
  ## let input = """{% liquid
  ##   assign x = 5
  ##   echo x
  ## %}"""
  ## let (sections, endPos) = lex_liquid_block(input, 9)  # Start after "liquid"
  ## assert sections.len == 2
  ## assert sections[0].kind == skTag  # assign statement
  ## assert sections[1].kind == skOutput  # echo converted to output
  ## 
  ## # With comments and empty lines
  ## let input2 = """{% liquid
  ##   # This is a comment
  ##   
  ##   assign y = 10
  ## %}"""
  ## let (sections2, _) = lex_liquid_block(input2, 9)
  ## assert sections2.len == 1  # Comment and empty line skipped
  ## 
  ## # Nested control flow
  ## let input3 = """{% liquid
  ##   for item in items
  ##     if item.active
  ##       echo item.name
  ##     endif
  ##   endfor
  ## %}"""
  ## let (sections3, _) = lex_liquid_block(input3, 9)
  ## assert sections3.len == 5  # for, if, echo, endif, endfor
  ## 
  ## # Early termination on %}
  ## let input4 = """{% liquid
  ##   assign a = 1
  ## %}
  ## This text is outside the liquid block"""
  ## let (sections4, endPos4) = lex_liquid_block(input4, 9)
  ## assert sections4.len == 1
  ## assert input4[endPos4..endPos4+10] == "\nThis text"  # After %}
  ## ```
  ##
  ## **Line Processing Rules:**
  ## 1. Skip leading whitespace on each line
  ## 2. Skip empty lines entirely
  ## 3. Lines starting with `#` are comments (skipped)
  ## 4. Lines starting with `echo` → output section
  ## 5. All other lines → tag section
  ## 6. Stop at standalone `%}` (can be on its own line)
  ##
  ## **Usage in Main Lexer:**
  ##
  ## ```nim
  ## # When encountering {% liquid %} in main lexer
  ## if input.matches_at(pos, "liquid"):
  ##   if pos + 6 >= input.len or input[pos + 6] in {' ', '\t', '\r', '\n', '-', '%'}:
  ##     let (liquidSections, newPos) = lex_liquid_block(input, pos + 6)
  ##     result.add(liquidSections)  # Add all sections from liquid block
  ##     pos = newPos  # Continue from after the liquid block
  ## ```
  ##
  ## **Implementation Notes:**
  ## - Does not create wrapper sections - each line becomes its own section
  ## - Preserves line-by-line structure for better error reporting
  ## - Tokens within lines are parsed using the same parse_token logic
  ## - Handles both UNIX (\n) and Windows (\r\n) line endings
  ## - The closing `%}` can appear on the same line as content or standalone
  var pos = startPos
  result.sections = @[]

  while pos < input.len:
    # Statements are separated by line breaks, and blank lines mean
    # nothing, so leading whitespace of any kind is skipped wholesale.
    while pos < input.len and input[pos] in {' ', '\t', '\r', '\n'}:
      inc pos
    if pos >= input.len:
      break

    # The tag ends here, with or without whitespace control.
    if input.matches_at(pos, "-%}"):
      result.stripRight = true
      result.endPos = pos + 3
      return
    if input.matches_at(pos, "%}"):
      result.endPos = pos + 2
      return

    # A comment statement runs to the end of its line — but never past the
    # closing delimiter, or `{% liquid # note %}` would swallow the rest
    # of the template.
    if input[pos] == '#':
      while pos < input.len and input[pos] notin {'\n', '\r'} and
            not input.matches_at(pos, "%}") and not input.matches_at(pos, "-%}"):
        inc pos
      continue

    # `liquid` is a no-op statement inside a liquid tag, so a body may
    # repeat the keyword: `{% liquid liquid echo "x" %}`.
    if input.matches_at(pos, "liquid") and
        (pos + 6 >= input.len or input[pos + 6] in {' ', '\t', '\r', '\n', '%', '-'}):
      pos += 6
      continue

    let lineStart = pos

    # `echo` produces output; every other statement is an ordinary tag.
    let isEcho = input.matches_at(pos, "echo") and
        (pos + 4 >= input.len or input[pos + 4] in {' ', '\t', '\r', '\n', '%', '-'})
    if isEcho:
      pos += 4

    var section = Section(kind: if isEcho: skOutput else: skTag, start: lineStart)
    section.tokens = newSeqOfCap[Token](if isEcho: 5 else: 10)

    # Consume the rest of the statement. Unlike the surrounding lexer this
    # stops at a line break as well as at the delimiter: the newline is
    # what separates one statement from the next.
    while pos < input.len:
      while pos < input.len and input[pos] in {' ', '\t'}:
        inc pos
      if pos >= input.len:
        break
      # Only a newline separates statements. A lone carriage return does
      # not, so a CR-terminated body is one long malformed statement —
      # which is exactly what the reference implementation rejects.
      if input[pos] == '\n' or
          (input[pos] == '\r' and pos + 1 < input.len and input[pos + 1] == '\n'):
        break
      if input.matches_at(pos, "-%}") or input.matches_at(pos, "%}"):
        break
      if input[pos] == '#':
        # Trailing comment on a statement line.
        while pos < input.len and input[pos] notin {'\n', '\r'} and
              not input.matches_at(pos, "%}") and not input.matches_at(pos, "-%}"):
          inc pos
        break
      let tokenStart = pos
      input.parse_token(pos, input.len, section)
      # parse_token leaves pos alone on a character it does not know; step
      # over it rather than spinning on it forever.
      if pos == tokenStart:
        inc pos

    section.stop = pos
    if section.tokens.len > 0:
      result.sections.add(section)

  # Unterminated: consume the rest of the input rather than handing back a
  # position the caller would loop on.
  result.endPos = input.len






proc lex*(input: string): seq[Section] =
  ## High-performance single-pass lexer for Liquid templates.
  ##
  ## Tokenizes an entire Liquid template in one pass, handling all Liquid
  ## constructs including tags, output sections, comments, and raw blocks.
  ## Achieves 500M-2B characters/second on modern hardware.
  ##
  ## **Performance Characteristics:**
  ## - **Sparse templates** (mostly text): ~1.8B chars/sec
  ## - **Normal templates** (mixed content): ~900M chars/sec
  ## - **Dense templates** (many tags): ~1.0B chars/sec
  ## - Zero intermediate string allocations
  ## - Single-pass scanning with no backtracking
  ## - Optimized for CPU branch prediction
  ##
  ## **Parameters:**
  ## - `input`: The Liquid template string to lex
  ##
  ## **Returns:**
  ## - Sequence of sections, each containing:
  ##   - `kind`: skText, skTag, or skOutput
  ##   - `start`/`stop`: Byte positions in input
  ##   - `tokens`: Parsed tokens (for tag/output sections)
  ##   - `stripLeft`/`stripRight`: Whitespace control flags
  ##
  ## **Liquid Constructs Handled:**
  ##
  ## - **Tags**: `{% if condition %}`, `{% for x in items %}`
  ## - **Output**: `{{ variable }}`, `{{ product.price | money }}`
  ## - **Comments**: `{%# inline comment %}`, `{% comment %}...{% endcomment %}`
  ## - **Raw blocks**: `{% raw %}...{% endraw %}` (content not parsed)
  ## - **Echo tags**: `{% echo var %}` (converted to output sections)
  ## - **Liquid blocks**: `{% liquid ... %}` (multiline Liquid without delimiters)
  ## - **Whitespace control**: `{%- tag -%}`, `{{- output -}}`
  ##
  ## **Examples:**
  ##
  ## ```nim
  ## # Simple template
  ## let sections = lex("Hello {{ name }}!")
  ## assert sections.len == 3
  ## assert sections[0].kind == skText  # "Hello "
  ## assert sections[1].kind == skOutput  # "{{ name }}"
  ## assert sections[2].kind == skText  # "!"
  ## 
  ## # With tags
  ## let sections2 = lex("{% if user %}Hi!{% endif %}")
  ## assert sections2.len == 3
  ## assert sections2[0].kind == skTag  # if tag
  ## assert sections2[1].kind == skText  # "Hi!"
  ## assert sections2[2].kind == skTag  # endif tag
  ## 
  ## # Comments are skipped
  ## let sections3 = lex("{%# comment %}text")
  ## assert sections3.len == 1
  ## assert sections3[0].kind == skText  # Just "text"
  ## 
  ## # Raw blocks preserved as text
  ## let sections4 = lex("{% raw %}{{ not.parsed }}{% endraw %}")
  ## assert sections4.len == 1
  ## assert sections4[0].kind == skText
  ## assert input[sections4[0].start..<sections4[0].stop] == "{{ not.parsed }}"
  ## 
  ## # Whitespace control
  ## let sections5 = lex("text {%- if true -%} more{% endif %}")
  ## assert sections5[1].stripLeft == true
  ## assert sections5[1].stripRight == true
  ## ```
  ##
  ## **Usage Pattern:**
  ##
  ## ```nim
  ## # Typical usage in a template engine
  ## proc compileTemplate(source: string): Template =
  ##   let sections = lex(source)
  ##   
  ##   for section in sections:
  ##     case section.kind
  ##     of skText:
  ##       # Add text directly to output
  ##       result.addText(source[section.start..<section.stop])
  ##     of skTag:
  ##       # Parse and compile tag
  ##       let ast = parseTag(section.tokens, source)
  ##       result.addInstruction(compile(ast))
  ##     of skOutput:
  ##       # Parse and compile output expression
  ##       let expr = parseExpression(section.tokens, source)
  ##       result.addOutput(compile(expr))
  ## ```
  ##
  ## **Implementation Notes:**
  ## - Comments and whitespace are handled during lexing (not passed to parser)
  ## - Raw blocks are returned as single text sections
  ## - Echo tags are converted to output sections for uniform handling
  ## - Incomplete tags at end of input are handled gracefully
  ## - The lexer is resilient to malformed input
  result = newSeqOfCap[Section](input.len div 20)
  var pos = 0
  var section: Section
  
  while pos < input.len:
    if input.matches_at(pos, "{%"):
      # It's a tag {%
      let tagStart = pos
      pos += 2  # Skip {%
      
      # Check for strip left
      var stripLeft = false
      if pos < input.len and input[pos] == '-':
        stripLeft = true
        inc pos
      
      # Skip whitespace
      input.skip_whitespace(pos)
      
      # Check what kind of tag this is
      if pos < input.len and input[pos] == '#':
        #      ,pm                                  ,,                ,,    ,,                                                                                                                                   mq.    
        #     6M   ,M""Yg.    ,M'      ,M' dP       db              `7MM    db                                                                                                         mm        ,M""Yg.    ,M'    Mb   
        #     MM   MY   Mb  ,M'        dP .M'                         MM                                                                                                               MM        MY   Mb  ,M'      MM   
        #     M9   8M. ,M9,M'       mmmMmmMmm     `7MM  `7MMpMMMb.    MM  `7MM  `7MMpMMMb.   .gP"Ya       ,p6"bo   ,pW"Wq.  `7MMpMMMb.pMMMb.  `7MMpMMMb.pMMMb.   .gP"Ya  `7MMpMMMb.  mmMMmm      8M. ,M9,M'        YM   
        #  _.d"'    `""' ,M',;:.      MP dP         MM    MM    MM    MM    MM    MM    MM  ,M'   Yb     6M'  OO  6W'   `Wb   MM    MM    MM    MM    MM    MM  ,M'   Yb   MM    MM    MM         `""' ,M',;:.     `"b._
        #  `"bp.       ,M',MP  Yb  mmdMmmMmmm       MM    MM    MM    MM    MM    MM    MM  8M""""""     8M       8M     M8   MM    MM    MM    MM    MM    MM  8M""""""   MM    MM    MM            ,M',MP  Yb    ,qd"'
        #     Mb     ,M'  `M.  .M:  ,M' dP          MM    MM    MM    MM    MM    MM    MM  YM.    ,     YM.    , YA.   ,A9   MM    MM    MM    MM    MM    MM  YM.    ,   MM    MM    MM          ,M'  `M.  .M:   6M   
        #     MM   ,M'     Ybmmd'   dP ,M'        .JMML..JMML  JMML..JMML..JMML..JMML  JMML. `Mbmmd'      YMbmd'   `Ybmd9'  .JMML  JMML  JMML..JMML  JMML  JMML. `Mbmmd' .JMML  JMML.  `Mbmo     ,M'     Ybmmd'    MM   
        #     YM                                                                                                                                                                                                   M9   
        #      `bm                                                                                                                                                                                               md'    
        profile("inline comment"):
          inc pos  # Skip the #
          # Once the comment spans lines, every further line has to open
          # with its own '#'; a bare continuation line is an error rather
          # than more comment text.
          var lineNeedsHash = false
          while pos < input.len - 1:
            if input.matches_at(pos, "%}"):
              pos += 1
              break
            if input.matches_at(pos, "-%}"):
              pos += 2
              break

            if input[pos] == '\n':
              lineNeedsHash = true
            elif lineNeedsHash and input[pos] notin {' ', '\t', '\r'}:
              if input[pos] != '#':
                raise newException(ValueError,
                  "inline comment tag: every line must start with '#'")
              lineNeedsHash = false

            inc pos
          # Continue to next iteration - inline comments produce no output
          inc pos
        
      elif input.matches_at(pos, "comment"):
        #      ,pm                                                                                                                             mq.    
        #     6M   ,M""Yg.    ,M'                                                                                    mm        ,M""Yg.    ,M'    Mb   
        #     MM   MY   Mb  ,M'                                                                                      MM        MY   Mb  ,M'      MM   
        #     M9   8M. ,M9,M'           ,p6"bo   ,pW"Wq.  `7MMpMMMb.pMMMb.  `7MMpMMMb.pMMMb.   .gP"Ya  `7MMpMMMb.  mmMMmm      8M. ,M9,M'        YM   
        #  _.d"'    `""' ,M',;:.       6M'  OO  6W'   `Wb   MM    MM    MM    MM    MM    MM  ,M'   Yb   MM    MM    MM         `""' ,M',;:.     `"b._
        #  `"bp.       ,M',MP  Yb      8M       8M     M8   MM    MM    MM    MM    MM    MM  8M""""""   MM    MM    MM            ,M',MP  Yb    ,qd"'
        #     Mb     ,M'  `M.  .M:     YM.    , YA.   ,A9   MM    MM    MM    MM    MM    MM  YM.    ,   MM    MM    MM          ,M'  `M.  .M:   6M   
        #     MM   ,M'     Ybmmd'       YMbmd'   `Ybmd9'  .JMML  JMML  JMML..JMML  JMML  JMML. `Mbmmd' .JMML  JMML.  `Mbmo     ,M'     Ybmmd'    MM   
        #     YM                                                                                                                                 M9   
        #      `bm                                                                                                                             md'    
        profile("comment tag"):
          pos += 7  # Skip "comment"

          # Skip the rest of the opening {% comment %} tag
          while pos < input.len - 1:
            if input.matches_at(pos, "-%}"):
              pos += 3
              break
            if input.matches_at(pos, "%}"):
              pos += 2
              break
            inc pos

          # Save position to detect endcomment strip flags
          let commentContentStart = pos

          # Use generic scanner - returns -1 since we don't need content
          discard scan_end_tag(input, pos, "endcomment", false)

          # Detect endcomment strip flags
          var endcommentStripRight = false
          if pos >= 3 and input[pos-3] == '-' and input[pos-2] == '%' and input[pos-1] == '}':
            endcommentStripRight = true

          # If strip flags present, insert zero-length text section to propagate them
          if stripLeft or endcommentStripRight:
            section = Section(kind: skText, start: commentContentStart, stop: commentContentStart,
                             stripLeft: stripLeft, stripRight: endcommentStripRight)
            result.add(section)
        
      elif input.matches_at(pos, "raw"):
        #      ,pm                                                                             mq.    
        #     6M   ,M""Yg.    ,M'                                              ,M""Yg.    ,M'    Mb   
        #     MM   MY   Mb  ,M'                                                MY   Mb  ,M'      MM   
        #     M9   8M. ,M9,M'          `7Mb,od8  ,6"Yb.  `7M'    ,A    `MF'    8M. ,M9,M'        YM   
        #  _.d"'    `""' ,M',;:.         MM' "' 8)   MM    VA   ,VAA   ,V       `""' ,M',;:.     `"b._
        #  `"bp.       ,M',MP  Yb        MM      ,pm9MM     VA ,V  VA ,V           ,M',MP  Yb    ,qd"'
        #     Mb     ,M'  `M.  .M:       MM     8M   MM      VVV    VVV          ,M'  `M.  .M:   6M   
        #     MM   ,M'     Ybmmd'      .JMML.   `Moo9^Yo.     W      W         ,M'     Ybmmd'    MM   
        #     YM                                                                                 M9   
        #      `bm                                                                             md'    
        profile("raw tag"):
          pos += 3  # Skip "raw"

          # Skip the rest of the opening tag, detect stripRight on opening tag
          var rawOpenStripRight = false
          while pos < input.len - 1:
            if input.matches_at(pos, "-%}"):
              rawOpenStripRight = true
              pos += 3
              break
            if input.matches_at(pos, "%}"):
              pos += 2
              break
            inc pos

          # Get content until {% endraw %}
          var rawStart = pos
          let savedPos = pos
          let rawEnd = scan_end_tag(input, pos, "endraw", true)

          # Detect endraw strip flags by scanning the endraw tag
          var endrawStripLeft = false
          var endrawStripRight = false
          if rawEnd < input.len:
            # Check if {%- was used for endraw
            if rawEnd >= 3 and input[rawEnd] == '{' and input[rawEnd+1] == '%' and input[rawEnd+2] == '-':
              endrawStripLeft = true
            elif rawEnd >= 2 and input[rawEnd] == '{' and input[rawEnd+1] == '%':
              endrawStripLeft = false
            # Check if -%} was used at the end (pos is now past the endraw tag)
            if pos >= 3 and input[pos-3] == '-' and input[pos-2] == '%' and input[pos-1] == '}':
              endrawStripRight = true

          # Apply internal stripping to raw content range
          var actualStart = rawStart
          var actualEnd = rawEnd
          if rawOpenStripRight and actualStart < actualEnd:
            while actualStart < actualEnd and input[actualStart] in {' ', '\t', '\r', '\n'}:
              inc actualStart
          if endrawStripLeft and actualStart < actualEnd:
            while actualEnd > actualStart and input[actualEnd - 1] in {' ', '\t', '\r', '\n'}:
              dec actualEnd

          # Add the raw content as text if not empty
          if actualEnd > actualStart:
            section = Section(kind: skText, start: actualStart, stop: actualEnd,
                             stripLeft: stripLeft, stripRight: endrawStripRight)
            result.add(section)
          elif stripLeft or endrawStripRight:
            # Even if raw content is empty, propagate strip flags via a zero-length text section
            section = Section(kind: skText, start: actualStart, stop: actualStart,
                             stripLeft: stripLeft, stripRight: endrawStripRight)
            result.add(section)
      
      elif input.matches_at(pos, "liquid") and
          (pos + 6 >= input.len or input[pos + 6] in {' ', '\t', '\r', '\n', '-', '%'}):
        #      ,pm                       ,,    ,,                           ,,         ,,                      mq.    
        #     6M   ,M""Yg.    ,M'      `7MM    db                           db       `7MM      ,M""Yg.    ,M'    Mb   
        #     MM   MY   Mb  ,M'          MM                                            MM      MY   Mb  ,M'      MM   
        #     M9   8M. ,M9,M'            MM  `7MM    ,dW"Yvd  `7MM  `7MM  `7MM    ,M""bMM      8M. ,M9,M'        YM   
        #  _.d"'    `""' ,M',;:.         MM    MM   ,W'   MM    MM    MM    MM  ,AP    MM       `""' ,M',;:.     `"b._
        #  `"bp.       ,M',MP  Yb        MM    MM   8M    MM    MM    MM    MM  8MI    MM          ,M',MP  Yb    ,qd"'
        #     Mb     ,M'  `M.  .M:       MM    MM   YA.   MM    MM    MM    MM  `Mb    MM        ,M'  `M.  .M:   6M   
        #     MM   ,M'     Ybmmd'      .JMML..JMML.  `MbmdMM    `Mbod"YML..JMML. `Wbmd"MML.    ,M'     Ybmmd'    MM   
        #     YM                                          MM                                                     M9   
        #      `bm                                      .JMML.                                                 md'    
        profile("liquid tag"):
          var (liquidSections, newPos, blockStripRight) = lex_liquid_block(input, pos + 6)
          validate_liquid_block(input, liquidSections)
          # Whitespace control belongs to the tag as a whole, but sections
          # are what carry it: the first statement takes the opening {%-
          # and the last takes the closing -%}. A body of nothing but
          # comments produces no statements, so an empty text section
          # stands in to keep trimming the text around the tag.
          if liquidSections.len == 0:
            liquidSections.add(Section(kind: skText, start: tagStart, stop: tagStart,
                                       stripLeft: stripLeft, stripRight: blockStripRight))
          else:
            liquidSections[0].stripLeft = stripLeft
            liquidSections[^1].stripRight = blockStripRight
          result.add(liquidSections)
          pos = newPos
      
      elif pos + 4 <= input.len and input.matches_at(pos, "echo"):
        #      ,pm                                         ,,                                      mq.    
        #     6M   ,M""Yg.    ,M'                        `7MM                      ,M""Yg.    ,M'    Mb   
        #     MM   MY   Mb  ,M'                            MM                      MY   Mb  ,M'      MM   
        #     M9   8M. ,M9,M'           .gP"Ya   ,p6"bo    MMpMMMb.   ,pW"Wq.      8M. ,M9,M'        YM   
        #  _.d"'    `""' ,M',;:.       ,M'   Yb 6M'  OO    MM    MM  6W'   `Wb      `""' ,M',;:.     `"b._
        #  `"bp.       ,M',MP  Yb      8M"""""" 8M         MM    MM  8M     M8         ,M',MP  Yb    ,qd"'
        #     Mb     ,M'  `M.  .M:     YM.    , YM.    ,   MM    MM  YA.   ,A9       ,M'  `M.  .M:   6M   
        #     MM   ,M'     Ybmmd'       `Mbmmd'  YMbmd'  .JMML  JMML. `Ybmd9'      ,M'     Ybmmd'    MM   
        #     YM                                                                                     M9   
        #      `bm                                                                                 md'    
        profile("echo tag"):
          section = Section(kind: skOutput, start: tagStart)
          section.stripLeft = stripLeft
          section.tokens = newSeqOfCap[Token](5)
          
          pos += 4  # Skip "echo"
          
          # Parse the expression
          while pos < input.len - 1:
            # Skip whitespace
            input.skip_whitespace(pos)
            
            if pos >= input.len - 1:
              break
            
            # Check for comment
            if input[pos] == '#':
              # Skip to end of tag
              while pos < input.len - 1:
                if input.matches_at(pos, "%}"):
                  pos += 2
                  break
                  
                if input.matches_at(pos, "-%}"):
                  section.stripRight = true
                  pos += 3
                  break
                inc pos
              break
            
            # Check for end of tag
            if input[pos] == '%' and pos + 1 < input.len and input[pos + 1] == '}':
              pos += 2
              break
            if input[pos] == '-' and pos + 2 < input.len and 
                input[pos + 1] == '%' and input[pos + 2] == '}':
              section.stripRight = true
              pos += 3
              break
            
            # Parse token
            parse_token(input, pos, input.len, section)
          
          section.stop = pos
          result.add(section)
      
      else:
        #      ,pm                                                                    mq.    
        #     6M   ,M""Yg.    ,M'        mm                           ,M""Yg.    ,M'    Mb   
        #     MM   MY   Mb  ,M'          MM                           MY   Mb  ,M'      MM   
        #     M9   8M. ,M9,M'          mmMMmm   ,6"Yb.   .P"Ybmmm     8M. ,M9,M'        YM   
        #  _.d"'    `""' ,M',;:.         MM    8)   MM  :MI  I8        `""' ,M',;:.     `"b._
        #  `"bp.       ,M',MP  Yb        MM     ,pm9MM   WmmmP"           ,M',MP  Yb    ,qd"'
        #     Mb     ,M'  `M.  .M:       MM    8M   MM  8M              ,M'  `M.  .M:   6M   
        #     MM   ,M'     Ybmmd'        `Mbmo `Moo9^Yo. YMMMMMb      ,M'     Ybmmd'    MM   
        #     YM                                        6'     dP                       M9   
        #      `bm                                      Ybmmmd'                       md'    
        profile("tag"):
          section = Section(kind: skTag, start: tagStart)
          section.stripLeft = stripLeft
          section.tokens = newSeqOfCap[Token](10)
          
          # Parse tokens
          while pos < input.len:  # Changed: was input.len - 1
            # Skip whitespace
            input.skip_whitespace(pos)
            
            if pos >= input.len:  # Changed: was input.len - 1
              break
            
            # Check for comment
            if input[pos] == '#':
              # Skip to end of tag
              while pos < input.len:  # Changed: was input.len - 1
                if input.matches_at(pos, "%}"):
                  pos += 2
                  break
                if input.matches_at(pos, "-%}"):
                  section.stripRight = true
                  pos += 3
                  break
                inc pos
              break
            
            # Check for end of tag - only if we have enough chars left
            if pos < input.len - 1 and input[pos] == '%' and input[pos + 1] == '}':
              pos += 2
              break
            if pos < input.len - 2 and input[pos] == '-' and 
                input[pos + 1] == '%' and input[pos + 2] == '}':
              section.stripRight = true
              pos += 3
              break
            
            # Parse token
            parse_token(input, pos, input.len, section)
          
          # Ensure incomplete tags consume everything
          if pos >= input.len:
            pos = input.len  # Make sure we've consumed all input
          
          section.stop = pos
          result.add(section)
    
    elif input.matches_at(pos, "{{"):
      #      ,pm     ,pm                                                                      mq.    mq.    
      #     6M      6M                               mm                             mm          Mb     Mb   
      #     MM      MM                               MM                             MM          MM     MM   
      #     M9      M9        ,pW"Wq.  `7MM  `7MM  mmMMmm  `7MMpdMAo. `7MM  `7MM  mmMMmm        YM     YM   
      #  _.d"'   _.d"'       6W'   `Wb   MM    MM    MM      MM   `Wb   MM    MM    MM          `"b._  `"b._
      #  `"bp.   `"bp.       8M     M8   MM    MM    MM      MM    M8   MM    MM    MM          ,qd"'  ,qd"'
      #     Mb      Mb       YA.   ,A9   MM    MM    MM      MM   ,AP   MM    MM    MM          6M     6M   
      #     MM      MM        `Ybmd9'    `Mbod"YML.  `Mbmo   MMbmmd'    `Mbod"YML.  `Mbmo       MM     MM   
      #     YM      YM                                       MM                                 M9     M9   
      #      `bm     `bm                                   .JMML.                             md'    md'    
      profile("output"):
        section = Section(kind: skOutput, start: pos)
        section.tokens = newSeqOfCap[Token](5)
        
        pos += 2  # Skip {{
        
        # Check for strip left
        section.stripLeft = pos < input.len and input[pos] == '-'
        if section.stripLeft: inc pos
        
        # Parse tokens
        while pos < input.len - 1:
          # Skip whitespace
          input.skip_whitespace(pos)
          
          if pos >= input.len - 1:
            break
          
          # Check for comment
          if input[pos] == '#':
            # Skip to end
            while pos < input.len - 1:
              if input.matches_at(pos, "}}"):
                pos += 2
                break
              if input.matches_at(pos, "-}}"):
                section.stripRight = true
                pos += 3
                break
              inc pos
            break
          
          # Check for end
          if input.matches_at(pos, "}}"):
            pos += 2
            break
          if input.matches_at(pos, "-}}"):
            section.stripRight = true
            pos += 3
            break
          
          # Parse token
          parse_token(input, pos, input.len, section)
        
        section.stop = pos
        result.add(section)
    else:
      #
      #    mm                          mm    
      #    MM                          MM    
      #  mmMMmm   .gP"Ya  `7M'   `MF'mmMMmm  
      #    MM    ,M'   Yb   `VA ,V'    MM    
      #    MM    8M""""""     XMX      MM    
      #    MM    YM.    ,   ,V' VA.    MM    
      #    `Mbmo  `Mbmmd' .AM.   .MA.  `Mbmo 
      #
      #
      profile("text"):
        let start = pos
        
        scan_text(input, pos)  # Try different versions
        
        # Create text section up to (but not including) the tag
        if pos > start:
          section = Section(kind: skText, start: start, stop: pos)
          result.add(section)

when isMainModule:
  import std/[unittest, sequtils, sugar]

  suite "Basic section lexing":
    test "Single text section":
      let input = "This is just text."
      let sections = lex(input)
      check sections.len == 1
      check sections[0].kind == skText
      check sections[0].start == 0
      check sections[0].stop == input.len

    test "Single output section":
      let input = "{{ product.name }}"
      let sections = lex(input)
      check sections.len == 1
      check sections[0].kind == skOutput
      check sections[0].start == 0
      check sections[0].stop == input.len
      let tokens = sections[0].tokens
      check tokens.len == 3
      check tokens[0].kind == tkIdentifier
      check tokens[1].kind == tkDot
      check tokens[2].kind == tkIdentifier

    test "Single tag section":
      let input = "{% for product in products %}"
      let sections = lex(input)
      check sections.len == 1
      check sections[0].kind == skTag
      check sections[0].start == 0
      check sections[0].stop == input.len
      let tokens = sections[0].tokens
      check tokens.len == 4
      check tokens[0].kind == tkFor
      check tokens[1].kind == tkIdentifier
      check tokens[2].kind == tkIn
      check tokens[3].kind == tkIdentifier

  suite "Mixed content":
    test "Text then output":
      let input = "Hello {{ name }}"
      let sections = lex(input)
      check sections.len == 2
      check sections[0].kind == skText
      check input[sections[0].start..<sections[0].stop] == "Hello "
      check sections[1].kind == skOutput
      check sections[1].tokens.len == 1
      check sections[1].tokens[0].kind == tkIdentifier

    test "Output then text":
      let input = "{{ greeting }} world"
      let sections = lex(input)
      check sections.len == 2
      check sections[0].kind == skOutput
      check sections[0].tokens.len == 1
      check sections[1].kind == skText
      check input[sections[1].start..<sections[1].stop] == " world"

    test "Text, output, text":
      let input = "Hello {{ name }}, how are you?"
      let sections = lex(input)
      check sections.len == 3
      check sections[0].kind == skText
      check sections[1].kind == skOutput
      check sections[2].kind == skText
      check input[sections[2].start..<sections[2].stop] == ", how are you?"

    test "Tag between text":
      let input = "Start {% if true %} middle {% endif %} end"
      let sections = lex(input)
      check sections.len == 5
      check sections[0].kind == skText
      check sections[1].kind == skTag
      check sections[2].kind == skText
      check sections[3].kind == skTag
      check sections[4].kind == skText

  suite "Comment handling":
    test "Inline comment only":
      let input = "{%# This should be skipped %}"
      let sections = lex(input)
      check sections.len == 0  # Should be completely skipped

    test "Inline comment with surrounding text":
      let input = "Before {%# comment %} After"
      let sections = lex(input)
      check sections.len == 2
      check sections[0].kind == skText
      check input[sections[0].start..<sections[0].stop] == "Before "
      check sections[1].kind == skText
      check input[sections[1].start..<sections[1].stop] == " After"

    test "Comment in output":
      let input = "{{ name # this is ignored }}"
      let sections = lex(input)
      check sections.len == 1
      check sections[0].kind == skOutput
      check sections[0].tokens.len == 1  # Only 'name', comment ignored
      check sections[0].tokens[0].kind == tkIdentifier

    test "Comment in tag":
      let input = "{% assign x = 5 # comment %}"
      let sections = lex(input)
      check sections.len == 1
      check sections[0].kind == skTag
      check sections[0].tokens.len == 4  # assign, x, =, 5 (no comment)

    test "Inline comment over multiple lines":
      let input = "{%-\n  # spread inline comments\n  # over multiple lines\n-%}"
      check lex(input).len == 0

    test "Inline comment continuation lines must each start with a hash":
      let input = "{%-\n  # spread inline comments\n  over multiple lines\n-%}"
      expect ValueError:
        discard lex(input)

    test "Comment block":
      let input = "{% comment %}This is ignored{% endcomment %}"
      let sections = lex(input)
      check sections.len == 0  # Entire block should be skipped

    test "Comment block with surrounding text":
      let input = "Before{% comment %}ignored{% endcomment %}After"
      let sections = lex(input)
      check sections.len == 2
      check sections[0].kind == skText
      check input[sections[0].start..<sections[0].stop] == "Before"
      check sections[1].kind == skText
      check input[sections[1].start..<sections[1].stop] == "After"

  suite "Raw block handling":
    test "Raw block only":
      let input = "{% raw %}{{ not.parsed }}{% endraw %}"
      let sections = lex(input)
      check sections.len == 1
      check sections[0].kind == skText
      check input[sections[0].start..<sections[0].stop] == "{{ not.parsed }}"

    test "Raw block with surrounding":
      let input = "Before{% raw %}{{ raw }}{% endraw %}After"
      let sections = lex(input)
      check sections.len == 3
      check sections[0].kind == skText
      check input[sections[0].start..<sections[0].stop] == "Before"
      check sections[1].kind == skText
      check input[sections[1].start..<sections[1].stop] == "{{ raw }}"
      check sections[2].kind == skText
      check input[sections[2].start..<sections[2].stop] == "After"

  suite "Echo tag handling":
    test "Echo tag as output":
      let input = "{% echo product.price %}"
      let sections = lex(input)
      check sections.len == 1
      check sections[0].kind == skOutput  # Should be output, not tag
      check sections[0].tokens.len == 3  # product, dot, price

  suite "Liquid tag handling":
    test "One statement per line":
      let input = "{% liquid\n  assign a = 1\n  echo a\n%}"
      let sections = lex(input)
      check sections.len == 2
      check sections[0].kind == skTag
      check sections[0].tokens[0].kind == tkAssignTag
      check sections[1].kind == skOutput  # echo becomes output
      check sections[1].tokens.len == 1

    test "Statements may share the opening line":
      let input = "{% liquid echo 'a' %}"
      let sections = lex(input)
      check sections.len == 1
      check sections[0].kind == skOutput

    test "Comment lines produce no section":
      let input = "{% liquid\n  # a note\n  echo 'a'\n%}"
      let sections = lex(input)
      check sections.len == 1
      check sections[0].kind == skOutput

    test "A comment does not run past the closing delimiter":
      let input = "{% liquid # a note %}after"
      let sections = lex(input)
      check sections.len == 2
      check sections[1].kind == skText
      check input[sections[1].start..<sections[1].stop] == "after"

    test "Whitespace control lands on the first and last statement":
      let input = "{%- liquid\n  echo 'a'\n  echo 'b'\n-%}"
      let sections = lex(input)
      check sections.len == 2
      check sections[0].stripLeft == true
      check sections[0].stripRight == false
      check sections[1].stripLeft == false
      check sections[1].stripRight == true

    test "A body of only comments still carries whitespace control":
      let input = "{%- liquid\n  # nothing but a note\n-%}"
      let sections = lex(input)
      check sections.len == 1
      check sections[0].kind == skText
      check sections[0].start == sections[0].stop  # emits no text
      check sections[0].stripLeft == true
      check sections[0].stripRight == true

    test "A repeated liquid keyword is a no-op":
      let input = "{%- liquid liquid liquid echo \"foo\" -%}"
      let sections = lex(input)
      check sections.len == 1
      check sections[0].kind == skOutput
      check sections[0].stripLeft == true
      check sections[0].stripRight == true

    test "CRLF separates statements":
      let input = "{% liquid\r\n  echo 'a'\r\n  echo 'b'\r\n%}"
      let sections = lex(input)
      check sections.len == 2
      check sections.allIt(it.kind == skOutput)

    test "A lone carriage return does not separate statements":
      # The whole body reads as one malformed statement, which opens an
      # `if` that is never closed.
      let input = "{% liquid\rif a\r  echo a\rendif\r%}"
      expect ValueError:
        discard lex(input)

    test "Cannot close a block it did not open":
      expect ValueError:
        discard lex("{% if true %}42{% liquid endif %}")

    test "Cannot leave a block it opened unclosed":
      expect ValueError:
        discard lex("{% liquid if true\n  echo 'a'\n%}")

    test "A comment block inside the body stays balanced":
      let input = "{% liquid\ncomment a note\nendcomment\n%}"
      check lex(input).len == 2  # comment + endcomment, both inert tags

    test "An unterminated block consumes the rest of the input":
      let input = "{% liquid\n  echo 'a'"
      let sections = lex(input)
      check sections.len == 1
      check sections[0].kind == skOutput

    test "A tag merely starting with 'liquid' is not a liquid tag":
      let input = "{% liquidate 5 %}"
      let sections = lex(input)
      check sections.len == 1
      check sections[0].kind == skTag
      check sections[0].tokens[0].kind == tkIdentifier

  suite "Whitespace control":
    test "Strip left in tag":
      let input = "{%- if true %}"
      let sections = lex(input)
      check sections.len == 1
      check sections[0].stripLeft == true
      check sections[0].stripRight == false

    test "Strip right in tag":
      let input = "{% if true -%}"
      let sections = lex(input)
      check sections.len == 1
      check sections[0].stripLeft == false
      check sections[0].stripRight == true

    test "Strip both in output":
      let input = "{{- name -}}"
      let sections = lex(input)
      check sections.len == 1
      check sections[0].stripLeft == true
      check sections[0].stripRight == true

  suite "Edge cases":
    test "Empty input":
      let input = ""
      let sections = lex(input)
      check sections.len == 0

    test "Just whitespace":
      let input = "   \n\t  "
      let sections = lex(input)
      check sections.len == 1
      check sections[0].kind == skText

    test "Incomplete tag":
      let input = "{% assign x = "
      let sections = lex(input)


      # Debug output
      for i, s in sections:
        echo "Section ", i, ": kind=", s.kind, " start=", s.start, " stop=", s.stop
        if s.stop <= input.len:
          echo "  Content: '", input[s.start..<s.stop], "'"

      # Should handle gracefully, likely as incomplete tag
      check sections.len == 1

    test "Single opening brace":
      let input = "Just a { brace"
      let sections = lex(input)
      check sections.len == 1
      check sections[0].kind == skText
      check input[sections[0].start..<sections[0].stop] == "Just a { brace"

    test "Double brace but not tag":
      let input = "{ { not a tag } }"
      let sections = lex(input)
      check sections.len == 1
      check sections[0].kind == skText

  suite "Complex token parsing":
    test "Numbers in tags":
      let input = "{% assign x = 42.5 %}"
      let sections = lex(input)
      check sections[0].tokens.len == 4
      check sections[0].tokens[3].kind == tkNumber
      check input[sections[0].tokens[3].start..<sections[0].tokens[3].stop] == "42.5"

    test "Strings in output":
      let input = "{{ 'hello world' }}"
      let sections = lex(input)
      check sections[0].tokens.len == 1
      check sections[0].tokens[0].kind == tkString

    test "Filters with colons":
      let input = "{{ product | filter: 'value' }}"
      let sections = lex(input)
      check sections[0].tokens.len == 5
      check sections[0].tokens[1].kind == tkPipe
      check sections[0].tokens[3].kind == tkColon

    test "Array access":
      let input = "{{ items[0] }}"
      let sections = lex(input)
      let tokens = sections[0].tokens
      check tokens.len == 4
      check tokens[1].kind == tkLeftBracket
      check tokens[2].kind == tkNumber
      check tokens[3].kind == tkRightBracket

    test "Range operator":
      let input = "{% for i in (1..10) %}"
      let sections = lex(input)
      let tokens = sections[0].tokens
      # Should have: for, i, in, (, 1, .., 10, )
      check tokens.len == 8
      check tokens[5].kind == tkDoubleDot

  suite "Identifier scanning":
    test "@ prefix identifier":
      let input = "{{ @foo }}"
      let sections = lex(input)
      check sections[0].tokens.len == 1
      check sections[0].tokens[0].kind == tkIdentifier
      check input[sections[0].tokens[0].start..<sections[0].tokens[0].stop] == "@foo"

    test "Trailing ? identifier":
      let input = "{{ empty? }}"
      let sections = lex(input)
      check sections[0].tokens.len == 1
      check sections[0].tokens[0].kind == tkIdentifier
      check input[sections[0].tokens[0].start..<sections[0].tokens[0].stop] == "empty?"

    test "@ prefix not followed by letter":
      let input = "{{ @123 }}"
      let sections = lex(input)
      # @ alone is not a valid identifier start, should not produce @123
      # The @ gets skipped and 123 is a number
      check sections[0].tokens.len == 1
      check sections[0].tokens[0].kind == tkNumber

  suite "Consecutive sections":
    test "Multiple outputs in a row":
      let input = "{{ a }}{{ b }}{{ c }}"
      let sections = lex(input)
      check sections.len == 3
      check sections.all(s => s.kind == skOutput)

    test "Multiple tags in a row":
      let input = "{% if a %}{% if b %}{% endif %}{% endif %}"
      let sections = lex(input)
      check sections.len == 4
      check sections.all(s => s.kind == skTag)

    test "Alternating tags and outputs":
      let input = "{{ a }}{% if b %}{{ c }}{% endif %}"
      let sections = lex(input)
      check sections.len == 4
      check sections[0].kind == skOutput
      check sections[1].kind == skTag
      check sections[2].kind == skOutput
      check sections[3].kind == skTag

  suite "Performance benchmark": 
    test "100 000 iterations, sparse template":
      let iterations = 100_000
      let start = getMonoTime()
      var sections: seq[Section]
      let file = open("test/templates/calculator.liquid", fmRead)
      let templ = readAll(file)
      file.close()
      
      for i in 0..<iterations:
        sections = lex(templ)

      let elapsed = getMonoTime() - start
      let seconds = elapsed.inNanoseconds.float / 1_000_000_000.0
      let charsPerSec = (templ.len * iterations).float / seconds
      
      echo "\nChars/sec: ", charsPerSec / 1_000_000.0, "M"
      echo "No sections: ", sections.len

    test "100 000 iterations, normal template":
      let iterations = 100_000
      let start = getMonoTime()
      var sections: seq[Section]
      let file = open("test/templates/article.liquid", fmRead)
      let templ = readAll(file)
      file.close()
      
      for i in 0..<iterations:
        sections = lex(templ)

      let elapsed = getMonoTime() - start
      let seconds = elapsed.inNanoseconds.float / 1_000_000_000.0
      let charsPerSec = (templ.len * iterations).float / seconds
      
      echo "\nChars/sec: ", charsPerSec / 1_000_000.0, "M"
      echo "No sections: ", sections.len

    test "100 000 iterations, dense template":
      let iterations = 100_000
      let start = getMonoTime()
      var sections: seq[Section]
      let file = open("test/templates/menu.liquid", fmRead)
      let templ = readAll(file)
      file.close()
      
      for i in 0..<iterations:
        sections = lex(templ)

      let elapsed = getMonoTime() - start
      let seconds = elapsed.inNanoseconds.float / 1_000_000_000.0
      let charsPerSec = (templ.len * iterations).float / seconds
      
      echo "\nChars/sec: ", charsPerSec / 1_000_000.0, "M"
      echo "No sections: ", sections.len
    
    when defined(profile):
      printProfilingReport()
