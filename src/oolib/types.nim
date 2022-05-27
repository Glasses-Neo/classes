import
  std/macros,
  std/sugar


type
  ClassKind* {.pure.} = enum
    Normal
    Inheritance
    Distinct
    Alias
    Implementation

  ClassInfo* = tuple
    isPub: bool
    pragmas: seq[string]
    generics: seq[NimNode]
    kind: ClassKind
    name, base: NimNode

  ClassData* = tuple
    isPub: bool
    name, base: NimNode
    pragmas: seq[string]
    generics: seq[NimNode]
    body, ctorBase, ctorBase2: NimNode
    argList, ignoredArgList, constList: seq[NimNode]

  ClassMembers* = tuple
    body, ctorBase, ctorBase2: NimNode
    argList, ignoredArgList, constList: seq[NimNode]


  ProtocolKind* {.pure.} = enum
    Normal

  ProtocolInfo* = tuple
    isPub: bool
    kind: ProtocolKind
    name: NimNode

  ProtocolMembers* = tuple
    argList, procs, funcs: seq[NimNode]


proc nameWithGenerics*(data: ClassData): NimNode {.compileTime.} =
  ## Return `name[T, U]` if a class has generics.
  result = data.name
  if data.generics != @[]:
    result = nnkBracketExpr.newTree(
      result & data.generics
    )


func allArgList*(data: ClassData): seq[NimNode] {.compileTime.} =
  data.argList & data.ignoredArgList


func withoutDefault*(argList: seq[NimNode]): seq[NimNode] =
  result = collect:
    for v in argList:
      v[^1] = newEmptyNode()
      v
