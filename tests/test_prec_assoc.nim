import unittest
import patty
import strutils
import macros
import std/math
import nimly

## variant is defined in patty
variant MyToken:
  PLUS
  MULTI
  MINUS 
  DIV
  NUM(val: int)
  DOT
  LPAREN
  RPAREN
  IGNORE
  EXPON

niml testLex[MyToken]:
  r"\(":
    return LPAREN()
  r"\)":
    return RPAREN()
  r"\+":
    return PLUS()
  r"-":
    return MINUS()
  r"\*":
    return MULTI()
  r"/":
    return DIV()
  r"\d+":
    return NUM(parseInt(token.token))
  r"^":
    return EXPON()
  r"\s":
    return IGNORE()

nimy testPar[MyToken]:
  %left PLUS MINUS
  %left MULTI 
  %nonassoc UMINUS

  exp[int]:
    NUM:
      return ($1).val
    exp PLUS exp:
      echo $($1) & " + " & $($3)
      return $1 + $3
    exp MINUS exp:
      echo $($1) & " - " & $($3)
      return $1 - $3
    exp MULTI exp:
      echo $($1) & " * " & $($3)
      return $1 * $3
    exp DIV exp:
      echo $($1) & " / " & $($3)
      return $1 div $3
    exp EXPON exp:
      echo $($1) & " ^ " & $($3)
      return int(math.pow(float64($1), float64($3)))
    MINUS exp %prec UMINUS:
      echo "-" & $($2)
      return -($2)

proc calculate(str: string) : int = 
  var
    lexer = testLex.newWithString($str)
  lexer.ignoreIf = proc(r: MyToken): bool = r.kind == MyTokenKind.IGNORE
  var
     parser = testPar.newParser()
  return parser.parse(lexer)

test "top level prec rules":
    # check calculate("20 + 1 * 2") == 22
    # check calculate("20+1*2+30") == 52
    # check calculate("1+2+3+4") == 10 
    # check calculate("1*2*3*4") == 24
    check calculate("1*2+3*4") == 14

test "nonassoc":
    discard

test "rule level prec":
    discard