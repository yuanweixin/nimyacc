import tables
import sets
import hashes

import patty

import parsetypes
import parser
import slr
import std/options

type
  LALRItem[T] = object
    rule: Rule[T]
    pos: int
    ahead: Symbol[T]
  LALRItems[T] = HashSet[LALRItem[T]]
  SetOfLALRItems[T] = OrderedTable[int, LALRItems[T]]
  PropagateTable[T] = Table[LRItem[T], HashSet[(int, LRItem[T])]]

proc initLALRItems[T](): LALRItems[T] =
  result = initHashSet[LALRItem[T]]()

proc initHashSetOfLALRItems[T](): SetOfLALRItems[T] =
  result = initOrderedTable[int, LALRItems[T]]()

proc initPropagateTable[T](): PropagateTable[T] =
  result = initTable[LRItem[T], HashSet[(int, LRItem[T])]]()

proc `$`*[T](x: LALRItems[T]) : string = 
  for i in x:
    result.add i.rule.left.nonTerm
    result.add " -> "
    for r in i.rule.right:
      case r.kind
      of SymbolKind.TermS:
        result.add $r.term
        result.add " "
      of SymbolKind.NonTermS:
        result.add $r.nonTerm
        result.add " "
      of SymbolKind.Dummy:
        result.add "# "
      of SymbolKind.End:
        result.add "$"
      of SymbolKind.Empty:
        result.add "epsilon "
    if i.rule.prec.isSome:
      result.add " prec "
      result.add $i.rule.prec.get
    result.add " ahead: "

    case i.ahead.kind
    of SymbolKind.End:
      result.add "$ "
    of SymbolKind.TermS:
      result.add $i.ahead.term
      result.add " "
    else:
      discard
    result.add " pos " 
    result.add $i.pos
    result.add "\n"

proc hash*[T](x: LALRItem[T]): Hash =
  var h: Hash = 0
  h = h !& hash(x.rule)
  h = h !& hash(x.pos)
  h = h !& hash(x.ahead)
  return !$h

proc next[T](i: LALRItem[T]): Symbol[T] =
  if i.pos >= i.rule.len:
    return End[T]()
  result = i.rule.right[i.pos]

proc nextSkipEmpty[T](i: LALRItem[T]): Symbol[T] =
  result = End[T]()
  for idx in i.pos..<i.rule.len:
    let nxt = i.rule.right[idx]
    if nxt != Empty[T]():
      result = nxt
      break

proc fromNextNext[T](i: LALRItem[T]): seq[Symbol[T]] =
  result = @[]
  doAssert i.pos < i.rule.len
  for index in (i.pos + 1)..<i.rule.len:
    result.add(i.rule.right[index])

proc closure[T](g: Grammar[T], whole: LALRItems[T]): LALRItems[T] =
  result = whole
  var checkSet = whole
  while checkSet.len > 0:
    var new: LALRItems[T]
    for i in checkSet:
      match i.next:
        NonTermS:
          for r in g.filterRulesLeftIs(i.next):
            doAssert i.ahead.kind != SymbolKind.Empty, "Lookahead is EMPTY (epsilon)"
            for fst in g.calFirsts(i.fromNextNext & i.ahead):
              # for each terminal b in FIRST(βa), dragonbook fig. 4.40
              if fst.kind == SymbolKind.Empty:
                continue 
              let n = LALRItem[T](rule: r, pos: 0, ahead: fst)
              if not result.containsOrIncl(n):
                new.incl(n)
        _:
          discard
    checkSet = new

proc closure[T](g: Grammar[T], single: LALRItem[T]): LALRItems[T] =
  result = g.closure([single].toHashSet)

proc toLALRItem[T](lrItem: LRItem[T], ahead: Symbol[T]): LALRItem[T] =
  result = LALRItem[T](rule: lrItem.rule, pos: lrItem.pos, ahead: ahead)

proc toLRItem[T](lalrItem: LALRItem[T]): LRItem[T] =
  result = LRItem[T](rule: lalrItem.rule, pos: lalrItem.pos)

proc `[]`[T](pt: PropagateTable[T],
             itm: LALRItem[T]): HashSet[(int, LRItem[T])] =
  result = pt[LRItem[T](rule: itm.rule, pos: itm.pos)]

proc incl[T](ot: var OrderedTable[int, T], vl: T) =
  ot[ot.len] = vl

proc forward[T](itm: LALRItem[T]): LALRItem[T] =
  result = LALRItem[T](rule: itm.rule, pos: itm.pos + 1, ahead: itm.ahead)

proc firstItem[T](os: OrderedSet[T]): T =
  for i in os:
    return i

proc getItemIfSingle[T](s: HashSet[T]): T =
  if s.card == 1:
    for i in s:
      return i
  raise newException(NimyError, "Unexpected: " & $s & " needs to be single.")

## Same as Dragonbook Argorithm 4.62 & 4.63
proc toLALRKernel[T](lrKernel: SetOfLRItems[T], g: Grammar[T],
                     tt: TransTable[T]): SetOfLALRItems[T] =
  # init result
  result = initHashSetOfLALRItems[T]()
  doAssert lrKernel.card > 0
  for idx in 0..<lrKernel.card:
    result.incl(initLALRItems[T]())
  var
    propagation: PropagateTable[T] = initPropagateTable[T]()
    checkSet: HashSet[LALRItem[T]] = initLALRItems[T]()

  # only starting rule
  let startingRule = lrKernel.firstItem.getItemIfSingle
  result[0].incl(startingRule.toLALRItem(End[T]()))
  checkSet.incl(startingRule.toLALRItem(End[T]()))

  # init collection and cal propagate
  for idx, itms in lrKernel:
    when defined(nimydebug):
      echo "[nimly] converting kernel: " & $(idx + 1) & "/" & $lrKernel.len
    for itm in itms:
      if not (propagation.haskey(itm)):
        propagation[itm] = initHashSet[(int, LRItem[T])]()

      # Dummy is "#" in dragonbook
      let clsr = g.closure(itm.toLALRItem(Dummy[T]()))
      for ci in clsr:
        if ci.ahead == Dummy[T]():
          if ci.next != End[T]():
            propagation[itm] = (propagation[itm] +
                                [(tt[idx][ci.next],
                                  ci.forward.toLRItem)].toHashSet)
        else:
          let prpgtd = ci.forward
          assert tt[idx][ci.next] < lrKernel.card
          result[tt[idx][ci.next]].incl(prpgtd)
          checkSet.incl(prpgtd)

  # cal collection
  while checkSet.card > 0:
    var newSet = initLALRItems[T]()
    for itm in checkSet:
      # propagation[itm] where itm is a LALRItem works because we 
      # snuck in a `[]` proc above, very sneaky and confusing. 
      for toInfo in propagation[itm]: 
        let
          (idx, toItm) = toInfo
          new = toItm.toLALRItem(itm.ahead)
        if not (result[idx].containsOrIncl(new)):
          newSet.incl(new)
    checkSet = newSet

proc makeTableLALR*[T](g: Grammar[T]): ParsingTable[T] =
  var
    actionTable: ActionTable[T]
    gotoTable: GotoTable[T]
  actionTable = initTable[State, ActionRow[T]]()
  gotoTable = initTable[State, GotoRow[T]]()
  when defined(nimydebug):
    echo "[nimly] start: make table for parser"
  let
    ag = if g.isAugment:
           g
         else:
           g.augment
    (cc, tt) = makeCanonicalCollection[T](ag)
    knl = cc.filterKernel
    lalrKnl = knl.toLALRKernel(ag, tt)
  when defined(nimydebug):
    echo "[nimly] done: make lalrkernel"
  for idx, itms in lalrKnl:
    when defined(nimydebug):
      echo "[nimly] processing: Collection " & $(idx + 1) & "/" & $lalrKnl.len
    actionTable[idx] = initTable[Symbol[T], ActionTableItem[T]]()
    gotoTable[idx] = initTable[Symbol[T], State]()
    when defined(nimydebug):
      echo "[nimly] processing: Collection " & $(idx + 1) & " - make closure"
    let clsr = ag.closure(itms)
    var cnt = 1
    for itm in clsr:
      when defined(nimydebug):
        echo "[nimly] processing: Collection " & $(idx + 1) & " - " &
          $cnt & "/" & $clsr.card
      inc(cnt)
      let sym = itm.nextSkipEmpty
      match sym:
        TermS:
          if actionTable[idx].haskey(sym) and
              actionTable[idx][sym].kind == ActionTableItemKind.Reduce:
            actionTable[idx][sym] = resolveShiftReduceConflict(actionTable[idx][sym].rule, sym.term, g, tt[idx][sym])
            when defined(nimyDebug):
              echo "LALR:Shift-Reduce CONFLICT!!!" & $idx & ":" & $sym 
              echo "Resolved in favor of " & $actionTable[idx][sym]
          elif actionTable[idx].haskey(sym) and
              actionTable[idx][sym].kind == ActionTableItemKind.Error:
            continue 
          else:
            actionTable[idx][sym] = Shift[T](tt[idx][sym])
        NonTermS:
          gotoTable[idx][sym] = tt[idx][sym]
        End:
          if itm.rule.left == ag.start:
            actionTable[idx][End[T]()] = Accept[T]()
          else:
            if actionTable[idx].haskey(itm.ahead) and
               actionTable[idx][itm.ahead].kind == ActionTableItemKind.Shift:
              actionTable[idx][itm.ahead] = resolveShiftReduceConflict(itm.rule, 
              itm.ahead.term, g, actionTable[idx][itm.ahead].state)
              when defined(nimydebug):
                echo "LALR:Shift-Reduce CONFLICT!!!" & $idx & ":" & $itm.ahead
                echo "Conflict resolved in favor of " & $actionTable[idx][itm.ahead]
            elif actionTable[idx].haskey(itm.ahead) and
               actionTable[idx][itm.ahead].kind == ActionTableItemKind.Reduce: 
              echo "LALR:Reduce-Reduce CONFLICT!!!" & $idx & ":" & $itm.ahead & ".  This usually indicates a serious error in the grammar. It could also be due to the LALR table compression, where multiple reducible rules are placed into the same parser state and there is insufficient context to distinguish them. A possible solution is to add a bogus token to one of the rules to force it into a distinct parser state. Another possible solution is to rewrite the grammar rules to reduce ambiguity." 
              continue
            elif actionTable[idx].haskey(itm.ahead) and
               actionTable[idx][itm.ahead].kind == ActionTableItemKind.Error:
              continue
            else:
              actionTable[idx][itm.ahead] = Reduce[T](itm.rule)
        _:
          discard
  when defined(nimydebug):
    echo "[nimly] done: make tables"
  result = ParsingTable[T](action: actionTable, goto: gotoTable)
  when defined(nimydebug):
    echo "LALR:"
    echo result
