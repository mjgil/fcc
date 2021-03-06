module ast.intr;

import ast.base, ast.int_literal, ast.math;

class Interrupt : Statement {
  int which;
  this(int i) { which = i; }
  Interrupt dup() { return this; }
  override void emitLLVM(LLVMFile lf) {
    if (isARM()) {
      if (which == 3) {
        fastalloc!(IntrinsicExpr)("llvm.debugtrap", cast(Expr[]) null, Single!(Void));
      } else fail(qformat("No interrupt ", which, " on ARM"));
    } else {
      put(lf, `call void asm sideeffect "int $$`, which, `", ""()`);
    }
  }
  mixin defaultIterate!();
  mixin defaultCollapse!();
}

Object gotIntrStmt(ref string text, ParseCb cont, ParseCb rest) {
  Expr ex;
  if (!rest(text, "tree.expr"[], &ex))
    throw new Exception("Couldn't match interrupt number! "[]);
  auto ie = fastcast!(IntExpr)~ ex;
  if (!ie)
    throw new Exception("Interrupt number must be a literal constant! "[]);
  return fastalloc!(Interrupt)(ie.num);
}
mixin DefaultParser!(gotIntrStmt, "tree.semicol_stmt.intr", "24", "_interrupt");
