import tables
import strutils

import patty

import lexer
import parsetypes
import debuginfo
import options
import dev_assert

# TODO would be nice to give user a way to handle parser error, but need more research

proc add(parser: var Parser, s: parsetypes.State) =
  parser.stack.add(s)

proc push(parser: var Parser, s: parsetypes.State) =
  parser.add(s)

proc pop(parser: var Parser): parsetypes.State =
  return parser.stack.pop

proc top(parser: Parser): parsetypes.State =
  return parser.stack[parser.stack.high]

template nextChar() {.dirty.} = 
  token = lexer.lexNext
  case token.kind 
  of Jammed:
    return ErrorNode[T]()
  of Eof:
    symbol = End()
  of Token:
    symbol = TermS(ord(token.token.kind))
    inc tokenCount 


proc parseImpl*[LS,T](parser: var Parser,
                      lexer: var NimlLexer[LS,T]): ParseTree[T] =
  var 
    tree: seq[ParseTree[T]] = @[]
    token: LexerOutput[T]
    symbol: Symbol
    prevErrPos = 0 
    minShiftsToReportError = 0 
    tokenCount = 0 
  nextChar()

  while true:
    when defined(nimytrace):
      echo "\nparser stack:", parser.stack
      echo "read token from lexer: ", token
    var action: ActionTableItem
    
    if symbol notin parser.table.action[parser.top]:
      action = Error()
    else:
      action = parser.table.action[parser.top][symbol]
    
    when defined(nimytrace):
      echo "action: ", action

    case action.kind
    of ActionTableItemKind.Shift:
      dec minShiftsToReportError
      tree.add(Terminal[T](token.token))
      when defined(nimytrace):
        echo "Shifted ", action.state
      nextChar()
      parser.push(action.state)
    of ActionTableItemKind.Reduce:
      let r = action.rule
      let reseted = tree[^r.lenWithoutEmpty..^1]
      for i in 0..<r.lenWithoutEmpty:
        discard parser.pop
        discard tree.pop
      tree.add(NonTerminal[T](r, reseted))
      parser.push(parser.table.goto[parser.top][r.left])
    of ActionTableItemKind.Accept:
      when defined(nimytrace):
        if tree.len == 1:
          echo tree[0]
        else:
          echo tree
      nimyaccAssert tree.len == 1, "Error, parsing result is wrong."
      return NonTerminal[T](rule = Rule(), tree =tree)
    of ActionTableItemKind.Error:
      parser.hasError = true 
      # are we out of luck (tokens)? 
      if symbol == End():
        parser.onEof(lexer.input, tokenCount)
        # we will just return ErrorNode as the parse tree. 
        return ErrorNode[T]()

      if minShiftsToReportError <= 0:
        when defined(nimydevel):
          echo "Parser stack: ", parser.stack
          echo "Last token read: ", token
        doAssert token.kind == Token, "Impl bug"
        parser.onError(lexer.input, token.startPos, token.endPosExcl)

      minShiftsToReportError = 3 
      if tokenCount == prevErrPos:
        # infinite loop detection: for the case when there is 
        # no possible action for the lookahead token we would 
        # be stuck. discarding tokens might help, so we will 
        # do that. this guarantees progress. this works because
        # any shift/reduce action puts something on the stack,
        # and accept would have returned. 
        when defined(nimytrace):
          echo "likely infinite loop detected, same read position in input as previous error, no progress made since last shift of error symbol. discarding the lookahead=", symbol, " to make progress"
        nextChar()
      prevErrPos = tokenCount

      let errSym = ErrorS()

      # pop the stack until we reach state in which the 
      # action for the error token is shift
      # while parser.stack.len > 1 and errSym notin parser.table.action[parser.top]:
      # parser.table.action[parser.top][errSym].kind == Shift means, we can shift the error symbol. 
      while parser.stack.len > 1 and (errSym notin parser.table.action[parser.top] or parser.table.action[parser.top][errSym].kind != ActionTableItemKind.Shift):
        when defined(nimytrace):
          if errSym notin parser.table.action[parser.top]:
            echo "no action for error symbol. discarding stack.top=", parser.top()
          else:
            echo "action for error symbol is not Shift but is ", parser.table.action[parser.top][errSym], ". discarding stack.top=", parser.top()
        discard parser.pop()
        discard tree.pop()

      # we could have error token show up in the initial state
      # so we check if we can shift the error token first. 
      if errSym in parser.table.action[parser.top]:
        # can we shift error symbol? 
        if parser.table.action[parser.top][errSym].kind == ActionTableItemKind.Shift:
          # shift the error symbol
          when defined(nimytrace):
            echo "stack=", parser.stack
            echo "adding ErrorNode to parse tree"
          tree.add(ErrorNode[T]())
          parser.push(parser.table.action[parser.top][errSym].state)
          # skip lookaheads until a state is reached that 
          # has a non-error action on the lookahead
          while symbol != End() and 
            (symbol notin parser.table.action[parser.top] or 
              parser.table.action[parser.top][symbol].kind == ActionTableItemKind.Error):
              when defined(nimytrace):
                echo "discarding lookahead=", token
              nextChar()
          if symbol == End(): # ran out of symbols
            parser.onEof(lexer.input, tokenCount)
            return ErrorNode[T]()
          # either shift some sync token or reduce a rule containing error symbol. 
          # the assumption is we should consume at least 1 lookahead after this. 
          continue
      # it is just a syntax error if we cannot shift the error symbo. don't 
      # to complicate things further say by discarding lookaheads and see if 
      # we can eventually parse something. more sane to bail at this point. 
      return ErrorNode[T]()
        
proc init*(p: var Parser) =
  # annoyingly, "reset" is a built-in proc that sets something to its default state,
  # so we can't name this proc "reset" because if we do the system.reset get called
  # and bad things happen. will keep calling this "init". 
  p.stack = @[0]

func findContext(input:string, startPos, endPosExcl: int) : string = 
  var nspaces = 0
  for i in countdown(startPos-1, 0):
    if input[i] in NewLines:
      for j in countup(i+1,startpos-1):
        result.add input[j]
      nspaces = startpos - (i+1)
      break 
  
  for i in countup(startPos,input.len-1):
    if input[i] notin NewLines: # assume a token can't contain newlines.
      result.add input[i]
      continue
    result.add "\n"
    break 
  
  if nspaces > 0:
    result.add spaces(nspaces)
    result.add "^"

proc defaultOnError(input: string, startPos, endPosExcl: int) = 
  echo "Syntax error detected at startPos=", startPos, " endPosExcl=", endPosExcl
  echo "Context:\n", findContext(input, startPos, endPosExcl)

proc defaultOnEof(input: string, pos: int) = 
  echo "Unexpected eof detected"

proc newParser*(t: ParsingTable, onError: proc (i: string, s,e: int) = defaultOnError, onEof: proc (i:string, p:int) = defaultOnEof): Parser =
  result = Parser(stack: @[0], table: t, provisionalToksCnt: 0, hasError:false, onError: onError, onEof: onEof)
  result.init()

