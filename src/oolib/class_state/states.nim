import
  std/macros,
  std/sequtils,
  std/sugar,
  std/strformat,
  .. / util,
  .. / types,
  .. / tmpl,
  state_interface

type
  NormalState* = ref object
    data: ClassData

  InheritanceState* = ref object
    data: ClassData

  DistinctState* = ref object
    data: ClassData

  AliasState* = ref object
    data: ClassData

  ImplementationState* = ref object
    data: ClassData

template generateNewState(t) =
  proc new*(_: typedesc[t], info: ClassInfo): t {.compileTime.} =
    return t(
      data: (
        isPub: info.isPub,
        name: info.name,
        base: info.base,
        pragmas: info.pragmas,
        generics: info.generics,
        body: newStmtList(),
        constructor: newEmptyNode(),
        argList: @[],
        ignoredArgList: @[],
        initialArgList: @[],
        constList: @[]
      )
    )

template generateToInterface(t) =
  proc toInterface*(self: t): IState {.compileTime.} =
    result = (
      data: self.data,
      getClassData:
      proc(body: NimNode) = self.getClassData(body),
      defClass:
      () => self.defClass(),
      defConstructor:
      (theClass: NimNode) => self.defConstructor(theClass),
      defMemberVars:
      (theClass: NimNode) => self.defMemberVars(theClass),
      defMemberRoutines:
      (theClass: NimNode) => self.defMemberRoutines(theClass),
      defBody:
      (theClass: NimNode) => self.defBody(theClass)
    )

func hasAsterisk(node: NimNode): bool {.compileTime.} =
  node.kind == nnkPostfix and node[0].eqIdent"*"

func removeDefault(v: NimNode): NimNode {.compileTime.} =
  v[^1] = newEmptyNode()
  return v

proc removeAsteriskFromIdent(def: NimNode): NimNode {.compileTime.} =
  result = nnkIdentDefs.newNimNode()
  for v in def[0..^3]:
    result.add if v.hasAsterisk: v[1]
      else: v
  result.add(def[^2], def[^1])

proc removeAsteriskFromProc(theProc: NimNode): NimNode {.compileTime.} =
  result = theProc
  result[0] = if theProc[0].hasAsterisk: theProc[0][1] else: theProc[0]

proc removePragmasFromIdent(def: NimNode): NimNode {.compileTime.} =
  result = nnkIdentDefs.newNimNode()
  for v in def[0..^3]:
    result.add if v.kind == nnkPragmaExpr: v[0]
      else: v
  result.add(def[^2], def[^1])

proc simplifyIdentDefs(def: NimNode): NimNode {.compileTime.} =
  result = def.removePragmasFromIdent().removeAsteriskFromIdent()

func toRecList(s: seq[NimNode]): NimNode {.compileTime.} =
  result = nnkRecList.newNimNode()
  for def in s:
    result.add def

proc genConstant(data: ClassData, node: NimNode): NimNode {.compileTime.} =
  ## Generates both a template for use with typedesc and a method for dynamic dispatch.
  result = newStmtList(
    # template
    nnkTemplateDef.newTree(
      node[0],
      newEmptyNode(),
      newEmptyNode(),
      nnkFormalParams.newTree(
        ident"untyped",
        newIdentDefs(
          ident"self",
          nnkBracketExpr.newTree(
            ident"typedesc",
            data.name
      ),
      newEmptyNode()
    )
      ),
      newEmptyNode(),
      newEmptyNode(),
      newStmtList node[^1]
    ),
    # method
    nnkMethodDef.newTree(
      node[0],
      newEmptyNode(),
      newEmptyNode(),
      nnkFormalParams.newTree(
        node[1],
        newIdentDefs(
          ident"self",
          data.name,
          newEmptyNode(),
      )
    ),
      nnkPragma.newTree ident"optBase",
      newEmptyNode(),
      newStmtList nnkReturnStmt.newTree(node[^1])
    ),
  )

func decomposeIdentDefs(defs: NimNode): seq[NimNode] {.compileTime.} =
  result = collect:
    for v in defs[0..^3]:
      newIdentDefs(v, defs[^2], defs[^1])

func hasDefault(node: NimNode): bool {.compileTime.} =
  ## `node` has to be `nnkIdentDefs` or `nnkConstDef`.
  node.expectKind {nnkIdentDefs, nnkConstDef}
  not (node.last.kind == nnkEmpty)

func inferValType(node: NimNode) {.compileTime.} =
  ## Infers type from default if a type annotation is empty.
  ## `node` has to be `nnkIdentDefs` or `nnkConstDef`.
  node.expectKind {nnkIdentDefs, nnkConstDef}
  node[^2] = node[^2] or newCall(ident"typeof", node[^1])

func inferArgType(
    v: NimNode;
    argList: seq[NimNode]
): NimNode {.compileTime.} =
  result = newIdentDefs(v, newEmptyNode())
  for def in argList.map(simplifyIdentDefs):
    for arg in def[0..^3]:
      if v == arg:
        result[^2] = def[^2]
        return

func inferArgTypes(data: ClassData): seq[NimNode] {.compileTime.} =
  for def in data.constructor.params[1..^1]:
    if newEmptyNode() notin def[^2..^1]:
      result.add def
      continue
    for v in def[0..^3]:
      result.add v.inferArgType(data.argList&data.ignoredArgList)

func inferConstructorArgTypes(data: ClassData) {.compileTime.} =
  ## Infers types of constructor arguments.
  data.constructor.params = nnkFormalParams.newTree(
    newEmptyNode() &
    data.inferArgTypes()
  )

func insertBody(
    data: ClassData
) {.compileTime.} =
  let args = (data.argList&data.ignoredArgList).filter(hasDefault).map(simplifyIdentDefs)
  if data.constructor.body[0].kind == nnkDiscardStmt:
    return
  data.constructor.body.insert(
    0,
    newVarStmt(ident"self", newCall data.nameWithGenerics)
  )
  for v in args.mapIt(it[0]):
    data.constructor.body.insert 1, quote do: self.`v` = `v`
  for def in data.initialArgList.map(simplifyIdentDefs):
    let
      v = def[0]
      initial = def[^1]
    data.constructor.body.insert 1, quote do: self.`v` = `initial`
  data.constructor.body.add quote do: result = self

proc insertArgs(constructor: NimNode, vars: seq[NimNode]) {.compileTime.} =
  ## Inserts `vars` to constructor args.
  for v in vars:
    constructor.params.add v

proc addSignatures(
    data: ClassData
) {.compileTime.} =
  ## Adds signatures to `data.constructor`.
  let args = (data.argList&data.ignoredArgList).filter(hasDefault).map(simplifyIdentDefs)
  data.constructor.name = ident"new"
  if data.isPub:
    markWithPostfix(data.constructor.name)
  data.constructor.params[0] = data.nameWithGenerics
  data.constructor.insertArgs(args)
  data.constructor.params.insert 1, newIdentDefs(
    ident"_",
    nnkBracketExpr.newTree(
      ident"typedesc",
      data.nameWithGenerics
    )
  )

func rmSelf(theProc: NimNode): NimNode {.compileTime.} =
  ## Removes `self: typeName` from the 1st of theProc.params.
  result = theProc.copy
  result.params.del(idx = 1)

func newVarsColonExpr(v: NimNode): NimNode {.compileTime.} =
  newColonExpr(v, newDotExpr(ident"self", v))

func newLambdaColonExpr(theProc: NimNode): NimNode {.compileTime.} =
  ## Generates `name: proc() = self.name()`.
  let lambdaProc = theProc.removeAsteriskFromProc().rmSelf()
  let name = lambdaProc.name
  lambdaProc.name = newEmptyNode()
  lambdaProc.body = newDotExpr(ident"self", name).newCall(
    lambdaProc.params[1..^1].mapIt(it[0])
  )
  result = newColonExpr(name, lambdaProc)

func isSuperFunc(node: NimNode): bool {.compileTime.} =
  ## Returns whether struct is `super.f()` or not.
  node.kind == nnkCall and
  node[0].kind == nnkDotExpr and
  node[0][0].eqIdent"super"

proc replaceSuper(node: NimNode): NimNode =
  ## Replaces `super.f()` with `procCall Base(self).f()`.
  result = node
  if node.isSuperFunc:
    return newTree(
      nnkCommand,
      ident "procCall",
      copyNimTree(node)
    )
  for i, n in node:
    result[i] = n.replaceSuper()

proc genNewBody(
    typeName: NimNode;
    vars, initialVars: seq[NimNode]
): NimNode {.compileTime.} =
  result = newStmtList(newVarStmt(ident"self", newCall typeName))
  for v in vars.mapIt(it[0]):
    result.insert 1, quote do:
      self.`v` = `v`
  for def in initialVars:
    let
      v = def[0]
      initial = def[^1]
    result.insert 1, quote do:
      self.`v` = `initial`
  result.add quote do: result = self

proc defNew(data: var ClassData) =
  let args = (data.argList&data.ignoredArgList).map(simplifyIdentDefs)
  let
    name = ident"new"
    params = data.nameWithGenerics&(
      newIdentDefs(
        ident"_",
        nnkBracketExpr.newTree(ident"typedesc", data.nameWithGenerics)
      )&args
    )
    body = genNewBody(
      data.nameWithGenerics,
      args,
      data.initialArgList.map(simplifyIdentDefs)
    )
  data.constructor = newProc(name, params, body)
  if data.isPub:
    markWithPostfix(data.constructor.name)

proc defNewWithBase(
    data: ClassData
) {.compileTime.} =
  ## Adds signatures and insert body to `constructor`.
  data.addSignatures()
  data.insertBody()

func addNoSideEffectPragma(theProc: NimNode) {.compileTime.} =
  ## Adds `noSideEffect` pragma to theProc.
  theProc.expectKind nnkProcDef
  if theProc[4].kind == nnkEmpty:
    theProc[4] = nnkPragma.newTree(
      ident"noSideEffect"
    )
  else:
    theProc[4].add ident"noSideEffect"

func convertFuncToProcWithPragma(theFunc: NimNode): NimNode {.compileTime.} =
  ## Converts `func f()` to `proc f() {.noSideEffect.}`.
  theFunc.expectKind nnkFuncDef
  result = nnkProcDef.newNimNode()
  theFunc.copyChildrenTo result
  result.addNoSideEffectPragma()

func isConstructor(node: NimNode): bool {.compileTime.} =
  ## `node` has to be `nnkProcDef`.
  node.expectKind {nnkProcDef, nnkMethodDef}
  node[0].kind == nnkAccQuoted and node.name.eqIdent"new"

func hasPragma(node: NimNode): bool {.compileTime.} =
  ## `node` has to be `nnkIdentDefs or nnkConstDef`.
  node.expectKind {nnkIdentDefs, nnkConstDef}
  node[0].kind == nnkPragmaExpr

func newSuperStmt(baseName: NimNode): NimNode {.compileTime.} =
  ## Generates `var super = Base(self)`.
  newVarStmt ident"super", newCall(baseName, ident "self")

func insertSuperStmt(theProc, baseName: NimNode): NimNode {.compileTime.} =
  ## Inserts `var super = Base(self)` in the 1st line of `theProc.body`.
  result = theProc
  result.body.insert 0, newSuperStmt(baseName)

proc getClassData(
  self: NormalState;
  body: NimNode;
) {.compileTime.} =
  for node in body:
    case node.kind
    of nnkVarSection:
      for n in node:
        if "noNewDef" in self.data.pragmas and n.hasDefault:
          error "default values cannot be used with {.noNewDef.}", n
        if self.data.generics.anyIt(it.eqIdent n[^2]):
          error "A member variable with generic type is not supported for now"
        if n.hasPragma and "ignored" in n[0][1]:
          error "{.ignored.} pragma cannot be used in non-implemented classes"
        n.inferValType()
        for d in n.decomposeIdentDefs():
          if d.hasPragma and "initial" in d[0][1]:
            self.data.initialArgList.add d
          else:
            self.data.argList.add d
    of nnkConstSection:
      for n in node:
        if not n.hasDefault:
          error "A constant must have a value", node
        if self.data.generics.anyIt(it.eqIdent n):
          error "A constant with generic type cannot be used"
        n.inferValType()
        for d in n.decomposeIdentDefs():
          if d.hasPragma and "initial" in d[0][1]:
            error "{.initial.} pragma cannot be used with constant", d
          else:
            self.data.constList.add d
    of nnkProcDef:
      if node.isConstructor:
        if self.data.constructor.kind == nnkEmpty:
          self.data.constructor = node.copy()
        else:
          error "Constructor already exists", node
      else:
        self.data.body.add node.insertSelf(self.data.nameWithGenerics)
    of nnkMethodDef, nnkFuncDef, nnkIteratorDef, nnkConverterDef, nnkTemplateDef:
      self.data.body.add node.insertSelf(self.data.nameWithGenerics)
    else:
      discard

proc defClass(
    self: NormalState;
): NimNode {.compileTime.} =
  result = getAst defObj(self.data.name)
  if self.data.generics != @[]:
    result[0][1] = nnkGenericParams.newTree(
      nnkIdentDefs.newTree(
        self.data.generics & newEmptyNode() & newEmptyNode()
      )
    )
  if self.data.isPub:
    markWithPostfix(result[0][0])
  if "open" in self.data.pragmas:
    result[0][2][0][1] = nnkOfInherit.newTree ident"RootObj"
  newPragmaExpr(result[0][0], "pClass")

proc defConstructor(
    self: NormalState;
    theClass: NimNode;
) {.compileTime.} =
  if "noNewDef" in self.data.pragmas:
    return
  if self.data.constructor.kind == nnkEmpty:
    self.data.defNew()
    if self.data.generics.len != 0:
      self.data.constructor.params[0] = self.data.nameWithGenerics
      self.data.constructor.params[1] = newIdentDefs(
        ident"_",
        nnkBracketExpr.newTree(ident"typedesc", self.data.nameWithGenerics)
      )
      self.data.constructor[2] = nnkGenericParams.newTree(
        nnkIdentDefs.newTree(
          self.data.generics & newEmptyNode() & newEmptyNode()
        )
      )
  else:
    self.data.inferConstructorArgTypes()
    if self.data.generics.len != 0:
      self.data.constructor[2] = nnkGenericParams.newTree(
        nnkIdentDefs.newTree(self.data.generics & newEmptyNode() & newEmptyNode())
      )
    self.data.defNewWithBase()
  theClass.insert(
    1,
    self.data.constructor
  )

proc defMemberVars(
    self: NormalState;
    theClass: NimNode;
) {.compileTime.} =
  theClass[0][0][2][0][2] = self.data.allArgList.map(removeDefault).toRecList()

proc defMemberRoutines(
    self: NormalState;
    theClass: NimNode;
) {.compileTime.} =
  theClass.add self.data.body.copy()
  for c in self.data.constList:
    theClass.insert 1, self.data.genConstant(c)

proc defBody(
    self: NormalState;
    theClass: NimNode;
) {.compileTime.} =
  self.defConstructor(theClass)
  self.defMemberVars(theClass)
  self.defMemberRoutines(theClass)

proc getClassData(
  self: InheritanceState;
  body: NimNode;
) {.compileTime.} =
  for node in body:
    case node.kind
    of nnkVarSection:
      for n in node:
        if "noNewDef" in self.data.pragmas and n.hasDefault:
          error "default values cannot be used with {.noNewDef.}", n
        if n.hasPragma and "ignored" in n[0][1]:
          error "{.ignored.} pragma cannot be used in non-implemented classes"
        n.inferValType()
        for d in n.decomposeIdentDefs():
          if d.hasPragma and "initial" in d[0][1]:
            self.data.initialArgList.add d
          else:
            self.data.argList.add d
    of nnkConstSection:
      for n in node:
        if not n.hasDefault:
          error "A constant must have a value", node
        n.inferValType()
        for d in n.decomposeIdentDefs():
          if d.hasPragma and "initial" in d[0][1]:
            error "{.initial.} pragma cannot be used with constant", d
          else:
            self.data.constList.add d
    of nnkProcDef:
      if node.isConstructor:
        if self.data.constructor.kind == nnkEmpty:
          self.data.constructor = node
            .replaceSuper()
            .insertSuperStmt(self.data.base)
        else:
          error "Constructor already exists", node
      else:
        self.data.body.add node.insertSelf(self.data.name)
    of nnkMethodDef:
      if node.isConstructor:
        if self.data.constructor.kind == nnkEmpty:
          self.data.constructor = node
            .replaceSuper()
            .insertSuperStmt(self.data.base)
        else:
          error "Constructor already exists", node
      else:
        node.body = replaceSuper(node.body)
        self.data.body.add node.insertSelf(self.data.name).insertSuperStmt(self.data.base)
    of nnkFuncDef, nnkIteratorDef, nnkConverterDef, nnkTemplateDef:
      self.data.body.add node.insertSelf(self.data.name)
    else:
      discard

proc defClass(
    self: InheritanceState;
): NimNode {.compileTime.} =
  result = getAst defObjWithBase(self.data.name, self.data.base)
  if self.data.isPub:
    markWithPostfix(result[0][0])
  newPragmaExpr(result[0][0], "pClass")

proc defConstructor(
    self: InheritanceState;
    theClass: NimNode;
) {.compileTime.} =
  if not (
    self.data.constructor.kind == nnkEmpty or "noNewDef" in self.data.pragmas
  ):
    self.data.defNewWithBase()
    theClass.insert 1, self.data.constructor

proc defMemberVars(
    self: InheritanceState;
    theClass: NimNode;
) {.compileTime.} =
  theClass[0][0][2][0][2] = self.data.argList.map(removeDefault).toRecList()

proc defMemberRoutines(
    self: InheritanceState;
    theClass: NimNode;
) {.compileTime.} =
  theClass.add self.data.body.copy()
  for c in self.data.constList:
    theClass.insert 1, self.data.genConstant(c)

proc defBody(
    self: InheritanceState;
    theClass: NimNode;
) {.compileTime.} =
  self.defConstructor(theClass)
  self.defMemberVars(theClass)
  self.defMemberRoutines(theClass)

proc getClassData(
  self: DistinctState;
  body: NimNode;
) {.compileTime.} =
  self.data.body = newStmtList()
  for node in body:
    case node.kind
    of nnkVarSection:
      error "Distinct type cannot have variables", node
    of nnkConstSection:
      for n in node:
        if not n.hasDefault:
          error "A constant must have a value", node
        n.inferValType()
        for d in n.decomposeIdentDefs():
          if d.hasPragma and "initial" in d[0][1]:
            error "{.initial.} pragma cannot be used with constant", d
          else:
            self.data.constList.add d
    of nnkProcDef, nnkMethodDef, nnkFuncDef, nnkIteratorDef, nnkConverterDef, nnkTemplateDef:
      self.data.body.add node.insertSelf(self.data.name)
    else:
      discard

proc defClass(
    self: DistinctState;
): NimNode {.compileTime.} =
  result = getAst defDistinct(self.data.name, self.data.base)
  if self.data.isPub:
    markWithPostfix(result[0][0][0])
  if "open" in self.data.pragmas:
    # replace {.final.} with {.inheritable.}
    result[0][0][1][0] = ident "inheritable"
    result[0][0][1].add ident "pClass"

proc defConstructor(
    self: DistinctState;
    theClass: NimNode;
) {.compileTime.} =
  discard

proc defMemberVars(
    self: DistinctState;
    theClass: NimNode;
) {.compileTime.} =
  discard

proc defMemberRoutines(
    self: DistinctState;
    theClass: NimNode;
) {.compileTime.} =
  theClass.add self.data.body.copy()
  for c in self.data.constList:
    theClass.insert 1, self.data.genConstant(c)

proc defBody(
    self: DistinctState;
    theClass: NimNode;
) {.compileTime.} =
  self.defConstructor(theClass)
  self.defMemberVars(theClass)
  self.defMemberRoutines(theClass)

proc getClassData(
  self: AliasState;
  body: NimNode;
) {.compileTime.} =
  for node in body:
    case node.kind
    of nnkVarSection:
      if self.data.base.repr != "tuple":
        error "Type alias cannot have variables", node
      for n in node:
        if "noNewDef" in self.data.pragmas and n.hasDefault:
          error "default values cannot be used with {.noNewDef.}", n
        if n.hasPragma and "ignored" in n[0][1]:
          error "{.ignored.} pragma cannot be used in non-implemented classes"
        n.inferValType()
        for d in n.decomposeIdentDefs():
          if d.hasPragma and "initial" in d[0][1]:
            self.data.initialArgList.add d
          else:
            self.data.argList.add d
    of nnkConstSection:
      for n in node:
        if not n.hasDefault:
          error "A constant must have a value", node
        n.inferValType()
        for d in n.decomposeIdentDefs():
          if d.hasPragma and "initial" in d[0][1]:
            error "{.initial.} pragma cannot be used with constant", d
          else:
            self.data.constList.add d
    of nnkProcDef:
      if self.data.base.eqIdent"tuple" and node.isConstructor:
        if self.data.constructor.kind == nnkEmpty:
          self.data.constructor = node.copy()
        else:
          error "Constructor already exists", node
      else:
        self.data.body.add node.insertSelf(self.data.name)
    of nnkMethodDef, nnkFuncDef, nnkIteratorDef, nnkConverterDef, nnkTemplateDef:
      self.data.body.add node.insertSelf(self.data.name)
    else:
      discard

proc defClass(
    self: AliasState;
): NimNode {.compileTime.} =
  result = getAst defAlias(self.data.name, self.data.base)
  if self.data.isPub:
    markWithPostfix(result[0][0])
  newPragmaExpr(result[0][0], "pClass")

proc defConstructor(
    self: AliasState;
    theClass: NimNode;
) {.compileTime.} =
  discard

proc defMemberVars(
    self: AliasState;
    theClass: NimNode;
) {.compileTime.} =
  if self.data.argList.len != 0:
    theClass[0][0][2] = nnkTupleTy.newTree(
      self.data.argList.map(removeDefault)
    )

proc defMemberRoutines(
    self: AliasState;
    theClass: NimNode;
) {.compileTime.} =
  theClass.add self.data.body.copy()
  for c in self.data.constList:
    theClass.insert 1, self.data.genConstant(c)

proc defBody(
    self: AliasState;
    theClass: NimNode;
) {.compileTime.} =
  self.defConstructor(theClass)
  self.defMemberVars(theClass)
  self.defMemberRoutines(theClass)

proc getClassData(
  self: ImplementationState;
  body: NimNode;
) {.compileTime.} =
  for node in body:
    case node.kind
    of nnkVarSection:
      for n in node:
        if "noNewDef" in self.data.pragmas and n.hasDefault:
          error "default values cannot be used with {.noNewDef.}", n
        n.inferValType()
        for d in n.decomposeIdentDefs():
          if d.hasPragma:
            if "initial" in d[0][1]:
              self.data.initialArgList.add d
            elif "ignored" in d[0][1]:
              self.data.ignoredArgList.add d
            else:
              self.data.argList.add d
          else:
            self.data.argList.add d
    of nnkConstSection:
      for n in node:
        if not n.hasDefault:
          error "A constant must have a value", node
        n.inferValType()
        for d in n.decomposeIdentDefs():
          if d.hasPragma and "initial" in d[0][1]:
            error "{.initial.} pragma cannot be used with constant", d
          else:
            self.data.constList.add d
    of nnkProcDef:
      if node.isConstructor:
        if self.data.constructor.kind == nnkEmpty:
          self.data.constructor = node.copy()
        else:
          error "Constructor already exists", node
      else:
        self.data.body.add node.insertSelf(self.data.name)
    of nnkFuncDef:
      self.data.body.add node.insertSelf(
          self.data.name).convertFuncToProcWithPragma()
    of nnkMethodDef, nnkIteratorDef, nnkConverterDef, nnkTemplateDef:
      self.data.body.add node.insertSelf(self.data.name)
    else:
      discard

proc defClass(
    self: ImplementationState;
): NimNode {.compileTime.} =
  result = getAst defObj(self.data.name)
  if self.data.isPub:
    markWithPostfix(result[0][0])
  newPragmaExpr(result[0][0], "pClass")

proc defConstructor(
    self: ImplementationState;
    theClass: NimNode;
) {.compileTime.} =
  if "noNewDef" in self.data.pragmas:
    return
  if self.data.constructor.kind == nnkEmpty:
    self.data.defNew()
  else:
    self.data.inferConstructorArgTypes()
    self.data.defNewWithBase()
  theClass.insert(
    1,
    self.data.constructor
  )

proc defMemberVars(
    self: ImplementationState;
    theClass: NimNode;
) {.compileTime.} =
  theClass[0][0][2][0][2] =
    (self.data.argList&self.data.ignoredArgList).map(removeDefault).toRecList()

proc defMemberRoutines(
    self: ImplementationState;
    theClass: NimNode;
) {.compileTime.} =
  theClass.add self.data.body.copy()
  for c in self.data.constList:
    theClass.insert 1, self.data.genConstant(c)
  let interfaceProc = newProc(
    ident"toInterface",
    [self.data.base],
    newStmtList(
      nnkReturnStmt.newNimNode.add(
        nnkTupleConstr.newNimNode.add(
          self.data.argList.map(removeAsteriskFromIdent).mapIt(it[
              0].newVarsColonExpr)
      ).add(
        self.data.body.filterIt(
          it.kind == nnkProcDef and "ignored" notin it[4]
        ).map(newLambdaColonExpr)
      )
    )
    )
  ).insertSelf(self.data.name)
  let compileProc = interfaceProc.copy
  if self.data.isPub:
    markWithPostfix(interfaceProc.name)
  for p in self.data.body.filterIt(it.kind == nnkProcDef and "ignored" notin it[4]):
    var
      propertyNode = newDotExpr(self.data.base, p.name)
      errorStatement = newStrLitNode fmt"property `{p.name.strVal}` is not in the definition of {self.data.base.strVal}"
    theClass.add quote do:
      when not compiles(`propertyNode`):
        {.error: `errorStatement`.}
  theClass.add quote do:
    when compiles(`compileProc`):
      `interfaceProc`
    else:
      {.error: "Something went wrong".}

proc defBody(
    self: ImplementationState;
    theClass: NimNode;
) {.compileTime.} =
  self.defConstructor(theClass)
  self.defMemberVars(theClass)
  self.defMemberRoutines(theClass)

generateNewState NormalState
generateNewState InheritanceState
generateNewState DistinctState
generateNewState AliasState
generateNewState ImplementationState

generateToInterface NormalState
generateToInterface InheritanceState
generateToInterface DistinctState
generateToInterface AliasState
generateToInterface ImplementationState

proc newState*(info: ClassInfo): IState {.compileTime.} =
  result = case info.kind
    of ClassKind.Normal: NormalState.new(info).toInterface()
    of ClassKind.Inheritance: InheritanceState.new(info).toInterface()
    of ClassKind.Distinct: DistinctState.new(info).toInterface()
    of ClassKind.Alias: AliasState.new(info).toInterface()
    of ClassKind.Implementation: ImplementationState.new(info).toInterface()
