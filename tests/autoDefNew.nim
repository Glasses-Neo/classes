discard """
  action: "run"
"""
import unittest
import ../src/classes

class A:
  var
    a: int = 4
    b: string = "default"


class B:
  var
    c: string
    d: bool = true


let
  a1 = newA()
  a2 = newA(1)
  a3 = newA(b = "a")

  b1 = newB("cc")
  b2 = newB("cc", false)

check a1.a == 4 and a1.b == "default"
check a2.a == 1
check a3.b == "a"

check b1.c == "cc" and b1.d
check not b2.d
