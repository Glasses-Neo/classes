discard """
  action: "compile"
"""

import
  ../src/oolib

protocol pub IA:
  var v: string
  proc wow
  proc f(v1: int, v2: int): int

class A impl IA:
  var v = ""
  proc wow =
    echo "wow"

  proc f(v1, v2: int): int =
    result = v1 + v2

  proc f2 {.used.} =
    echo "f2"

let a = A.new("aa")

let _ = a.toProtocol()
