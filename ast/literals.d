module ast.literals;

import ast.base, ast.pointer, tools.base: slice, replace, toString;

public import ast.int_literal, ast.float_literal;

import ast.static_arrays, parseBase;

Expr delegate(string) mkString; // defined in literal_string

string uhex(uint u) {
  string res;
  for (int i = 0; i < 8; ++i) {
    res = "0123456789abcdef"[u & 0xf] ~ res;
    u >>= 4;
  }
  return res;
}

class DoubleExpr : Expr, Literal {
  union {
    double d;
    uint[2] i;
  }
  this(double d) { this.d = d; }
  mixin defaultIterate!();
  mixin defaultCollapse!();
  string name_used;
  override {
    DoubleExpr dup() { return fastalloc!(DoubleExpr)(d); }
    string toString() { return Format(d); }
    IType valueType() { return Single!(Double); }
    string getValue() { return "0x" ~ uhex(i[1]) ~ uhex(i[0]); }
    void emitLLVM(LLVMFile lf) {
      push(lf, "0x", toHex(i[1]), toHex(i[0]));
    }
  }
}

int floatconscounter;

string toHex(uint u) {
  auto chars = "0123456789abcdef";
  string res;
  for (int i = 28; i >= 0; i -= 4)
    res ~= chars[(u>>i)&0xf];
  return res;
}

union UHAX { double d; uint[2] u; }
class FloatExpr : Expr, Literal {
  union {
    float f;
    uint f_as_i;
  }
  this(float f) { this.f = f; }
  private this() { }
  mixin DefaultDup!();
  mixin defaultIterate!();
  mixin defaultCollapse!();
  string name_used;
  override {
    string toString() { return Format(f); }
    IType valueType() { return Single!(Float); }
    string getValue() { return Format(f_as_i); }
    void emitLLVM(LLVMFile lf) {
      UHAX hax;
      hax.d = f;
      push(lf, "0x", toHex(hax.u[1]), toHex(hax.u[0]&0b1110_0000_0000_0000_00000000_00000000));
    }
  }
}

bool fpPrecheck(string s) {
  s.eatComments();
  if (!s.length) return false;
  auto ch = s[0];
  if ((ch < '0' || ch > '9') && ch != '.' && ch != '-') { return false; }
  return true;
}

Object gotFloatExpr(ref string text, ParseCb cont, ParseCb rest) {
  if (!fpPrecheck(text)) return null;
  float f;
  if (gotFloat(text, f)) return fastalloc!(FloatExpr)(f);
  return null;
}
mixin DefaultParser!(gotFloatExpr, "tree.expr.float_literal_early", "230");
mixin DefaultParser!(gotFloatExpr, "tree.expr.literal.float", "54");

Object gotDoubleExpr(ref string text, ParseCb cont, ParseCb rest) {
  if (!fpPrecheck(text)) return null;
  double d;
  if (gotDouble(text, d)) return fastalloc!(DoubleExpr)(d);
  return null;
}
mixin DefaultParser!(gotDoubleExpr, "tree.expr.literal.double", "545");

Object gotLiteralExpr(ref string text, ParseCb cont, ParseCb rest) {
  int i;
  auto t2 = text;
  bool isUint;
  if (t2.gotInt(i, &isUint)) {
    // allow for a..b .. HAX!
    if (t2.length >= 2) {
      auto t3 = t2;
      char ch1 = t3.takech(' '), ch2 = t3.takech(' ');
      if (ch1 == '.' && ch2 != '.')
        return null;
    }
    if (t2.length >= 1 && t2[0] == 'e') return null; // 1e5 is float/double, not int
    if (t2.accept("K")) i *= 1024;
    else if (t2.accept("M")) i *= 1024*1024;
    else if (t2.accept("G")) i *= 1024*1024*1024;
    text = t2;
    return fastcast!(Object)(mkInt(i, isUint));
  } else return null;
}

static this() {
  addPrecedence("tree.expr.literal", "55");
}

mixin DefaultParser!(gotLiteralExpr, "tree.expr.int_literal", "23");

/// "foo": char[3] -> char*
class CValueAsPointer : Expr {
  CValue sup;
  this(CValue sup) {
    this.sup = sup;
    if (!sup) fail;
    // if (fastcast!(StatementAnd)(sup)) fail;
  }
  override typeof(this) dup() { return new typeof(this) (sup.dup); }
  mixin defaultIterate!(sup);
  mixin defaultCollapse!();
  override IType valueType() {
    if (auto sa = fastcast!(StaticArray) (resolveType(sup.valueType())))
      return fastalloc!(Pointer)(sa.elemType);
    throw new Exception(Format("The CValue ", sup, " has confused me. "));
  }
  override void emitLLVM(LLVMFile lf) {
    sup.emitLocation(lf);
    auto from = typeToLLVM(sup.valueType())~"*", to = typeToLLVM(valueType());
    llcast(lf, from, to, lf.pop(), valueType().llvmSize());
  }
  override string toString() { return Format("cvalue& ", sup); }
}
