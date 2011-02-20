module ast.fold;

import ast.base, tools.base: and;

Itr fold(Itr i) {
  if (!i) return null;
  auto cur = i;
  while (true) {
    auto start = cur;
    Expr e1;
    debug e1 = fastcast!(Expr)~ start;
    foreach (dg; foldopt) {
      if (auto res = dg(cur)) cur = res;
      // logln("TEST ", (fastcast!(Object)~ cur.valueType()).classinfo.name, " != ", (fastcast!(Object)~ start.valueType()).classinfo.name, ": ", cur.valueType() != start.valueType());
      debug {
        auto e2 = fastcast!(Expr)~ cur;
        if (e1 && e2 && e1.valueType() != e2.valueType()) {
          throw new Exception(Format("Fold has violated type consistency: ", start, " => ", cur));
        }
      }
    }
    if (cur is start) break;
  }
  return cur;
}

Expr foldex(Expr ex) {
  if (!ex) return null;
  auto cur = ex;
  while (true) {
    auto start = cur;
    IType oldtype;
    debug oldtype = start.valueType();
    foreach (dg; _foldopt_expr) {
      if (auto res = dg(cur)) cur = res;
    }
    if (cur is start) break;
    IType nutype;
    debug {
      nutype = cur.valueType();
      if (nutype != oldtype || oldtype != nutype) {
        logln("Invalid replacement: ", oldtype, " -> ", nutype, "!");
        asm { int 3; }
      }
    }
  }
  return cur;
}

Statement optst(Statement st) {
  if (!st) return null;
  opt(st);
  return st;
}

void opt(T)(ref T t) {
  void fun(ref Itr it) {
    if (auto ex = fastcast!(Expr)~ it) {
      ex = foldex(ex);
      it = cast(Itr) ex;
    } else {
      it = fold(it);
    }
    it.iterate(&fun);
  }
  Itr it = cast(Itr) t;
  if (!it) asm { int 3; }
  fun(it);
  t = fastcast!(T)~ it;
  assert(!!t);
}
