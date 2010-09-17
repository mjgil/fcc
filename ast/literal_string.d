module ast.literal_string;

import ast.base, ast.modules, ast.literals, ast.pointer, ast.arrays;

class StringExpr : Expr, Setupable {
  string str;
  Module forb;
  this() { forb = current_module(); current_module().addSetupable(this); }
  this(string s) { this(); str = s; }
  mixin defaultIterate!();
  string name_used;
  override {
    StringExpr dup() { return this; }
    void setup(AsmFile af) {
      if (name_used) return;
      name_used = Format(af.id, "_cons_", af.constants.length);
      af.constants[name_used] = cast(ubyte[]) str;
    }
    string toString() { return '"'~str.replace("\n", "\\n")~'"'; }
    // default action: place in string segment, load address on stack
    void emitAsm(AsmFile af) {
      assert(!!name_used, Format("\"", str, "\" not set up (in ", forb, " vs. ", current_module(), ")"));
      auto ptr = new Symbol(name_used);
      (new ArrayMaker(ptr, new IntExpr(str.length))).emitAsm(af);
    }
    // IType valueType() { return new StaticArray(Single!(Char), str.length); }
    IType valueType() { return Single!(Array, Single!(Char)); }
  }
}

static this() {
  mkString = delegate Expr(string s) { return new StringExpr(s); };
}

bool gotStringExpr(ref string text, out Expr ex, string sep = "\"") {
  auto t2 = text;
  StringExpr se;
  return t2.accept(sep) &&
    (se = new StringExpr, true) &&
    (se.str = t2.slice(sep).subst(sep), true) &&
    (text = t2, true) &&
    (ex = se, true);
}

Object gotStringLiteralExpr(ref string text, ParseCb cont, ParseCb rest) {
  // "" handled in ast.stringex now.
  Expr ex;
  if (text.gotStringExpr(ex, "`")) {
    return cast(Object) ex;
  } else return null;
}
mixin DefaultParser!(gotStringLiteralExpr, "tree.expr.literal_string", "551");

import ast.casting;
static this() {
  implicits ~= delegate Expr(Expr ex) {
    if (cast(StringExpr) ex) {
      return getArrayPtr(ex);
    }
    return null;
  };
}
